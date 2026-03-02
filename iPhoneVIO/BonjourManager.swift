//
//  BonjourManager.swift
//  iPhoneVIO
//
//  Handles Bonjour/mDNS advertising and service discovery.
//  - Advertises _iphonevio._tcp so rapid_driver can detect the app is running
//  - Browses _vioserver._tcp to auto-discover TCP servers on the LAN
//  - Browses _rapiddriver._tcp to discover the HTTP control API
//

import Foundation
import Network
import Combine

struct DiscoveredServer: Identifiable, Equatable {
    let id: String          // NWBrowser.Result hash
    let name: String        // Service name
    let endpoint: NWEndpoint
}

class BonjourManager: ObservableObject {
    static let shared = BonjourManager()

    // MARK: - Published State
    @Published var discoveredServers: [DiscoveredServer] = []
    @Published var isAdvertising = false
    @Published var rapidDriverURL: URL?

    // MARK: - Advertising (_iphonevio._tcp)
    private var listener: NWListener?
    private let advertiseQueue = DispatchQueue(label: "com.iphoneVIO.bonjour.advertise")

    // MARK: - Browsing (_vioserver._tcp)
    private var browser: NWBrowser?
    private let browseQueue = DispatchQueue(label: "com.iphoneVIO.bonjour.browse")

    // MARK: - Browsing (_rapiddriver._tcp)
    private var rapidDriverBrowser: NWBrowser?
    private let rapidDriverQueue = DispatchQueue(label: "com.iphoneVIO.bonjour.rapiddriver")
    private var resolveConnection: NWConnection?

    // Retry state for advertising
    private var lastAdvertiseSessionId: String = ""
    private var lastAdvertiseDeviceModel: String = ""
    private var advertiseRetryCount: Int = 0
    private static let maxAdvertiseRetries = 5

    private init() {}

    // MARK: - Advertise _iphonevio._tcp

    func startAdvertising(sessionId: String = "", deviceModel: String = "") {
        // Never restart if already advertising — brief gap kills rapid_driver discovery
        if isAdvertising {
            print("[Bonjour] Already advertising, skipping restart")
            return
        }
        stopAdvertising()
        lastAdvertiseSessionId = sessionId
        lastAdvertiseDeviceModel = deviceModel
        advertiseRetryCount = 0
        createAndStartListener()
    }

    private func createAndStartListener() {
        listener?.cancel()
        listener = nil

        do {
            // NWListener on an ephemeral port — we only need the Bonjour registration,
            // not actual TCP connections on this listener.
            let params = NWParameters.tcp
            listener = try NWListener(using: params)
        } catch {
            print("[Bonjour] Failed to create listener: \(error)")
            scheduleAdvertiseRetry()
            return
        }

        guard let listener = listener else { return }

        // Bonjour service registration
        let txtRecord = NWTXTRecord([
            "sessionId": lastAdvertiseSessionId,
            "deviceModel": lastAdvertiseDeviceModel,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        ])
        listener.service = NWListener.Service(
            name: "\(lastAdvertiseDeviceModel)-iPhoneVIO",
            type: "_iphonevio._tcp",
            txtRecord: txtRecord
        )

        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.advertiseRetryCount = 0
                    self.isAdvertising = true
                    if let port = self.listener?.port {
                        print("[Bonjour] Advertising _iphonevio._tcp on port \(port)")
                    }
                case .failed(let error):
                    print("[Bonjour] Listener failed: \(error)")
                    self.isAdvertising = false
                    self.listener?.cancel()
                    self.listener = nil
                    self.scheduleAdvertiseRetry()
                case .cancelled:
                    self.isAdvertising = false
                default:
                    break
                }
            }
        }

        // Accept and immediately cancel incoming connections (we don't need them)
        listener.newConnectionHandler = { conn in
            conn.cancel()
        }

        listener.start(queue: advertiseQueue)
    }

    private func scheduleAdvertiseRetry() {
        guard advertiseRetryCount < Self.maxAdvertiseRetries else {
            print("[Bonjour] Gave up advertising after \(Self.maxAdvertiseRetries) retries")
            return
        }
        advertiseRetryCount += 1
        let delay = Double(min(1 << advertiseRetryCount, 16))  // 2, 4, 8, 16, 16s
        print("[Bonjour] Retrying advertising in \(delay)s (attempt \(advertiseRetryCount)/\(Self.maxAdvertiseRetries))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.listener == nil else { return }
            self.createAndStartListener()
        }
    }

    func stopAdvertising() {
        advertiseRetryCount = Self.maxAdvertiseRetries  // prevent pending retries from firing
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isAdvertising = false
        }
    }

    // MARK: - Browse _vioserver._tcp

    func startBrowsing() {
        if browser != nil {
            print("[Bonjour] Already browsing _vioserver._tcp, skipping restart")
            return
        }

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_vioserver._tcp", domain: nil)
        let params = NWParameters()
        params.includePeerToPeer = true

        browser = NWBrowser(for: descriptor, using: params)

        browser?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[Bonjour] Browsing for _vioserver._tcp")
            case .failed(let error):
                print("[Bonjour] Browser failed: \(error), restarting…")
                self?.browser?.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self?.startBrowsing()
                }
            default:
                break
            }
        }

        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            let servers = results.compactMap { result -> DiscoveredServer? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredServer(
                    id: "\(result.hashValue)",
                    name: name,
                    endpoint: result.endpoint
                )
            }
            DispatchQueue.main.async {
                self?.discoveredServers = servers
            }
        }

        browser?.start(queue: browseQueue)
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        DispatchQueue.main.async {
            self.discoveredServers = []
        }
    }

    // MARK: - Browse _rapiddriver._tcp

    func startRapidDriverBrowsing() {
        if rapidDriverBrowser != nil {
            print("[Bonjour] Already browsing _rapiddriver._tcp, skipping restart")
            return
        }

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_rapiddriver._tcp", domain: nil)
        let params = NWParameters()
        params.includePeerToPeer = true

        rapidDriverBrowser = NWBrowser(for: descriptor, using: params)

        rapidDriverBrowser?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[Bonjour] Browsing for _rapiddriver._tcp")
            case .failed(let error):
                print("[Bonjour] RapidDriver browser failed: \(error), restarting…")
                self?.rapidDriverBrowser?.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self?.startRapidDriverBrowsing()
                }
            default:
                break
            }
        }

        rapidDriverBrowser?.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }

            if results.isEmpty {
                // Service disappeared
                self.resolveConnection?.cancel()
                self.resolveConnection = nil
                DispatchQueue.main.async {
                    self.rapidDriverURL = nil
                }
                return
            }

            // Resolve the first discovered service
            if let first = results.first {
                self.resolveRapidDriverEndpoint(first.endpoint)
            }
        }

        rapidDriverBrowser?.start(queue: rapidDriverQueue)
    }

    private func resolveRapidDriverEndpoint(_ endpoint: NWEndpoint) {
        resolveConnection?.cancel()

        // Force IPv4 to avoid link-local IPv6 addresses (%en0) breaking URL construction
        let tcpOptions = NWProtocolTCP.Options()
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        if let ipOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4
        }
        let conn = NWConnection(to: endpoint, using: params)
        resolveConnection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            print("[Bonjour] RapidDriver conn state: \(state)")
            switch state {
            case .ready:
                // Extract host and port from the resolved path
                if let remoteEndpoint = conn.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = remoteEndpoint {
                    let hostStr: String
                    switch host {
                    case .ipv4(let addr):
                        let raw = "\(addr)"
                        hostStr = raw.split(separator: "%").first.map(String.init) ?? raw
                    case .ipv6(let addr):
                        let raw = "\(addr)"
                        let clean = raw.split(separator: "%").first.map(String.init) ?? raw
                        hostStr = "[\(clean)]"
                    case .name(let name, _):
                        hostStr = name
                    @unknown default:
                        hostStr = "\(host)"
                    }
                    print("[Bonjour] RapidDriver host=\(host) hostStr=\(hostStr) port=\(port)")
                    let url = URL(string: "http://\(hostStr):\(port)")
                    print("[Bonjour] Resolved _rapiddriver._tcp → \(url?.absoluteString ?? "nil")")
                    DispatchQueue.main.async {
                        self.rapidDriverURL = url
                    }
                } else {
                    print("[Bonjour] RapidDriver .ready but no hostPort endpoint, path=\(String(describing: conn.currentPath))")
                }
                // Close the probe connection — we only needed the resolved address
                conn.cancel()
            case .failed(let error):
                print("[Bonjour] RapidDriver resolve failed: \(error)")
                conn.cancel()
                self.resolveConnection = nil
            case .waiting(let error):
                print("[Bonjour] RapidDriver resolve waiting: \(error)")
            case .cancelled:
                break
            default:
                break
            }
        }

        conn.start(queue: rapidDriverQueue)
    }

    func stopRapidDriverBrowsing() {
        rapidDriverBrowser?.cancel()
        rapidDriverBrowser = nil
        resolveConnection?.cancel()
        resolveConnection = nil
        DispatchQueue.main.async {
            self.rapidDriverURL = nil
        }
    }

    // MARK: - Lifecycle Helpers

    func startAll(sessionId: String = "", deviceModel: String = "") {
        startAdvertising(sessionId: sessionId, deviceModel: deviceModel)
        startBrowsing()
        startRapidDriverBrowsing()
    }

    func stopAll() {
        stopAdvertising()
        stopBrowsing()
        stopRapidDriverBrowsing()
    }
}
