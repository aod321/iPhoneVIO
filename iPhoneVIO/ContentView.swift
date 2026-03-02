//
//  ContentView.swift
//  iPhoneVIO
//
//  Created by David Gao on 4/26/24.
//

import SwiftUI
import SceneKit

struct ContentView : View {
    @ObservedObject var viewController: ViewController = ViewController()
    @ObservedObject var bonjourManager = BonjourManager.shared
    @StateObject var recordingController = RecordingController()
    @State private var autoConnected = false

    var statusColor: Color {
        switch viewController.connectionStatus {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .red
        }
    }

    var isConnected: Bool {
        viewController.connectionStatus == .connected
    }

    var body: some View {
        NavigationStack {
        ARViewContainer(viewController: self.viewController)
            .edgesIgnoringSafeArea(.all)
            // Top status bar
            .overlay(alignment: .top) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 12, height: 12)
                    Text(viewController.displayString)
                        .font(.system(size: 14).monospaced())
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if !viewController.trackingStatus.isEmpty {
                        Text(viewController.trackingStatus)
                            .font(.system(size: 13, weight: .bold).monospaced())
                            .foregroundColor(.red)
                    }
                }
                .padding(10)
                .background(Color.black.opacity(0.6))
                .cornerRadius(8)
                .padding(.top, 50)
            }
            // Orientation cube + reset origin (top-right)
            .overlay(alignment: .topTrailing) {
                VStack(spacing: 8) {
                    OrientationCubeView(cameraTransform: viewController.cameraTransform)
                        .frame(width: 120, height: 120)

                    Button {
                        ARManager.shared.actionStream.send(.resetOrigin)
                    } label: {
                        Image(systemName: "scope")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        DataManagementView(
                            isRecording: recordingController.isRecording
                        )
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 90)
                .padding(.trailing, 8)
            }
            // mDNS status panel (top-left)
            .overlay(alignment: .topLeading) {
                MDNSStatusPanel(
                    bonjourManager: bonjourManager,
                    recordingController: recordingController,
                    connectionStatus: viewController.connectionStatus
                )
                .padding(.top, 90)
                .padding(.leading, 8)
            }
            // FeasibleCap control panel (bottom-leading)
            .overlay(alignment: .bottomLeading) {
                FeasibleCapControlPanel(viewController: viewController)
                    .padding(.leading, 8)
                    .padding(.bottom, 40)
            }
            // Teleop control panel (bottom-trailing)
            .overlay(alignment: .bottomTrailing) {
                TeleopControlPanel(viewController: viewController, bonjourManager: bonjourManager)
                    .padding(.trailing, 8)
                    .padding(.bottom, 40)
            }
            // Recording button (bottom-center)
            .overlay(alignment: .bottom) {
                RecordingButton(
                    recordingController: recordingController,
                    isEnabled: recordingController.isReady || recordingController.isRecording
                )
                .padding(.bottom, 40)
            }
            // Error toast
            .overlay(alignment: .center) {
                if let error = recordingController.lastError {
                    Text(error)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.85))
                        .cornerRadius(10)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: recordingController.lastError)
            // Auto-connect to first teleop server (priority)
            .onChange(of: bonjourManager.teleopServers) { _, servers in
                if !autoConnected && !isConnected && !servers.isEmpty {
                    let server = servers[0]
                    print("[Bonjour] Auto-connecting to teleop: \(server.name)")
                    ARManager.shared.actionStream.send(.connectToEndpoint(server.endpoint))
                    autoConnected = true
                }
            }
            // Fallback: auto-connect to _vioserver._tcp (node_iphone via Raspberry Pi)
            .onChange(of: bonjourManager.discoveredServers) { _, servers in
                if !autoConnected && !isConnected && bonjourManager.teleopServers.isEmpty && !servers.isEmpty {
                    let server = servers[0]
                    print("[Bonjour] Auto-connecting to vioserver: \(server.name)")
                    ARManager.shared.actionStream.send(.connectToEndpoint(server.endpoint))
                    autoConnected = true
                }
            }
            // Retry on disconnect: teleop first, then vioserver fallback
            .onChange(of: viewController.connectionStatus) { _, status in
                if status == .disconnected {
                    autoConnected = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        if viewController.connectionStatus == .disconnected {
                            if let server = bonjourManager.teleopServers.first {
                                print("[Bonjour] Reconnecting to teleop: \(server.name)")
                                ARManager.shared.actionStream.send(.connectToEndpoint(server.endpoint))
                                autoConnected = true
                            } else if let server = bonjourManager.discoveredServers.first {
                                print("[Bonjour] Reconnecting to vioserver: \(server.name)")
                                ARManager.shared.actionStream.send(.connectToEndpoint(server.endpoint))
                                autoConnected = true
                            }
                        }
                    }
                }
            }
            // Sync rapidDriverURL to recording controller
            .onChange(of: bonjourManager.rapidDriverURL) { _, url in
                recordingController.updateBaseURL(url)
            }
            .navigationBarHidden(true)
        } // NavigationStack
    }
}

// MARK: - mDNS Status Panel

struct MDNSStatusPanel: View {
    @ObservedObject var bonjourManager: BonjourManager
    @ObservedObject var recordingController: RecordingController
    let connectionStatus: ConnectionStatus
    @State private var isPanelExpanded = false
    @State private var showDeviceControls = false

    var readyStatusText: String {
        if bonjourManager.rapidDriverURL == nil {
            return "—"
        }
        return "\(recordingController.onlineDevices)/\(recordingController.totalDevices)"
    }

    var readyStatusColor: Color {
        if recordingController.isReady { return .green }
        if recordingController.totalDevices > 0 { return .yellow }
        return .gray
    }

    var dataStatusText: String {
        if connectionStatus == .connected {
            return "Connected"
        } else if !bonjourManager.discoveredServers.isEmpty {
            return "Found"
        } else {
            return "Searching"
        }
    }

    var dataStatusColor: Color {
        if connectionStatus == .connected { return .green }
        if !bonjourManager.discoveredServers.isEmpty { return .yellow }
        return .gray
    }

    var teleopStatusText: String {
        if connectionStatus == .connected && !bonjourManager.teleopServers.isEmpty {
            return "Connected"
        } else if !bonjourManager.teleopServers.isEmpty {
            return "Found"
        } else {
            return "Searching"
        }
    }

    var teleopStatusColor: Color {
        if connectionStatus == .connected && !bonjourManager.teleopServers.isEmpty { return .green }
        if !bonjourManager.teleopServers.isEmpty { return .yellow }
        return .gray
    }

    var controlStatusText: String {
        bonjourManager.rapidDriverURL != nil ? "Found" : "Searching"
    }

    var controlStatusColor: Color {
        bonjourManager.rapidDriverURL != nil ? .green : .gray
    }

    var controlAvailable: Bool {
        bonjourManager.rapidDriverURL != nil
    }

    // Collapsed pill: 4 colored dots
    private var collapsedPill: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isPanelExpanded = true
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(bonjourManager.isAdvertising ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Circle()
                    .fill(dataStatusColor)
                    .frame(width: 8, height: 8)
                Circle()
                    .fill(teleopStatusColor)
                    .frame(width: 8, height: 8)
                Circle()
                    .fill(controlStatusColor)
                    .frame(width: 8, height: 8)
                Circle()
                    .fill(readyStatusColor)
                    .frame(width: 8, height: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.6))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    // Expanded panel: full status + device controls
    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header with collapse button
            HStack {
                Text("Status")
                    .font(.system(size: 11, weight: .bold).monospaced())
                    .foregroundColor(.white.opacity(0.85))
                Spacer(minLength: 4)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPanelExpanded = false
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(4)
                }
                .buttonStyle(.plain)
            }

            StatusRow(
                label: "Advert",
                status: bonjourManager.isAdvertising ? "✓" : "…",
                color: bonjourManager.isAdvertising ? .green : .gray
            )
            StatusRow(
                label: "Data",
                status: dataStatusText,
                color: dataStatusColor
            )
            StatusRow(
                label: "Teleop",
                status: teleopStatusText,
                color: teleopStatusColor
            )
            StatusRow(
                label: "Ctrl",
                status: controlStatusText,
                color: controlStatusColor
            )
            StatusRow(
                label: "Ready",
                status: readyStatusText,
                color: readyStatusColor
            )

            Divider()
                .overlay(Color.white.opacity(0.15))

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showDeviceControls.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Devices")
                        .font(.system(size: 11, weight: .medium).monospaced())
                        .foregroundColor(.white.opacity(0.7))
                    Spacer(minLength: 4)
                    Text(showDeviceControls ? "Hide" : "Show")
                        .font(.system(size: 11).monospaced())
                        .foregroundColor(.white.opacity(0.85))
                }
            }
            .buttonStyle(.plain)

            if showDeviceControls {
                deviceControlsView
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.6))
        .cornerRadius(8)
    }

    var body: some View {
        if isPanelExpanded {
            expandedPanel
        } else {
            collapsedPill
        }
    }

    @ViewBuilder
    private var deviceControlsView: some View {
        if !controlAvailable {
            Text("Control not connected")
                .font(.system(size: 11).monospaced())
                .foregroundColor(.white.opacity(0.75))
        } else if recordingController.devicesFetchFailed && recordingController.deviceNodes.isEmpty {
            Text("Device status fetch failed")
                .font(.system(size: 11).monospaced())
                .foregroundColor(.yellow)
        } else if recordingController.deviceNodes.isEmpty {
            Text("No device nodes found")
                .font(.system(size: 11).monospaced())
                .foregroundColor(.white.opacity(0.75))
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if recordingController.devicesFetchFailed {
                    Text("Device status update failed")
                        .font(.system(size: 10).monospaced())
                        .foregroundColor(.yellow)
                }
                ForEach(recordingController.deviceNodes) { device in
                    DeviceControlRow(
                        device: device,
                        isControlAvailable: controlAvailable,
                        isRecording: recordingController.isRecording,
                        isRestarting: recordingController.isRestarting.contains(device.name)
                    ) {
                        Task {
                            await recordingController.restartDevice(device.name)
                        }
                    }
                }
            }
        }
    }
}

struct StatusRow: View {
    let label: String
    let status: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11, weight: .medium).monospaced())
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 42, alignment: .leading)
            Text(status)
                .font(.system(size: 11).monospaced())
                .foregroundColor(.white)
        }
    }
}

struct DeviceControlRow: View {
    let device: DeviceNodeStatus
    let isControlAvailable: Bool
    let isRecording: Bool
    let isRestarting: Bool
    let onRestart: () -> Void

    var statusColor: Color {
        if device.isReachable && device.processRunning { return .green }
        if device.isReachable { return .yellow }
        return .gray
    }

    var restartTitle: String {
        if isRestarting { return "Restarting" }
        if isRecording { return "Recording" }
        return "Restart"
    }

    var buttonDisabled: Bool {
        !isControlAvailable || isRestarting
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(device.name)
                .font(.system(size: 11).monospaced())
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer(minLength: 6)
            Button(action: onRestart) {
                Text(restartTitle)
                    .font(.system(size: 10, weight: .medium).monospaced())
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.16))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(buttonDisabled)
            .opacity((buttonDisabled || isRecording) ? 0.55 : 1.0)
        }
    }
}

// MARK: - Recording Button

struct RecordingButton: View {
    @ObservedObject var recordingController: RecordingController
    let isEnabled: Bool

    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 8) {
            Button {
                Task {
                    if recordingController.isRecording {
                        await recordingController.stopRecording()
                    } else {
                        await recordingController.startRecording()
                    }
                }
            } label: {
                ZStack {
                    // Outer ring
                    Circle()
                        .stroke(isEnabled ? Color.white : Color.gray, lineWidth: 4)
                        .frame(width: 72, height: 72)
                        .scaleEffect(recordingController.isRecording ? pulseScale : 1.0)

                    // Inner shape: circle when idle, rounded square when recording
                    if recordingController.isRecording {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red)
                            .frame(width: 30, height: 30)
                    } else {
                        Circle()
                            .fill(isEnabled ? Color.red : Color.gray)
                            .frame(width: 58, height: 58)
                    }
                }
            }
            .disabled(!isEnabled)
            .onChange(of: recordingController.isRecording) { _, recording in
                if recording {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulseScale = 1.1
                    }
                } else {
                    withAnimation(.default) {
                        pulseScale = 1.0
                    }
                }
            }

            // Duration label
            if recordingController.isRecording {
                Text(formatDuration(recordingController.recordingDuration))
                    .font(.system(size: 14, weight: .medium).monospaced())
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.7))
                    .cornerRadius(6)
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}


// MARK: - FeasibleCap Control Panel

struct FeasibleCapControlPanel: View {
    @ObservedObject var viewController: ViewController

    private var feasibilityColor: Color {
        switch viewController.feasibilityState {
        case .feasible:   return .green
        case .warning:    return .yellow
        case .infeasible: return .red
        }
    }

    private var feasibilityLabel: String {
        switch viewController.feasibilityState {
        case .feasible:   return "Feasible"
        case .warning:    return "Near Singular"
        case .infeasible: return "Infeasible"
        }
    }

    private let taskLabels = ["pick_and_place", "tossing"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Collection mode toggle
            HStack(spacing: 0) {
                ForEach(CollectionMode.allCases, id: \.self) { mode in
                    Button {
                        ARManager.shared.actionStream.send(.setCollectionMode(mode))
                    } label: {
                        Text(mode == .feasiblecap ? "FeasibleCap" : "Baseline")
                            .font(.system(size: 10, weight: .medium).monospaced())
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(viewController.collectionMode == mode ? Color.blue.opacity(0.5) : Color.white.opacity(0.12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .cornerRadius(6)

            // Task label picker
            HStack(spacing: 0) {
                ForEach(taskLabels, id: \.self) { label in
                    Button {
                        ARManager.shared.actionStream.send(.setTaskLabel(label))
                    } label: {
                        Text(label.replacingOccurrences(of: "_", with: " "))
                            .font(.system(size: 10, weight: .medium).monospaced())
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(viewController.taskLabel == label ? Color.purple.opacity(0.5) : Color.white.opacity(0.12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .cornerRadius(6)

            // Feasibility indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(feasibilityColor)
                    .frame(width: 10, height: 10)
                Text(feasibilityLabel)
                    .font(.system(size: 11, weight: .medium).monospaced())
                    .foregroundColor(.white)
            }

            if !viewController.feasibilityReason.isEmpty {
                Text(viewController.feasibilityReason)
                    .font(.system(size: 10).monospaced())
                    .foregroundColor(.white.opacity(0.7))
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(viewController.isPlacingBaseMode ? Color.yellow : (viewController.robotBasePlaced ? Color.green : Color.gray))
                    .frame(width: 10, height: 10)
                Text(viewController.isPlacingBaseMode ? "Previewing Base" : (viewController.robotBasePlaced ? "Base Placed" : "Base Not Placed"))
                    .font(.system(size: 11, weight: .medium).monospaced())
                    .foregroundColor(.white)
            }

            // Place Base: ArUco tag or manual
            HStack(spacing: 6) {
                Button {
                    ARManager.shared.actionStream.send(.startArucoPlacement)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 11))
                        Text("Tag Locate")
                            .font(.system(size: 11, weight: .medium).monospaced())
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.45))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Button {
                    ARManager.shared.actionStream.send(.startBasePlacement)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "location.circle")
                            .font(.system(size: 11))
                        Text("Manual Place")
                            .font(.system(size: 11, weight: .medium).monospaced())
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.16))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }

            // ArUco detection status (shown during ArUco placement mode)
            if viewController.isPlacingBaseMode {
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewController.isArucoMarkerDetected ? Color.green : Color.yellow)
                        .frame(width: 8, height: 8)
                    Text(viewController.isArucoMarkerDetected ? "Tag Detected · Tracking" : "Searching Tag...")
                        .font(.system(size: 11, weight: .medium).monospaced())
                        .foregroundColor(.white.opacity(0.9))
                }
                if !viewController.arucoDebugText.isEmpty {
                    Text(viewController.arucoDebugText)
                        .font(.system(size: 10).monospaced())
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(2)
                }
            }

            if viewController.isPlacingBaseMode {
                HStack(spacing: 6) {
                    Button {
                        ARManager.shared.actionStream.send(.rotateBaseYaw(Float.pi / 12))
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "rotate.left")
                                .font(.system(size: 11))
                            Text("Left 15°")
                                .font(.system(size: 11, weight: .medium).monospaced())
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.16))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewController.hasPlacementPreview)
                    .opacity(viewController.hasPlacementPreview ? 1.0 : 0.4)

                    Button {
                        ARManager.shared.actionStream.send(.rotateBaseYaw(-Float.pi / 12))
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "rotate.right")
                                .font(.system(size: 11))
                            Text("Right 15°")
                                .font(.system(size: 11, weight: .medium).monospaced())
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.16))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewController.hasPlacementPreview)
                    .opacity(viewController.hasPlacementPreview ? 1.0 : 0.4)
                }

                HStack(spacing: 6) {
                    Button {
                        ARManager.shared.actionStream.send(.adjustBaseHeight(0.01))
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 11))
                            Text("Up 1cm")
                                .font(.system(size: 11, weight: .medium).monospaced())
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.16))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewController.hasPlacementPreview)
                    .opacity(viewController.hasPlacementPreview ? 1.0 : 0.4)

                    Button {
                        ARManager.shared.actionStream.send(.adjustBaseHeight(-0.01))
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 11))
                            Text("Down 1cm")
                                .font(.system(size: 11, weight: .medium).monospaced())
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.16))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewController.hasPlacementPreview)
                    .opacity(viewController.hasPlacementPreview ? 1.0 : 0.4)
                }

                Text(String(format: "Height Offset: %.1f cm", viewController.placementHeightOffsetMeters * 100))
                    .font(.system(size: 11, weight: .medium).monospaced())
                    .foregroundColor(.white.opacity(0.9))

                HStack(spacing: 6) {
                    Button {
                        ARManager.shared.actionStream.send(.confirmBasePlacement)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 11))
                            Text("Confirm")
                                .font(.system(size: 11, weight: .medium).monospaced())
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.4))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewController.hasPlacementPreview)
                    .opacity(viewController.hasPlacementPreview ? 1.0 : 0.4)

                    Button {
                        ARManager.shared.actionStream.send(.cancelBasePlacement)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 11))
                            Text("Cancel")
                                .font(.system(size: 11, weight: .medium).monospaced())
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.35))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Pose preset buttons (available after base placement confirmed)
            if viewController.robotBasePlaced && !viewController.isPlacingBaseMode {
                HStack(spacing: 6) {
                    Button {
                        ARManager.shared.actionStream.send(.setZeroPose)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise.circle")
                                .font(.system(size: 11))
                            Text("Zero")
                                .font(.system(size: 11, weight: .medium).monospaced())
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.16))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    Button {
                        ARManager.shared.actionStream.send(.setHomePose)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "house.circle")
                                .font(.system(size: 11))
                            Text("Home")
                                .font(.system(size: 11, weight: .medium).monospaced())
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.4))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    Button {
                        ARManager.shared.actionStream.send(.correctToCamera)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "scope")
                                .font(.system(size: 11))
                            if viewController.distanceToEE >= 0 && viewController.angleToEE >= 0 {
                                Text(String(format: "Correct %.2fm %.0f°", viewController.distanceToEE, viewController.angleToEE))
                                    .font(.system(size: 11, weight: .medium).monospaced())
                            } else {
                                Text("Correct")
                                    .font(.system(size: 11, weight: .medium).monospaced())
                            }
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.4))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewController.isClutchEngaged)
                    .opacity(viewController.isClutchEngaged ? 0.4 : 1.0)
                }
            }

            // Clutch toggle
            Button {
                ARManager.shared.actionStream.send(.toggleClutch)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: viewController.isClutchEngaged ? "lock.fill" : "lock.open")
                        .font(.system(size: 11))
                    Text(viewController.isClutchEngaged ? "Release" : "Lock")
                        .font(.system(size: 11, weight: .medium).monospaced())
                }
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(viewController.isClutchEngaged ? Color.green.opacity(0.4) : Color.white.opacity(0.16))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(!viewController.robotBasePlaced || viewController.isPlacingBaseMode)
            .opacity((viewController.robotBasePlaced && !viewController.isPlacingBaseMode) ? 1.0 : 0.4)

            // Reset
            Button {
                ARManager.shared.actionStream.send(.resetGhostArm)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11))
                    Text("Reset")
                        .font(.system(size: 11, weight: .medium).monospaced())
                }
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.16))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(!viewController.isGhostVisible && !viewController.isPlacingBaseMode)
            .opacity((viewController.isGhostVisible || viewController.isPlacingBaseMode) ? 1.0 : 0.4)
        }
        .padding(10)
        .background(Color.black.opacity(0.6))
        .cornerRadius(8)
    }
}

// MARK: - Teleop Control Panel

struct TeleopControlPanel: View {
    @ObservedObject var viewController: ViewController
    @ObservedObject var bonjourManager: BonjourManager

    private var isConnected: Bool {
        viewController.connectionStatus == .connected
    }

    private var teleopStatusColor: Color {
        if isConnected { return .green }
        if !bonjourManager.teleopServers.isEmpty { return .yellow }
        return .gray
    }

    private var teleopStatusText: String {
        if isConnected { return "Teleop Ready" }
        if !bonjourManager.teleopServers.isEmpty { return "Teleop Found" }
        return "No Teleop"
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            // Connection status
            HStack(spacing: 6) {
                Circle()
                    .fill(teleopStatusColor)
                    .frame(width: 8, height: 8)
                Text(teleopStatusText)
                    .font(.system(size: 11, weight: .medium).monospaced())
                    .foregroundColor(.white.opacity(0.85))
            }

            // Clutch toggle button
            Button {
                ARManager.shared.actionStream.send(.toggleTeleopClutch)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: viewController.isTeleopClutchEngaged ? "hand.raised.fill" : "hand.raised")
                        .font(.system(size: 14))
                    Text(viewController.isTeleopClutchEngaged ? "Clutch ON" : "Clutch OFF")
                        .font(.system(size: 12, weight: .semibold).monospaced())
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(viewController.isTeleopClutchEngaged ? Color.green.opacity(0.5) : Color.white.opacity(0.16))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(!isConnected)
            .opacity(isConnected ? 1.0 : 0.4)
        }
        .padding(10)
        .background(Color.black.opacity(0.6))
        .cornerRadius(8)
    }
}

struct ARViewContainer: UIViewControllerRepresentable {

    @ObservedObject var viewController: ViewController

    func makeUIViewController(context: Context) -> ViewController {
        return self.viewController
    }

    func updateUIViewController(_ uiViewController: ViewController, context: Context) {
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
