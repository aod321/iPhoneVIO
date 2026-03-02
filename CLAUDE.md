# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

iOS ARKit app that streams VIO pose data (pose + JPEG) via TCP to a Python/Rust server, and overlays a real-time "ghost arm" AR visualization for robot teleoperation feasibility checking.

## Tech Stack

- **iOS**: Swift 5.0, SwiftUI, ARKit, ARSCNView (SceneKit), Model I/O, Accelerate, CoreHaptics, Network.framework
- **Minimum iOS**: 17.2 (Podfile) / 17.4 (project.pbxproj deployment target)
- **Dependencies**: CocoaPods present but currently no pods — Network.framework is built-in
- **Server**: Python with python-socketio/eventlet (legacy `socketio_server.py`); primary server is rapid_driver (external Rust/axum binary)

## Essential Commands

```bash
# Install CocoaPods (required after git clone even if no pods are active)
pod install

# Open project — MUST use workspace, not .xcodeproj
open iPhoneVIO.xcworkspace

# Build for device (no simulator — ARKit requires physical device)
xcodebuild -workspace iPhoneVIO.xcworkspace -scheme iPhoneVIO -sdk iphoneos build

# Run unit tests (note: some tests are out of sync with current model fields)
xcodebuild -workspace iPhoneVIO.xcworkspace -scheme iPhoneVIO test

# Legacy Python server (Socket.IO, port 5555)
python3 -m venv .venv && source .venv/bin/activate
pip install python-socketio eventlet numpy
python socketio_server.py
```

## Architecture

### Action Bus Pattern
UI (ContentView) sends actions via `ARManager.shared.actionStream` (Combine `PassthroughSubject<ARAction, Never>`). `ViewController` (in ARSessionManager.swift) subscribes and handles all actions. This is the sole communication path from UI to the AR/networking layer.

### Core Data Flow: VIO Streaming
ARKit frame → `ViewController.session(_:didUpdate:)` → JPEG compress on background `jpegQueue` → `FramePacket.toBytes()` → `NetworkClient.sendFrame()` → TCP binary stream. Backpressure: frames are dropped if `NetworkClient.isSending` is true.

Binary frame format: `[8B header: 4B payload_len + 1B msg_type + 3B reserved] [4B jpeg_size] [64B transform column-major float32×16] [8B device_ts] [8B wall_clock] [jpeg_data]`. Message types: `0x00` sessionMetadata (JSON), `0x01` frameData (binary).

### FeasibleCap (Ghost Arm) Pipeline
Lazy-initialized on first `.startBasePlacement` / `.startArucoPlacement` action (`initFeasibleCapIfNeeded()`). Per-frame pipeline runs at 60 Hz only when clutch is engaged:
1. Camera displacement delta (world coords) → transform to robot base coords
2. `IKSolver.solve()` — DLS IK with warm start, Accelerate `sgesv_` for the 6×6 linear solve
3. `RobotRenderer.updateTransforms()` — apply FK link transforms to SceneKit nodes
4. `FeasibilityChecker.evaluate()` — IK convergence + joint position limits + velocity limits
5. `HapticManager` — continuous haptic on infeasible, transient pulse on state transition

Ghost arm: green (feasible) / red (infeasible). Robot is RM75 (7-DoF) with a fixed gripper on Link7.

### Teleoperation (Clutch) Mechanism
When clutch is engaged, `clutchCameraRef` and `clutchEERef` snapshot the current camera pose and end-effector pose. Each frame computes:
- Position delta: `dp_world = camera_current - camera_ref` → rotate into base frame
- Rotation delta: `dR = curRot * refRot^T` → rotate into base frame
- Target EE pose = reference EE + deltas → IK solve

### ArUco Marker Detection (Pure Swift, no OpenCV)
`ArucoDetector` pipeline: Y-plane extraction → vImage downsample (4x) → multi-window adaptive threshold → Moore boundary tracing → Ramer-Douglas-Peucker polygon approximation → quad filtering → perspective correction (homography via `sgesv_`) → 4×4 bit decode with Otsu threshold → dictionary match (DICT_4X4_50, Hamming ≤ 2) → `PnPSolver` (homography decomposition + SVD orthogonalization). Runs on background `detectQueue`, skips frames when busy.

### Two Base Placement Modes
- **Manual**: ARKit plane-detection raycast from screen center; yaw defaults to face away from camera
- **ArUco tag** (`targetArucoId = 13`): per-frame marker detection drives placement continuously; yaw extracted from marker's X-axis projected onto XZ plane

### Network Discovery
`BonjourManager` advertises `_iphonevio._tcp` (so rapid_driver finds the phone) and browses for `_vioserver._tcp` (auto-connect for data streaming) and `_rapiddriver._tcp` (HTTP control API for recording). Auto-reconnect on disconnect is handled in `ContentView` via `onChange(of: connectionStatus)`.

### Recording Management
`RecordingController` polls `rapid_driver` HTTP API every 2s for device ready status. `DataManagementController` handles recordings CRUD and replay. See `docs/recording_management_api.md` for the full API spec.

### Communication with rapid_driver (Raspberry Pi)

The iPhone communicates with `rapid_driver` (a Rust device orchestration daemon, typically on a Raspberry Pi) through three channels: mDNS discovery, TCP binary streaming, and HTTP REST API.

#### mDNS Service Discovery (`BonjourManager.swift`)

| Direction | Service Type | Purpose |
|-----------|-------------|---------|
| **Advertise** | `_iphonevio._tcp` | Phone announces itself; rapid_driver discovers and spawns `node_iphone` process |
| **Browse** | `_vioserver._tcp` | Discover TCP data streaming servers; auto-connect via `NetworkClient` |
| **Browse** | `_rapiddriver._tcp` | Discover rapid_driver HTTP API (default port 7400); resolves to `rapidDriverURL` |

iPhone advertises with service name `"{deviceModel}-iPhoneVIO"` and TXT records: `sessionId`, `deviceModel`, `appVersion`. The `_rapiddriver._tcp` resolver forces IPv4 (`ipOptions.version = .v4`) to avoid link-local IPv6 issues.

#### TCP Binary Stream Pipeline

Full data path: iPhone → TCP → `node_iphone` process → msgpack → ZMQ PUB (`tcp://127.0.0.1:5563`) → RecorderCore ZMQ SUB → MCAP file.

`NetworkClient.swift` uses `NWConnection` with TCP `noDelay = true`. Backpressure: frames are dropped if `isSending` is true. The binary frame format is documented above in "Core Data Flow: VIO Streaming".

On the rapid_driver side:
1. rapid_driver discovers `_iphonevio._tcp` and spawns `node_iphone` with env var `DEVICE_ADDR={ip}:{port}`
2. `node_iphone` connects to iPhone's TCP port, decodes binary frames, re-encodes as msgpack
3. `node_iphone` publishes on a ZMQ PUB socket (default port 5563, configurable via `--data-port`)
4. During recording, rapid_driver's RecorderCore subscribes via ZMQ SUB and writes to MCAP (Zstd compression)
5. Heartbeat: `node_iphone` writes JSON to `~/.local/state/rapid_driver/heartbeat/{device_name}.json` (stale threshold 3s)

#### HTTP API Endpoints (called by iOS)

All endpoints use `baseURL` resolved from `_rapiddriver._tcp` Bonjour discovery. Error responses: `{"error": "..."}`.

**RecordingController.swift** (polls every 2s):

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/ready` | Device readiness: `{"ready": bool, "online": int, "total": int}` |
| `GET` | `/devices` | Device node status list (name, discovered, heartbeat_ok, process_running, pid, backend, address) |
| `POST` | `/recording/start` | Start recording: `{"session_id": "<UUID>"}` |
| `POST` | `/recording/stop` | Stop recording: `{}` |
| `POST` | `/devices/{name}/restart` | Restart a device node (blocked during recording) |

**DataManagementController.swift** (replay polls every 1s):

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/recordings` | List recordings with disk usage: `{recordings: [...], total_size_bytes, disk_free_bytes}` |
| `DELETE` | `/recordings/{session_id}` | Delete single recording |
| `POST` | `/recordings/delete_batch` | Batch delete: `{"session_ids": [...]}` |
| `POST` | `/recordings/{session_id}/replay` | Start replay: `{}` |
| `POST` | `/replay/stop` | Stop replay: `{}` |
| `GET` | `/replay/status` | Replay progress: `{active, progress, elapsed_secs, total_secs, speed}` |

#### rapid_driver Registry Configuration

iPhone is registered as an mDNS device in `~/.config/rapid_driver/registry.toml`:
```toml
[[device]]
name = "iphone"
backend = "mdns"
service_type = "_iphonevio._tcp.local."
on_attach = "node_iphone --data-port 5563"
sensor_type = "video"
```

## Project Structure

```
iPhoneVIO/
├── iPhoneVIO/                  # iOS app source
│   ├── ContentView.swift       # SwiftUI root: AR view + all overlay panels (~800 lines)
│   ├── ARSessionManager.swift  # ViewController: ARSCNView, ARSessionDelegate, all FeasibleCap + ArUco logic (~1100 lines, largest file)
│   ├── ARManager.swift         # Singleton Combine action stream
│   ├── ARAction.swift          # Action enum (connect, disconnect, FeasibleCap actions)
│   ├── NetworkClient.swift     # Raw TCP client: binary frame protocol
│   ├── BonjourManager.swift    # mDNS advertising + service discovery
│   ├── ArucoDetector.swift     # Pure Swift ArUco marker detection pipeline
│   ├── ArucoDictionary.swift   # DICT_4X4_50 (50 markers, 4 rotations, Hamming matching)
│   ├── PnPSolver.swift         # Planar marker PnP via homography + SVD orthogonalization
│   ├── IKSolver.swift          # DLS IK + FK (7-DoF, Accelerate sgesv_)
│   ├── RobotModel.swift        # Value types: JointDef, LinkDef, RobotKinematics
│   ├── URDFParser.swift        # SAX XML parser → RobotKinematics
│   ├── RobotRenderer.swift     # SceneKit ghost arm: STL mesh loading, FK updates, feasibility coloring
│   ├── FeasibilityChecker.swift  # IK convergence + joint/velocity limits check
│   ├── HapticManager.swift     # CoreHaptics: continuous warning + transient pulse
│   ├── RecordingController.swift  # HTTP client for rapid_driver recording/device API
│   ├── DataManagementController.swift  # HTTP client for recordings CRUD + replay
│   ├── DataManagementView.swift  # SwiftUI: MCAP file browser, delete, replay
│   ├── RecordingItem.swift     # Codable data models for recording API
│   ├── OrientationCubeView.swift  # Live SCNView orientation cube (top-right HUD)
│   └── Resources/
│       ├── RM75/               # rm_75.urdf + base_link.STL, link1-7.STL
│       └── gripper/            # base_link.stl, gripper_left_1_1.stl, gripper_right_1_1.stl
├── iPhoneVIOTests/             # Unit tests (currently out of sync with model fields)
├── socketio_server.py          # Legacy Python server (Socket.IO, port 5555)
├── docs/
│   ├── feasiblecap_feature_gap.md   # Feature roadmap vs paper (Chinese)
│   └── recording_management_api.md  # rapid_driver HTTP API spec (Chinese)
├── Podfile
└── iPhoneVIO.xcworkspace       # MUST use this (not .xcodeproj)
```

## Critical Constraints

- **No simulator**: ARKit requires a real iOS device
- **Always use `.xcworkspace`**: CocoaPods integration
- **Landscape only**: `ViewController` and `AppDelegate` both lock to landscape orientation
- **FeasibleCap requires horizontal surface**: manual base placement uses ARKit plane detection raycast
- **STL scale detection**: `RobotRenderer` auto-detects mm vs m from bounding box (max dimension >100 → scale ×0.001). Gripper meshes are always treated as mm (hardcoded 0.001 scale).
- **URDF parsing**: uses `Foundation.XMLParser` (SAX). `XMLDocument` is not available on iOS.
- **Column-major transforms**: Swift `simd_float4x4` is column-major throughout. The `makeTransform(xyz:rpy:)` helper uses ZYX Euler convention. Python server transposes to row-major on decode.
- **Coordinate convention**: ARKit world frame is Y-up. Robot URDF is Z-up. `buildBaseTransform()` applies a -90° X rotation (`zUpToYUp`) to bridge between them.
- **ArUco PnP convention**: `PnPSolver` returns OpenCV convention (Y-down, Z-forward). A `flipYZ` diagonal matrix (1, -1, -1, 1) converts to ARKit camera frame before applying `cameraTransform`.

## Verification

After iOS changes:
1. Build succeeds (`xcodebuild ... -sdk iphoneos build` — requires a physical device target)
2. FeasibleCap: base placement finds a horizontal surface, ghost arm appears, clutch toggle works, haptic fires on feasibility state change
3. Data stream: mDNS discovers server, green status dot, server logs show incoming frames
4. ArUco placement: marker ID 13 detected, yellow overlay tracks marker on screen, robot base follows marker pose
