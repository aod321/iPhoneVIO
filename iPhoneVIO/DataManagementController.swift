//
//  DataManagementController.swift
//  iPhoneVIO
//
//  HTTP client for recording management and replay control.
//

import Foundation

class DataManagementController: ObservableObject {
    @Published var recordings: [RecordingItem] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var totalSizeBytes: Int64 = 0
    @Published var diskFreeBytes: Int64 = 0
    @Published var replayStatus: ReplayStatus?
    @Published var selectedIds: Set<String> = []

    private var replayPoller: Timer?
    private var baseURL: URL?

    private let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let date = formatter.date(from: str) { return date }
            if let date = fallback.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(str)")
        }
        return decoder
    }()

    func updateBaseURL(_ url: URL?) {
        baseURL = url
        if url == nil {
            stopReplayPolling()
        }
    }

    // MARK: - Fetch Recordings

    func fetchRecordings() async {
        guard let baseURL = baseURL else {
            await setError("控制服务未连接")
            return
        }
        await MainActor.run { isLoading = true }
        defer { Task { @MainActor in isLoading = false } }

        guard let url = makePathURL(baseURL: baseURL, components: ["recordings"]) else {
            await setError("Invalid URL")
            return
        }

        do {
            let (data, response) = try await sendRequest(URLRequest(url: url))
            guard (200..<300).contains(response.statusCode) else {
                let apiErr = parseAPIError(from: data)
                await setError(apiErr ?? "获取列表失败 (\(response.statusCode)) \(url.absoluteString)")
                return
            }
            let result = try jsonDecoder.decode(RecordingsResponse.self, from: data)
            await MainActor.run {
                self.recordings = result.recordings
                self.totalSizeBytes = result.totalSizeBytes
                self.diskFreeBytes = result.diskFreeBytes
                // Remove selected IDs that no longer exist
                let existingIds = Set(result.recordings.map(\.sessionId))
                self.selectedIds = self.selectedIds.intersection(existingIds)
            }
        } catch {
            await setError("连接失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Delete Single

    func deleteRecording(_ id: String) async -> Bool {
        guard let baseURL = baseURL else {
            await setError("控制服务未连接")
            return false
        }

        guard let url = makePathURL(baseURL: baseURL, components: ["recordings", id]) else {
            await setError("Invalid URL")
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        do {
            let (data, response) = try await sendRequest(request)
            if (200..<300).contains(response.statusCode) {
                await MainActor.run {
                    self.recordings.removeAll { $0.sessionId == id }
                    self.selectedIds.remove(id)
                }
                return true
            } else {
                await setError(parseAPIError(from: data) ?? "删除失败")
                return false
            }
        } catch {
            await setError("连接失败")
            return false
        }
    }

    // MARK: - Batch Delete

    func deleteBatch(_ ids: Set<String>) async {
        guard let baseURL = baseURL else {
            await setError("控制服务未连接")
            return
        }
        guard !ids.isEmpty else { return }

        guard let url = makePathURL(baseURL: baseURL, components: ["recordings", "delete_batch"]) else {
            await setError("Invalid URL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(BatchDeleteRequest(sessionIds: Array(ids)))

        do {
            let (data, response) = try await sendRequest(request)
            if (200..<300).contains(response.statusCode) {
                let result = try JSONDecoder().decode(BatchDeleteResponse.self, from: data)
                await MainActor.run {
                    let deletedSet = Set(result.deleted)
                    self.recordings.removeAll { deletedSet.contains($0.sessionId) }
                    self.selectedIds.subtract(deletedSet)
                }
                if !result.failed.isEmpty {
                    let failMsg = result.failed.map { "\($0.sessionId.prefix(8)): \($0.error)" }.joined(separator: "\n")
                    await setError("部分删除失败:\n\(failMsg)")
                }
            } else {
                await setError(parseAPIError(from: data) ?? "批量删除失败")
            }
        } catch {
            await setError("连接失败")
        }
    }

    // MARK: - Replay

    func startReplay(_ id: String) async -> Bool {
        guard let baseURL = baseURL else {
            await setError("控制服务未连接")
            return false
        }

        guard let url = makePathURL(baseURL: baseURL, components: ["recordings", id, "replay"]) else {
            await setError("Invalid URL")
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{}".data(using: .utf8)

        do {
            let (data, response) = try await sendRequest(request)
            if (200..<300).contains(response.statusCode) {
                await MainActor.run {
                    self.startReplayPolling()
                }
                return true
            } else {
                await setError(parseAPIError(from: data) ?? "重播启动失败")
                return false
            }
        } catch {
            await setError("连接失败")
            return false
        }
    }

    func stopReplay() async {
        guard let baseURL = baseURL else { return }

        guard let url = makePathURL(baseURL: baseURL, components: ["replay", "stop"]) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{}".data(using: .utf8)

        do {
            let (data, response) = try await sendRequest(request)
            if (200..<300).contains(response.statusCode) {
                await MainActor.run {
                    self.replayStatus = nil
                    self.stopReplayPolling()
                }
            } else {
                await setError(parseAPIError(from: data) ?? "停止重播失败")
            }
        } catch {
            await setError("连接失败")
        }
    }

    // MARK: - Replay Polling

    private func startReplayPolling() {
        stopReplayPolling()
        pollReplayStatus()
        replayPoller = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollReplayStatus()
        }
    }

    func stopReplayPolling() {
        replayPoller?.invalidate()
        replayPoller = nil
    }

    private func pollReplayStatus() {
        guard let baseURL = baseURL else { return }
        guard let url = makePathURL(baseURL: baseURL, components: ["replay", "status"]) else { return }

        Task {
            do {
                let (data, response) = try await sendRequest(URLRequest(url: url))
                guard (200..<300).contains(response.statusCode) else { return }
                let status = try JSONDecoder().decode(ReplayStatus.self, from: data)
                await MainActor.run {
                    self.replayStatus = status.active ? status : nil
                    if !status.active {
                        self.stopReplayPolling()
                    }
                }
            } catch {
                // Silently ignore poll failures
            }
        }
    }

    /// Whether a replay is currently active
    var isReplaying: Bool {
        replayStatus?.active == true
    }

    // MARK: - Helpers

    private func makePathURL(baseURL: URL, components: [String]) -> URL? {
        guard var urlComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var path = urlComponents.percentEncodedPath
        if path.isEmpty { path = "/" }
        else if !path.hasSuffix("/") { path += "/" }

        for (index, component) in components.enumerated() {
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "/")
            guard let encoded = component.addingPercentEncoding(withAllowedCharacters: allowed) else {
                return nil
            }
            path += encoded
            if index != components.count - 1 { path += "/" }
        }
        urlComponents.percentEncodedPath = path
        return urlComponents.url
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
        struct APIError: Decodable { let error: String }
        return (try? JSONDecoder().decode(APIError.self, from: data))?.error
    }

    @MainActor
    private func setError(_ message: String) {
        error = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.error = nil
        }
    }
}
