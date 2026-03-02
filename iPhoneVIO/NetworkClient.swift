import Foundation
import Network
import simd

enum ConnectionStatus {
    case disconnected
    case connecting
    case connected
}

enum MessageType: UInt8 {
    case sessionMetadata = 0
    case frameData = 1
    case teleopCommand = 2
}

struct SessionMetadata: Encodable {
    let sessionId: String
    let deviceModel: String
    let imageWidth: Int
    let imageHeight: Int
    let focalLengthX: Float
    let focalLengthY: Float
    let principalPointX: Float
    let principalPointY: Float
    let arkitTimestamp0: Double
    let wallClock0: Double
}

struct FramePacket {
    var transform: simd_float4x4
    var deviceTimestamp: Double
    var wallClock: Double
    var jpegData: Data

    func toBytes() -> Data {
        var data = Data()

        // 4 bytes: JPEG payload size (uint32 LE)
        var imageLen = UInt32(jpegData.count)
        data.append(Data(bytes: &imageLen, count: 4))

        // 64 bytes: transform matrix (column-major float32 x 16)
        for i in 0..<4 {
            for j in 0..<4 {
                var val = transform[i][j]
                data.append(Data(bytes: &val, count: MemoryLayout<Float>.size))
            }
        }

        // 8 bytes: device timestamp (float64)
        var ts = deviceTimestamp
        data.append(Data(bytes: &ts, count: MemoryLayout<Double>.size))

        // 8 bytes: wall clock (float64)
        var wc = wallClock
        data.append(Data(bytes: &wc, count: MemoryLayout<Double>.size))

        // JPEG data
        data.append(jpegData)

        return data
    }
}

class NetworkClient {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.iphoneVIO.network", qos: .userInitiated)
    var isSending: Bool = false
    var onStatusChange: ((ConnectionStatus) -> Void)?

    func connect(hostIP: String, hostPort: Int) {
        // Clean up existing connection
        connection?.cancel()
        connection = nil
        isSending = false

        onStatusChange?(.connecting)
        print("Connecting to \(hostIP):\(hostPort)")

        let host = NWEndpoint.Host(hostIP)
        let port = NWEndpoint.Port(integerLiteral: UInt16(hostPort))

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)

        let conn = NWConnection(host: host, port: port, using: params)

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("TCP connected to \(hostIP):\(hostPort)")
                self?.onStatusChange?(.connected)
            case .failed(let error):
                print("TCP connection failed: \(error)")
                self?.onStatusChange?(.disconnected)
            case .cancelled:
                self?.onStatusChange?(.disconnected)
            case .waiting(let error):
                print("TCP waiting: \(error)")
            default:
                break
            }
        }

        conn.start(queue: queue)
        self.connection = conn
    }

    func connect(endpoint: NWEndpoint) {
        // Clean up existing connection
        connection?.cancel()
        connection = nil
        isSending = false

        onStatusChange?(.connecting)
        print("Connecting to endpoint: \(endpoint)")

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)

        let conn = NWConnection(to: endpoint, using: params)

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("TCP connected to \(endpoint)")
                self?.onStatusChange?(.connected)
            case .failed(let error):
                print("TCP connection failed: \(error)")
                conn.cancel()
                self?.connection = nil
                self?.onStatusChange?(.disconnected)
            case .cancelled:
                self?.onStatusChange?(.disconnected)
            case .waiting(let error):
                print("TCP waiting: \(error), cancelling")
                conn.cancel()
                self?.connection = nil
                self?.onStatusChange?(.disconnected)
            default:
                break
            }
        }

        conn.start(queue: queue)
        self.connection = conn
    }

    func disconnect() {
        isSending = false
        connection?.cancel()
        connection = nil
        onStatusChange?(.disconnected)
    }

    func sendSessionMetadata(_ metadata: SessionMetadata) {
        guard let conn = connection else { return }
        do {
            let jsonData = try JSONEncoder().encode(metadata)
            let message = Self.wrapMessage(type: .sessionMetadata, payload: jsonData)
            conn.send(content: message, completion: .contentProcessed { error in
                if let error = error {
                    print("Failed to send session metadata: \(error)")
                }
            })
        } catch {
            print("Failed to encode session metadata: \(error)")
        }
    }

    func sendFrame(_ packet: FramePacket) {
        guard !isSending else { return }
        guard let conn = connection else { return }

        isSending = true
        let payload = packet.toBytes()
        let message = Self.wrapMessage(type: .frameData, payload: payload)

        conn.send(content: message, completion: .contentProcessed { [weak self] error in
            self?.isSending = false
            if let error = error {
                print("Failed to send frame: \(error)")
            }
        })
    }

    func sendTeleopCommand(_ cmd: String) {
        guard let conn = connection else { return }
        let dict: [String: Any] = ["cmd": cmd, "ts": Date().timeIntervalSince1970]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict) else { return }
        let message = Self.wrapMessage(type: .teleopCommand, payload: jsonData)
        conn.send(content: message, completion: .contentProcessed { error in
            if let error = error {
                print("Failed to send teleop command: \(error)")
            }
        })
    }

    static func wrapMessage(type: MessageType, payload: Data) -> Data {
        var header = Data(count: 8)
        // [0:4] payload length (uint32 LE)
        var payloadLen = UInt32(payload.count)
        header.replaceSubrange(0..<4, with: Data(bytes: &payloadLen, count: 4))
        // [4] message type
        header[4] = type.rawValue
        // [5:8] reserved (already zero)

        var message = header
        message.append(payload)
        return message
    }
}
