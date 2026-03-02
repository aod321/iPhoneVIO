//
//  RecordingController.swift
//  iPhoneVIO
//
//  Controls recording via rapid_driver HTTP API.
//

import Foundation

struct DeviceNodeStatus: Decodable, Identifiable, Equatable {
    let name: String
    let bitIndex: Int
    let discovered: Bool
    let heartbeatOk: Bool
    let processRunning: Bool
    let pid: UInt32?
    let backend: String
    let address: String?

    /// Device is effectively reachable (heartbeat OK or discovered)
    var isReachable: Bool { discovered || heartbeatOk }

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case bitIndex = "bit_index"
        case discovered
        case heartbeatOk = "heartbeat_ok"
        case processRunning = "process_running"
        case pid
        case backend
        case address
    }
}

private struct ReadyStatus: Decodable {
    let ready: Bool
    let online: Int
    let total: Int
}

private struct APIErrorResponse: Decodable {
    let error: String
}

class RecordingController: ObservableObject {
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var lastError: String?
    @Published var isReady = false
    @Published var onlineDevices = 0
    @Published var totalDevices = 0
    @Published var deviceNodes: [DeviceNodeStatus] = []
    @Published var devicesFetchFailed = false
    @Published var isRestarting: Set<String> = []
    @Published var isReplaying = false

    private var timer: Timer?
    private var readyPoller: Timer?
    private var baseURL: URL?
    private let pollInterval: TimeInterval = 2.0

    func updateBaseURL(_ url: URL?) {
        baseURL = url
        // If server disappeared while recording, stop the timer
        if url == nil && isRecording {
            stopTimer()
            isRecording = false
        }
        if url != nil {
            startReadyPolling()
        } else {
            stopReadyPolling()
            resetControlState()
        }
    }

    func startRecording() async {
        guard let baseURL = baseURL else { return }

        guard let url = makePathURL(baseURL: baseURL, components: ["recording", "start"]) else {
            await setError("Invalid control URL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["session_id": UUID().uuidString]
        request.httpBody = try? JSONEncoder().encode(body)

        do {
            let (data, response) = try await sendRequest(request)
            if (200..<300).contains(response.statusCode) {
                await MainActor.run {
                    self.isRecording = true
                    self.recordingDuration = 0
                    self.startTimer()
                }
            } else {
                await setError(parseAPIError(from: data) ?? "Server returned error")
            }
        } catch {
            await setError("Connection failed")
        }
    }

    func stopRecording() async {
        guard let baseURL = baseURL else { return }

        guard let url = makePathURL(baseURL: baseURL, components: ["recording", "stop"]) else {
            await setError("Invalid control URL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{}".data(using: .utf8)

        do {
            let (data, response) = try await sendRequest(request)
            if (200..<300).contains(response.statusCode) {
                await MainActor.run {
                    self.isRecording = false
                    self.stopTimer()
                }
            } else {
                await setError(parseAPIError(from: data) ?? "Server returned error")
            }
        } catch {
            await setError("Connection failed")
        }
    }

    func restartDevice(_ name: String) async {
        guard let baseURL = baseURL else {
            await setError("Control service not connected")
            return
        }
        if isRecording {
            await setError("Cannot restart device while recording")
            return
        }

        let shouldStart = await MainActor.run { () -> Bool in
            if self.isRestarting.contains(name) {
                return false
            }
            self.isRestarting.insert(name)
            return true
        }
        guard shouldStart else { return }
        defer {
            Task { @MainActor in
                self.isRestarting.remove(name)
            }
        }

        guard let url = makePathURL(baseURL: baseURL, components: ["devices", name, "restart"]) else {
            await setError("Invalid device name")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{}".data(using: .utf8)

        do {
            let (data, response) = try await sendRequest(request)
            if (200..<300).contains(response.statusCode) {
                try? await Task.sleep(nanoseconds: 500_000_000)
                pollDevices()
            } else {
                await setError(parseAPIError(from: data) ?? "Restart failed")
            }
        } catch {
            await setError("Connection failed")
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.recordingDuration += 1.0
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        recordingDuration = 0
    }

    // MARK: - Ready Polling

    private func startReadyPolling() {
        readyPoller?.invalidate()
        pollReady()
        pollDevices()
        readyPoller = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollReady()
            self?.pollDevices()
        }
    }

    private func stopReadyPolling() {
        readyPoller?.invalidate()
        readyPoller = nil
    }

    private func pollReady() {
        guard let baseURL = baseURL else { return }
        guard let url = makePathURL(baseURL: baseURL, components: ["ready"]) else { return }

        Task {
            do {
                let request = URLRequest(url: url)
                let (data, response) = try await sendRequest(request)
                guard (200..<300).contains(response.statusCode) else {
                    await MainActor.run {
                        self.isReady = false
                    }
                    return
                }
                let readyStatus = try JSONDecoder().decode(ReadyStatus.self, from: data)
                await MainActor.run {
                    self.isReady = readyStatus.ready
                    self.onlineDevices = readyStatus.online
                    self.totalDevices = readyStatus.total
                }
            } catch {
                await MainActor.run {
                    self.isReady = false
                }
            }
        }
    }

    private func pollDevices() {
        guard let baseURL = baseURL else { return }
        guard let url = makePathURL(baseURL: baseURL, components: ["devices"]) else { return }

        Task {
            do {
                let request = URLRequest(url: url)
                let (data, response) = try await sendRequest(request)
                guard (200..<300).contains(response.statusCode) else {
                    await MainActor.run {
                        self.devicesFetchFailed = true
                    }
                    return
                }

                if let rawJSON = String(data: data, encoding: .utf8) {
                    print("[Devices] Raw response: \(rawJSON)")
                }
                let devices = try JSONDecoder().decode([DeviceNodeStatus].self, from: data)
                await MainActor.run {
                    self.deviceNodes = devices
                    self.devicesFetchFailed = false

                    let names = Set(devices.map(\.name))
                    self.isRestarting = Set(self.isRestarting.filter { names.contains($0) })
                }
            } catch {
                await MainActor.run {
                    self.devicesFetchFailed = true
                }
            }
        }
    }

    private func resetControlState() {
        isReady = false
        onlineDevices = 0
        totalDevices = 0
        deviceNodes = []
        devicesFetchFailed = false
        isRestarting.removeAll()
    }

    private func makePathURL(baseURL: URL, components: [String]) -> URL? {
        guard var urlComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        var path = urlComponents.percentEncodedPath
        if path.isEmpty {
            path = "/"
        } else if !path.hasSuffix("/") {
            path += "/"
        }

        for (index, component) in components.enumerated() {
            guard let encoded = encodedPathComponent(component) else {
                return nil
            }
            path += encoded
            if index != components.count - 1 {
                path += "/"
            }
        }

        urlComponents.percentEncodedPath = path
        return urlComponents.url
    }

    private func encodedPathComponent(_ component: String) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return component.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    private func sendRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    private func parseAPIError(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return (try? JSONDecoder().decode(APIErrorResponse.self, from: data))?.error
    }

    @MainActor
    private func setError(_ message: String) {
        lastError = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.lastError = nil
        }
    }
}
