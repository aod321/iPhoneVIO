//
//  DataManagementView.swift
//  iPhoneVIO
//
//  Recording file browser with batch delete and replay controls.
//

import SwiftUI
import Combine

struct DataManagementView: View {
    @StateObject private var controller = DataManagementController()
    let isRecording: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var showDeleteConfirm = false
    @State private var deleteTarget: String?          // single delete
    @State private var showBatchDeleteConfirm = false
    @State private var actionTarget: RecordingItem?   // for confirmation dialog

    var body: some View {
        VStack(spacing: 0) {
            // Storage stats bar
            storageBar

            // Edit mode toolbar
            if isEditing && !controller.selectedIds.isEmpty {
                editToolbar
            }

            // Main list
            listContent

            // Replay control bar
            if let status = controller.replayStatus, status.active {
                replayControlBar(status)
            }
        }
        .navigationTitle("Data Management")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEditing ? "Done" : "Edit") {
                    withAnimation {
                        isEditing.toggle()
                        if !isEditing {
                            controller.selectedIds.removeAll()
                        }
                    }
                }
                .disabled(controller.recordings.isEmpty)
            }
        }
        .onAppear {
            controller.updateBaseURL(BonjourManager.shared.rapidDriverURL)
            Task { await controller.fetchRecordings() }
        }
        .onDisappear {
            controller.stopReplayPolling()
        }
        .onReceive(BonjourManager.shared.$rapidDriverURL) { url in
            controller.updateBaseURL(url)
            if url != nil {
                Task { await controller.fetchRecordings() }
            }
        }
        // Single delete confirmation
        .alert("Confirm Delete", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                if let id = deleteTarget {
                    Task { await controller.deleteRecording(id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone")
        }
        // Batch delete confirmation
        .alert("Confirm Batch Delete", isPresented: $showBatchDeleteConfirm) {
            Button("Delete \(controller.selectedIds.count) Items", role: .destructive) {
                let ids = controller.selectedIds
                Task {
                    await controller.deleteBatch(ids)
                    await MainActor.run {
                        if controller.selectedIds.isEmpty {
                            isEditing = false
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(controller.selectedIds.count) selected recordings will be permanently deleted")
        }
        // Error toast
        .overlay(alignment: .top) {
            if let error = controller.error {
                Text(error)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.red.opacity(0.85))
                    .cornerRadius(10)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: controller.error)
    }

    // MARK: - Storage Stats Bar

    private var storageBar: some View {
        HStack {
            Label(formatBytes(controller.totalSizeBytes), systemImage: "internaldrive")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
            Label("Free \(formatBytes(controller.diskFreeBytes))", systemImage: "externaldrive")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Edit Toolbar

    private var editToolbar: some View {
        HStack {
            Button {
                if controller.selectedIds.count == controller.recordings.count {
                    controller.selectedIds.removeAll()
                } else {
                    controller.selectedIds = Set(controller.recordings.map(\.sessionId))
                }
            } label: {
                Text(controller.selectedIds.count == controller.recordings.count ? "Deselect All" : "Select All")
                    .font(.system(size: 14))
            }

            Spacer()

            Button(role: .destructive) {
                showBatchDeleteConfirm = true
            } label: {
                Text("Delete Selected (\(controller.selectedIds.count))")
                    .font(.system(size: 14, weight: .medium))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - List Content

    @ViewBuilder
    private var listContent: some View {
        if controller.isLoading && controller.recordings.isEmpty {
            Spacer()
            ProgressView("Loading…")
            Spacer()
        } else if controller.recordings.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text("No Recordings")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                Button("Refresh") {
                    Task { await controller.fetchRecordings() }
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        } else {
            List {
                ForEach(controller.recordings) { item in
                    recordingRow(item)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deleteTarget = item.sessionId
                                showDeleteConfirm = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isEditing {
                                toggleSelection(item.sessionId)
                            } else {
                                actionTarget = item
                            }
                        }
                }
            }
            .listStyle(.plain)
            .refreshable {
                await controller.fetchRecordings()
            }
            // Action dialog for single item
            .confirmationDialog(
                actionTarget?.filename ?? "",
                isPresented: Binding(
                    get: { actionTarget != nil },
                    set: { if !$0 { actionTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let item = actionTarget {
                    Button("Replay") {
                        startReplayIfAllowed(item.sessionId)
                    }
                    .disabled(isRecording)

                    Button("Delete", role: .destructive) {
                        deleteTarget = item.sessionId
                        actionTarget = nil
                        showDeleteConfirm = true
                    }

                    Button("Cancel", role: .cancel) {
                        actionTarget = nil
                    }
                }
            }
        }
    }

    // MARK: - Recording Row

    private func recordingRow(_ item: RecordingItem) -> some View {
        HStack(spacing: 12) {
            if isEditing {
                Image(systemName: controller.selectedIds.contains(item.sessionId) ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(controller.selectedIds.contains(item.sessionId) ? .accentColor : .secondary)
                    .font(.system(size: 22))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName(item))
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(formatDate(item.createdAt))
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text("·")
                        .foregroundColor(.secondary)
                    Text(formatBytes(item.sizeBytes))
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }

                if let dur = item.durationSecs {
                    Text("Duration \(formatDuration(dur))")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Show replay indicator if this item is being replayed
            if controller.replayStatus?.sessionId == item.sessionId {
                Image(systemName: "play.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 14))
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Replay Control Bar

    private func replayControlBar(_ status: ReplayStatus) -> some View {
        VStack(spacing: 6) {
            ProgressView(value: status.progress, total: 1.0)
                .tint(.green)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Replaying")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.green)
                    Text("\(formatDuration(status.elapsedSecs)) / \(formatDuration(status.totalSecs))")
                        .font(.system(size: 12).monospaced())
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    Task { await controller.stopReplay() }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.red)
                        .clipShape(Circle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
        .shadow(color: .black.opacity(0.1), radius: 4, y: -2)
    }

    // MARK: - Actions

    private func toggleSelection(_ id: String) {
        if controller.selectedIds.contains(id) {
            controller.selectedIds.remove(id)
        } else {
            controller.selectedIds.insert(id)
        }
    }

    private func startReplayIfAllowed(_ id: String) {
        if isRecording {
            controller.error = "Cannot replay while recording"
            return
        }
        if controller.isReplaying {
            controller.error = "Replay already in progress, stop it first"
            return
        }
        Task { await controller.startReplay(id) }
    }

    // MARK: - Formatting

    private func displayName(_ item: RecordingItem) -> String {
        // Show filename without .mcap extension
        if item.filename.hasSuffix(".mcap") {
            return String(item.filename.dropLast(5))
        }
        return item.filename
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalSecs = Int(seconds)
        let mins = totalSecs / 60
        let secs = totalSecs % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
