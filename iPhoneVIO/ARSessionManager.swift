//
//  ARSessionManager.swift
//  iPhoneVIO
//
//  Created by David Gao on 4/26/24.
//

import Foundation
import ARKit
import SceneKit
import Combine
import UIKit

class ViewController: UIViewController, ARSessionDelegate, ObservableObject {
    @Published var displayString: String = ""
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var displayMode: Int = 0
    @Published var trackingStatus: String = ""
    @Published var cameraTransform: simd_float4x4 = matrix_identity_float4x4

    var scnView: ARSCNView!
    let networkClient = NetworkClient()
    var prevTimestamp: Double = 0.0

    private let jpegQueue = DispatchQueue(label: "com.iphoneVIO.jpeg", qos: .userInitiated)
    private let frameProcessingLock = NSLock()
    private let ciContext = CIContext()
    private var sessionId = UUID().uuidString
    private var hasSentMetadata = false
    private var jpegQuality: CGFloat = 0.7
    private var isFrameProcessing = false

    // AR guides
    private var originNode: SCNNode?
    private var normalFrameCount: Int = 0
    private let normalFrameThreshold: Int = 10

    // FeasibleCap
    private var robotModel: RobotKinematics?
    private var ikSolver: IKSolver?
    private var robotRenderer: RobotRenderer?
    private var feasibilityChecker: FeasibilityChecker?
    private var hapticManager: HapticManager?
    private var previousJointAngles: [Float] = Array(repeating: 0, count: 7)

    @Published var isClutchEngaged = false
    @Published var isTeleopClutchEngaged = false
    @Published var isGhostVisible = false
    @Published var feasibilityState: FeasibilityState = .feasible
    @Published var feasibilityReason: String = ""
    @Published var robotBasePlaced = false
    @Published var isPlacingBaseMode = false
    @Published var hasPlacementPreview = false
    @Published var placementHeightOffsetMeters: Float = 0
    @Published var isArucoMarkerDetected = false
    @Published var arucoDebugText: String = ""
    @Published var distanceToEE: Float = -1  // <0 means unavailable
    @Published var angleToEE: Float = -1    // degrees, <0 means unavailable

    private var isArucoPlacementMode = false
    private var arucoDetector: ArucoDetector?
    private var lastArucoPoseLogTimestamp: TimeInterval = 0
    private var markerVizNode: SCNNode?
    private let targetArucoId: Int = 13
    private var arucoMissCount: Int = 0
    private let arucoMissTolerance: Int = 15
    private let arucoOverlayLayer = CAShapeLayer()
    private let arucoXAxisLayer = CAShapeLayer()
    private let arucoYAxisLayer = CAShapeLayer()
    private let arucoCenterLayer = CAShapeLayer()

    private var robotBaseTransform = matrix_identity_float4x4
    private var isPlacingBase = false
    private var feasibleCapInitialized = false
    private var hasStartedARSession = false
    private var pendingBaseTransform: simd_float4x4?
    private var pendingBaseHitPosition: SIMD3<Float>?
    private var pendingBaseYaw: Float?
    private var pendingBaseHeightOffset: Float = 0
    private var baseTransformBeforePlacement: simd_float4x4?

    /// RM75 Home pose (degrees): -100, -38, -156, 50, -15, 85, 90
    private let homeJointAnglesDeg: [Float] = [-100, -38, -156, 50, -15, 85, 0]
    private var homeJointAngles: [Float] {
        homeJointAnglesDeg.map { $0 * .pi / 180 }
    }

    /// Initial pose after placement confirmed — uses Home pose directly
    private var placementInitJointAngles: [Float] {
        homeJointAngles
    }

    // Teleop anchors (snapshot on engage)
    private var clutchCameraRef: simd_float4x4?
    private var clutchEERef: simd_float4x4?

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    override var shouldAutorotate: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()

        scnView = ARSCNView(frame: view.bounds)
        scnView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scnView.debugOptions.insert(.showFeaturePoints)
        view.addSubview(scnView)
        setupArucoOverlayLayers()

        networkClient.onStatusChange = { [weak self] status in
            DispatchQueue.main.async {
                self?.connectionStatus = status
            }
        }
        subscribeToActionStream()

        // Tap gesture for base placement (FeasibleCap)
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        scnView.addGestureRecognizer(tapGesture)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        arucoOverlayLayer.frame = scnView.bounds
        arucoXAxisLayer.frame = scnView.bounds
        arucoYAxisLayer.frame = scnView.bounds
        arucoCenterLayer.frame = scnView.bounds
    }

    func setupARSession() {
        hasSentMetadata = false
        sessionId = UUID().uuidString

        // Start Bonjour advertising + browsing instead of connecting immediately
        let deviceModel = Self.deviceModelIdentifier()
        BonjourManager.shared.startAll(sessionId: sessionId, deviceModel: deviceModel)

        self.publishPose = false  // Wait for connection via discovered server or manual connect
        scnView.session.delegate = self
        let configuration = createARConfiguration()
        scnView.session.run(configuration)
        setupARGuides()
    }

    private func createARConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        return configuration
    }

    // MARK: - AR Visual Guides

    func setupARGuides() {
        originNode?.removeFromParentNode()

        let origin = SCNNode()
        let axisLength: CGFloat = 0.15
        let axisThick: CGFloat = 0.004

        func unlitMaterial(_ color: UIColor) -> SCNMaterial {
            let mat = SCNMaterial()
            mat.diffuse.contents = color
            mat.lightingModel = .constant
            return mat
        }

        // X — red
        let xAxis = SCNNode(geometry: SCNBox(width: axisLength, height: axisThick, length: axisThick, chamferRadius: 0))
        xAxis.geometry?.firstMaterial = unlitMaterial(.red)
        xAxis.position = SCNVector3(axisLength / 2, 0, 0)
        origin.addChildNode(xAxis)

        // Y — green
        let yAxis = SCNNode(geometry: SCNBox(width: axisThick, height: axisLength, length: axisThick, chamferRadius: 0))
        yAxis.geometry?.firstMaterial = unlitMaterial(.green)
        yAxis.position = SCNVector3(0, axisLength / 2, 0)
        origin.addChildNode(yAxis)

        // Z — blue
        let zAxis = SCNNode(geometry: SCNBox(width: axisThick, height: axisThick, length: axisLength, chamferRadius: 0))
        zAxis.geometry?.firstMaterial = unlitMaterial(.blue)
        zAxis.position = SCNVector3(0, 0, axisLength / 2)
        origin.addChildNode(zAxis)

        // Origin sphere
        let sphere = SCNNode(geometry: SCNSphere(radius: 0.008))
        sphere.geometry?.firstMaterial = unlitMaterial(.white)
        origin.addChildNode(sphere)

        scnView.scene.rootNode.addChildNode(origin)
        originNode = origin
    }

    // MARK: - Action Stream

    private var cancellables: Set<AnyCancellable> = []
    private var publishPose: Bool = false

    func subscribeToActionStream() {

        ARManager.shared
            .actionStream
            .sink { [weak self] action in
                switch action {
                    case .resetOrigin:
                        guard let self = self else { return }
                        self.hasSentMetadata = false
                        self.sessionId = UUID().uuidString
                        self.isArucoMarkerDetected = false
                        self.lastArucoPoseLogTimestamp = 0
                        self.arucoMissCount = 0
                        self.clearArucoVisuals()
                        let configuration = self.createARConfiguration()
                        self.scnView.session.run(configuration, options: .resetTracking)
                        self.setupARGuides()
                    case .disconnect:
                        self?.publishPose = false
                        self?.networkClient.disconnect()
                    case .connectToEndpoint(let endpoint):
                        guard let self = self else { return }
                        self.publishPose = false
                        self.networkClient.disconnect()
                        self.hasSentMetadata = false
                        self.sessionId = UUID().uuidString
                        print("Connecting to discovered endpoint: \(endpoint)")
                        self.networkClient.connect(endpoint: endpoint)
                        self.publishPose = true

                    // FeasibleCap actions
                    case .startArucoPlacement:
                        guard let self = self else { return }
                        self.isArucoPlacementMode = true
                        self.arucoMissCount = 0
                        print("[ArUco] Enter ArUco placement mode.")
                        self.startBasePlacement()
                    case .startBasePlacement:
                        guard let self = self else { return }
                        self.isArucoPlacementMode = false
                        self.arucoMissCount = 0
                        print("[ArUco] Enter manual placement mode.")
                        self.startBasePlacement()
                    case .confirmBasePlacement:
                        self?.confirmBasePlacement()
                    case .cancelBasePlacement:
                        self?.cancelBasePlacement()
                    case .rotateBaseYaw(let delta):
                        self?.rotatePlacementYaw(by: delta)
                    case .adjustBaseHeight(let delta):
                        self?.adjustPlacementHeight(by: delta)
                    case .toggleClutch:
                        guard let self = self else { return }
                        self.isClutchEngaged.toggle()
                        if self.isClutchEngaged {
                            // Record anchors
                            self.clutchCameraRef = self.cameraTransform
                            if let solver = self.ikSolver {
                                let fk = solver.forwardKinematics(self.previousJointAngles)
                                self.clutchEERef = fk.eePose
                            }
                            self.feasibilityChecker?.reset()
                        } else {
                            self.clutchCameraRef = nil
                            self.clutchEERef = nil
                            self.hapticManager?.stopWarning()
                        }
                    case .setZeroPose:
                        self?.setJointAngles(Array(repeating: 0, count: 7))
                    case .setHomePose:
                        self?.setJointAngles(self?.homeJointAngles ?? [])
                    case .resetGhostArm:
                        guard let self = self else { return }
                        self.robotRenderer?.hide()
                        self.isGhostVisible = false
                        self.isClutchEngaged = false
                        self.isPlacingBase = false
                        self.isPlacingBaseMode = false
                        self.hasPlacementPreview = false
                        self.robotBasePlaced = false
                        self.feasibilityState = .feasible
                        self.pendingBaseTransform = nil
                        self.pendingBaseHitPosition = nil
                        self.pendingBaseYaw = nil
                        self.pendingBaseHeightOffset = 0
                        self.placementHeightOffsetMeters = 0
                        self.baseTransformBeforePlacement = nil
                        self.clutchCameraRef = nil
                        self.clutchEERef = nil
                        self.previousJointAngles = Array(repeating: 0, count: 7)
                        self.distanceToEE = -1
                        self.angleToEE = -1
                        self.isArucoPlacementMode = false
                        self.isArucoMarkerDetected = false
                        self.lastArucoPoseLogTimestamp = 0
                        self.arucoMissCount = 0
                        self.clearArucoVisuals()
                        self.feasibilityChecker?.reset()
                        self.hapticManager?.stopWarning()
                    case .correctToCamera:
                        self?.correctGhostArmToCamera()
                    case .toggleTeleopClutch:
                        guard let self = self else { return }
                        self.isTeleopClutchEngaged.toggle()
                        let cmd = self.isTeleopClutchEngaged ? "clutch_engage" : "clutch_disengage"
                        self.networkClient.sendTeleopCommand(cmd)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let transform = frame.camera.transform
        let timestamp = frame.timestamp
        let wallClock = Date().timeIntervalSince1970
        let fps = prevTimestamp > 0 ? 1 / (timestamp - prevTimestamp) : 0

        switch displayMode {
        case 1:
            let euler = frame.camera.eulerAngles
            let roll = euler.x * 180 / .pi
            let pitch = euler.y * 180 / .pi
            let yaw = euler.z * 180 / .pi
            displayString = String(format: "x:%.3f y:%.3f z:%.3f r:%.1f p:%.1f yaw:%.1f fps:%.0f",
                                   transform[3][0], transform[3][1], transform[3][2],
                                   roll, pitch, yaw, fps)
        case 2:
            displayString = String(format: "fps: %.0f", fps)
        default:
            displayString = String(format: "x:%.4f y:%.4f z:%.4f fps:%.0f",
                                   transform[3][0], transform[3][1], transform[3][2], fps)
        }

        cameraTransform = transform
        prevTimestamp = timestamp

        // Per-frame tracking quality (debounce: clear after 10 consecutive normal frames)
        switch frame.camera.trackingState {
        case .normal:
            normalFrameCount += 1
            if normalFrameCount >= normalFrameThreshold {
                trackingStatus = ""
            }
        case .limited(let reason):
            normalFrameCount = 0
            switch reason {
            case .excessiveMotion:      trackingStatus = "Too fast!"
            case .insufficientFeatures: trackingStatus = "Low features"
            case .initializing:         trackingStatus = "Initializing"
            case .relocalizing:         trackingStatus = "Relocalizing"
            @unknown default:           trackingStatus = "Limited"
            }
        case .notAvailable:
            normalFrameCount = 0
            trackingStatus = "No tracking"
        }

        // Native ArUco detection (runs on background queue)
        if isArucoPlacementMode && isPlacingBase {
            if arucoDetector == nil { arucoDetector = ArucoDetector() }
            let imageSize = CGSize(
                width: CVPixelBufferGetWidthOfPlane(frame.capturedImage, 0),
                height: CVPixelBufferGetHeightOfPlane(frame.capturedImage, 0)
            )
            let displayTransform = frame.displayTransform(for: .landscapeRight, viewportSize: scnView.bounds.size)
            arucoDetector?.detect(
                pixelBuffer: frame.capturedImage,
                intrinsics: frame.camera.intrinsics,
                cameraTransform: frame.camera.transform
            ) { [weak self] result in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard self.isArucoPlacementMode && self.isPlacingBase else { return }
                    if let detector = self.arucoDetector {
                        let d = detector.lastDebugInfo
                        let bitsStr = d.decodedBits.map { String(format: "0x%04X", $0) } ?? "-"
                        self.arucoDebugText = "C:\(d.contourCount) Q:\(d.quadCount) D:\(d.candidateCount) bits:\(bitsStr) border:\(d.borderOK ? "Y" : "N") id:\(d.matchedId.map { String($0) } ?? "-")"
                    }
                    if let result {
                        self.arucoDebugText += " hit:\(result.markerId)"
                        if result.markerId == self.targetArucoId {
                        self.arucoMissCount = 0
                        self.isArucoMarkerDetected = true
                            self.updateArucoScreenOverlay(
                                corners: result.corners,
                                imageSize: imageSize,
                                displayTransform: displayTransform
                            )
                            self.updateArucoBasePlacement(worldTransform: result.worldTransform)
                        } else {
                        self.arucoMissCount += 1
                        if self.arucoMissCount > self.arucoMissTolerance {
                            self.isArucoMarkerDetected = false
                            self.clearArucoScreenOverlay()
                        }
                    }
                }
            }
        }
        }

        updatePlacementPreview(cameraTransform: transform)

        // Update distance from camera to EE (for "correct" button)
        updateDistanceToEE(cameraTransform: transform)

        // FeasibleCap ghost arm update
        updateGhostArm(cameraTransform: transform, timestamp: timestamp)

        guard publishPose else { return }

        // Send session metadata once (on first frame after connect)
        if !hasSentMetadata {
            let intrinsics = frame.camera.intrinsics
            let resolution = frame.camera.imageResolution
            let metadata = SessionMetadata(
                sessionId: sessionId,
                deviceModel: Self.deviceModelIdentifier(),
                imageWidth: Int(resolution.width),
                imageHeight: Int(resolution.height),
                focalLengthX: intrinsics[0][0],
                focalLengthY: intrinsics[1][1],
                principalPointX: intrinsics[2][0],
                principalPointY: intrinsics[2][1],
                arkitTimestamp0: timestamp,
                wallClock0: wallClock
            )
            networkClient.sendSessionMetadata(metadata)
            hasSentMetadata = true
        }

        // Backpressure: skip frame if still sending previous
        guard !networkClient.isSending else { return }
        guard beginFrameProcessing() else { return }

        // Compress JPEG on background queue
        let pixelBuffer = frame.capturedImage
        jpegQueue.async { [weak self] in
            guard let self else { return }
            defer { self.endFrameProcessing() }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let jpeg = self.ciContext.jpegRepresentation(
                of: ciImage,
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: self.jpegQuality]
            ) else { return }
            let packet = FramePacket(
                transform: transform,
                deviceTimestamp: timestamp,
                wallClock: wallClock,
                jpegData: jpeg
            )
            self.networkClient.sendFrame(packet)
        }
    }

    // MARK: - Native ArUco Detection

    private func updateArucoBasePlacement(worldTransform: simd_float4x4) {
        let position = SIMD3<Float>(
            worldTransform.columns.3.x,
            worldTransform.columns.3.y,
            worldTransform.columns.3.z
        )
        pendingBaseHitPosition = position

        // Extract yaw from marker's X-axis projected onto XZ plane
        let markerXAxis = SIMD3<Float>(
            worldTransform.columns.0.x,
            0,
            worldTransform.columns.0.z
        )
        let len = length(markerXAxis)
        if len > 1e-4 {
            let normalized = markerXAxis / len
            pendingBaseYaw = atan2(normalized.x, normalized.z)
        }
        let yaw = pendingBaseYaw ?? 0

        let transform = buildBaseTransform(
            hitPosition: position,
            yaw: yaw,
            heightOffset: pendingBaseHeightOffset
        )
        pendingBaseTransform = transform
        hasPlacementPreview = true

        let now = Date().timeIntervalSince1970
        if now - lastArucoPoseLogTimestamp >= 1.0 {
            print(String(format: "[ArUco] Pose update x=%.3f y=%.3f z=%.3f yaw=%.1fdeg",
                         position.x, position.y, position.z, yaw * 180 / .pi))
            lastArucoPoseLogTimestamp = now
        }

        robotRenderer?.setBaseTransform(transform)
        robotRenderer?.show()
        isGhostVisible = true
        feasibilityState = .feasible
        robotRenderer?.setFeasibilityState(.feasible)

        // Update marker visualization (frame + axes)
        updateMarkerVisualization(worldTransform: worldTransform)
    }

    // MARK: - Marker Visualization (3D frame + axes on detected marker)

    private func updateMarkerVisualization(worldTransform: simd_float4x4) {
        if markerVizNode == nil {
            markerVizNode = createMarkerVizNode()
            scnView.scene.rootNode.addChildNode(markerVizNode!)
            print("[ArUco] Marker viz node created and added to scene")
        }
        markerVizNode?.simdTransform = worldTransform
        markerVizNode?.isHidden = false
    }

    private func setupArucoOverlayLayers() {
        func configureLineLayer(_ layer: CAShapeLayer, color: UIColor, width: CGFloat) {
            layer.strokeColor = color.cgColor
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = width
            layer.lineJoin = .round
            layer.lineCap = .round
            layer.zPosition = 10_000
        }

        configureLineLayer(arucoOverlayLayer, color: .yellow, width: 4)
        arucoOverlayLayer.fillColor = UIColor.yellow.withAlphaComponent(0.15).cgColor
        configureLineLayer(arucoXAxisLayer, color: .red, width: 3)
        configureLineLayer(arucoYAxisLayer, color: .green, width: 3)

        arucoCenterLayer.strokeColor = UIColor.white.cgColor
        arucoCenterLayer.fillColor = UIColor.white.cgColor
        arucoCenterLayer.lineWidth = 1
        arucoCenterLayer.zPosition = 10_001

        scnView.layer.addSublayer(arucoOverlayLayer)
        scnView.layer.addSublayer(arucoXAxisLayer)
        scnView.layer.addSublayer(arucoYAxisLayer)
        scnView.layer.addSublayer(arucoCenterLayer)
    }

    private func updateArucoScreenOverlay(
        corners: [SIMD2<Float>],
        imageSize: CGSize,
        displayTransform: CGAffineTransform
    ) {
        guard corners.count == 4, imageSize.width > 0, imageSize.height > 0 else {
            clearArucoScreenOverlay()
            return
        }

        let normalized = corners.map {
            CGPoint(x: CGFloat($0.x) / imageSize.width, y: CGFloat($0.y) / imageSize.height)
        }

        let mappedDirect = normalized.map { $0.applying(displayTransform) }
        let mappedInverted = normalized.map { $0.applying(displayTransform.inverted()) }

        func inBoundsScore(_ points: [CGPoint]) -> Int {
            points.reduce(0) { partial, p in
                partial + ((0...1).contains(p.x) && (0...1).contains(p.y) ? 1 : 0)
            }
        }

        let directScore = inBoundsScore(mappedDirect)
        let invertedScore = inBoundsScore(mappedInverted)
        let mappedNorm = directScore >= invertedScore ? mappedDirect : mappedInverted
        let viewPoints = mappedNorm.map { p in
            CGPoint(x: p.x * scnView.bounds.width, y: p.y * scnView.bounds.height)
        }

        // Debug: log screen coordinates once per second
        let now = Date().timeIntervalSince1970
        if now - lastArucoPoseLogTimestamp >= 0.5 {
            let nStr = normalized.map { String(format: "(%.3f,%.3f)", $0.x, $0.y) }.joined(separator: " ")
            let dStr = mappedDirect.map { String(format: "(%.2f,%.2f)", $0.x, $0.y) }.joined(separator: " ")
            let vStr = viewPoints.map { String(format: "(%.0f,%.0f)", $0.x, $0.y) }.joined(separator: " ")
            print("[ArUco-2D] norm=[\(nStr)] direct=[\(dStr)] dScore=\(directScore) iScore=\(invertedScore) view=[\(vStr)] bounds=\(scnView.bounds.size)")
        }

        let boxPath = UIBezierPath()
        boxPath.move(to: viewPoints[0])
        boxPath.addLine(to: viewPoints[1])
        boxPath.addLine(to: viewPoints[2])
        boxPath.addLine(to: viewPoints[3])
        boxPath.close()
        arucoOverlayLayer.path = boxPath.cgPath

        let center = CGPoint(
            x: (viewPoints[0].x + viewPoints[1].x + viewPoints[2].x + viewPoints[3].x) * 0.25,
            y: (viewPoints[0].y + viewPoints[1].y + viewPoints[2].y + viewPoints[3].y) * 0.25
        )
        let xEnd = CGPoint(
            x: (viewPoints[0].x + viewPoints[1].x) * 0.5,
            y: (viewPoints[0].y + viewPoints[1].y) * 0.5
        )
        let yEnd = CGPoint(
            x: (viewPoints[0].x + viewPoints[3].x) * 0.5,
            y: (viewPoints[0].y + viewPoints[3].y) * 0.5
        )

        let xPath = UIBezierPath()
        xPath.move(to: center)
        xPath.addLine(to: xEnd)
        arucoXAxisLayer.path = xPath.cgPath

        let yPath = UIBezierPath()
        yPath.move(to: center)
        yPath.addLine(to: yEnd)
        arucoYAxisLayer.path = yPath.cgPath

        let centerDotPath = UIBezierPath(arcCenter: center, radius: 4, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        arucoCenterLayer.path = centerDotPath.cgPath
    }

    private func clearArucoScreenOverlay() {
        arucoOverlayLayer.path = nil
        arucoXAxisLayer.path = nil
        arucoYAxisLayer.path = nil
        arucoCenterLayer.path = nil
    }

    private func clearArucoVisuals() {
        markerVizNode?.isHidden = true
        arucoDebugText = ""
        isArucoMarkerDetected = false
        clearArucoScreenOverlay()
    }

    private func createMarkerVizNode() -> SCNNode {
        let root = SCNNode()
        root.name = "arucoMarkerViz"

        func unlitMat(_ color: UIColor) -> SCNMaterial {
            let m = SCNMaterial()
            m.diffuse.contents = color
            m.lightingModel = .constant
            m.isDoubleSided = true
            m.writesToDepthBuffer = false
            m.readsFromDepthBuffer = false
            return m
        }

        let markerSize: CGFloat = 0.16  // 16cm marker

        // Semi-transparent green filled plane on the marker surface (XY plane, Z=0)
        let plane = SCNPlane(width: markerSize, height: markerSize)
        plane.firstMaterial = unlitMat(UIColor(red: 0, green: 1, blue: 0, alpha: 0.3))
        let planeNode = SCNNode(geometry: plane)
        planeNode.renderingOrder = 100
        root.addChildNode(planeNode)

        // Bright green border — 4 edges using SCNPlane strips (visible from both sides)
        let borderW: CGFloat = 0.006  // 6mm wide border
        let borderMat = unlitMat(UIColor(red: 0, green: 1, blue: 0, alpha: 1.0))

        // Top edge
        let topPlane = SCNPlane(width: markerSize, height: borderW)
        topPlane.firstMaterial = borderMat
        let topNode = SCNNode(geometry: topPlane)
        topNode.simdPosition = SIMD3<Float>(0, Float(markerSize / 2), 0.001)
        topNode.renderingOrder = 101
        root.addChildNode(topNode)

        // Bottom edge
        let bottomPlane = SCNPlane(width: markerSize, height: borderW)
        bottomPlane.firstMaterial = borderMat
        let bottomNode = SCNNode(geometry: bottomPlane)
        bottomNode.simdPosition = SIMD3<Float>(0, Float(-markerSize / 2), 0.001)
        bottomNode.renderingOrder = 101
        root.addChildNode(bottomNode)

        // Left edge
        let leftPlane = SCNPlane(width: borderW, height: markerSize)
        leftPlane.firstMaterial = borderMat
        let leftNode = SCNNode(geometry: leftPlane)
        leftNode.simdPosition = SIMD3<Float>(Float(-markerSize / 2), 0, 0.001)
        leftNode.renderingOrder = 101
        root.addChildNode(leftNode)

        // Right edge
        let rightPlane = SCNPlane(width: borderW, height: markerSize)
        rightPlane.firstMaterial = borderMat
        let rightNode = SCNNode(geometry: rightPlane)
        rightNode.simdPosition = SIMD3<Float>(Float(markerSize / 2), 0, 0.001)
        rightNode.renderingOrder = 101
        root.addChildNode(rightNode)

        // Coordinate axes — using cylinders for better visibility
        let axisLen: Float = 0.10
        let axisRadius: CGFloat = 0.003

        // X axis — Red (along marker's X)
        let xCyl = SCNCylinder(radius: axisRadius, height: CGFloat(axisLen))
        xCyl.firstMaterial = unlitMat(.red)
        let xNode = SCNNode(geometry: xCyl)
        xNode.simdPosition = SIMD3<Float>(axisLen / 2, 0, 0)
        xNode.eulerAngles.z = -.pi / 2  // rotate cylinder to lie along X
        xNode.renderingOrder = 102
        root.addChildNode(xNode)

        // Y axis — Green
        let yCyl = SCNCylinder(radius: axisRadius, height: CGFloat(axisLen))
        yCyl.firstMaterial = unlitMat(UIColor(red: 0.2, green: 1.0, blue: 0.2, alpha: 1.0))
        let yNode = SCNNode(geometry: yCyl)
        yNode.simdPosition = SIMD3<Float>(0, axisLen / 2, 0)
        yNode.renderingOrder = 102
        root.addChildNode(yNode)

        // Z axis — Blue (pointing out of marker surface)
        let zCyl = SCNCylinder(radius: axisRadius, height: CGFloat(axisLen))
        zCyl.firstMaterial = unlitMat(.blue)
        let zNode = SCNNode(geometry: zCyl)
        zNode.simdPosition = SIMD3<Float>(0, 0, axisLen / 2)
        zNode.eulerAngles.x = .pi / 2  // rotate to lie along Z
        zNode.renderingOrder = 102
        root.addChildNode(zNode)

        // Origin sphere
        let sphere = SCNSphere(radius: 0.008)
        sphere.firstMaterial = unlitMat(.white)
        let sphereNode = SCNNode(geometry: sphere)
        sphereNode.renderingOrder = 103
        root.addChildNode(sphereNode)

        return root
    }

    // MARK: - FeasibleCap (lazy init on first base placement)

    private func initFeasibleCapIfNeeded() {
        guard !feasibleCapInitialized else { return }

        guard let urdfURL = Bundle.main.url(forResource: "rm_75", withExtension: "urdf", subdirectory: "RM75") else {
            print("[FeasibleCap] URDF not found in bundle")
            return
        }

        let parser = URDFParser()
        guard let model = parser.parse(url: urdfURL) else {
            print("[FeasibleCap] URDF parse failed")
            return
        }

        print("[FeasibleCap] Parsed robot '\(model.name)': \(model.dof) joints, \(model.links.count) links")
        for joint in model.joints {
            print("  \(joint.name): [\(joint.posLower), \(joint.posUpper)] vel=\(joint.velLimit)")
        }

        self.robotModel = model
        self.ikSolver = IKSolver(model: model)
        self.feasibilityChecker = FeasibilityChecker(joints: model.joints)
        self.hapticManager = HapticManager()

        let renderer = RobotRenderer(model: model)
        scnView.scene.rootNode.addChildNode(renderer.rootNode)
        self.robotRenderer = renderer
        self.feasibleCapInitialized = true
    }

    private func startBasePlacement() {
        baseTransformBeforePlacement = robotBasePlaced ? robotBaseTransform : nil
        isClutchEngaged = false
        robotBasePlaced = false
        isPlacingBase = true
        isPlacingBaseMode = true
        hasPlacementPreview = false
        pendingBaseTransform = nil
        pendingBaseHitPosition = nil
        pendingBaseYaw = nil
        pendingBaseHeightOffset = 0
        placementHeightOffsetMeters = 0

        guard prepareRendererForPlacementPreview() else {
            isPlacingBase = false
            isPlacingBaseMode = false
            if let previous = baseTransformBeforePlacement {
                robotBaseTransform = previous
                robotBasePlaced = true
                robotRenderer?.setBaseTransform(previous)
                robotRenderer?.show()
                isGhostVisible = true
            }
            baseTransformBeforePlacement = nil
            return
        }

        if isArucoPlacementMode {
            // In ArUco mode, skip raycast; placement comes from per-frame native detection
            print("[ArUco] Waiting for marker detection via native detector.")
            return
        }

        let center = CGPoint(x: scnView.bounds.midX, y: scnView.bounds.midY)
        _ = tryPreviewBase(at: center, cameraTransform: cameraTransform, logMiss: true)
    }

    private func confirmBasePlacement() {
        guard isPlacingBase else { return }
        guard let transform = pendingBaseTransform else {
            print("[FeasibleCap] Confirm failed: no preview pose yet.")
            return
        }

        robotBaseTransform = transform
        robotBasePlaced = true
        isPlacingBase = false
        isPlacingBaseMode = false
        hasPlacementPreview = false
        pendingBaseTransform = nil
        pendingBaseHitPosition = nil
        pendingBaseYaw = nil
        pendingBaseHeightOffset = 0
        placementHeightOffsetMeters = 0
        baseTransformBeforePlacement = nil
        arucoMissCount = 0

        // Use default post-placement pose instead of carrying over previous teleop/zero pose
        previousJointAngles = placementInitJointAngles

        robotRenderer?.setBaseTransform(transform)
        // Display at current joint angles (post-placement initial pose), no IK
        if let solver = ikSolver, let renderer = robotRenderer {
            let fk = solver.forwardKinematics(previousJointAngles)
            renderer.updateTransforms(fk)
            renderer.setFeasibilityState(.feasible)
        }
        feasibilityState = .feasible
        robotRenderer?.show()
        isGhostVisible = true
        clearArucoVisuals()
        print("[FeasibleCap] Base placement confirmed.")
    }

    private func cancelBasePlacement() {
        guard isPlacingBase else { return }

        isPlacingBase = false
        isPlacingBaseMode = false
        hasPlacementPreview = false
        pendingBaseTransform = nil
        pendingBaseHitPosition = nil
        pendingBaseYaw = nil
        pendingBaseHeightOffset = 0
        placementHeightOffsetMeters = 0
        isArucoPlacementMode = false
        lastArucoPoseLogTimestamp = 0
        arucoMissCount = 0
        clearArucoVisuals()

        if let previous = baseTransformBeforePlacement {
            robotBaseTransform = previous
            robotBasePlaced = true
            robotRenderer?.setBaseTransform(previous)
            robotRenderer?.show()
            isGhostVisible = true
            print("[FeasibleCap] Base placement canceled, restored previous base.")
        } else {
            robotBasePlaced = false
            robotRenderer?.hide()
            isGhostVisible = false
            print("[FeasibleCap] Base placement canceled.")
        }

        baseTransformBeforePlacement = nil
    }

    private func rotatePlacementYaw(by delta: Float) {
        guard isPlacingBase else { return }
        guard let hitPos = pendingBaseHitPosition else { return }
        let currentYaw = pendingBaseYaw ?? 0
        let newYaw = currentYaw + delta
        pendingBaseYaw = newYaw

        let rotatedTransform = buildBaseTransform(hitPosition: hitPos, yaw: newYaw, heightOffset: pendingBaseHeightOffset)
        pendingBaseTransform = rotatedTransform
        robotRenderer?.setBaseTransform(rotatedTransform)
        robotRenderer?.show()
        isGhostVisible = true
    }

    private func adjustPlacementHeight(by delta: Float) {
        guard isPlacingBase else { return }
        guard let hitPos = pendingBaseHitPosition else { return }

        let newOffset = max(-0.30, min(0.30, pendingBaseHeightOffset + delta))
        pendingBaseHeightOffset = newOffset
        placementHeightOffsetMeters = newOffset

        let transform = buildBaseTransform(hitPosition: hitPos, yaw: pendingBaseYaw ?? 0, heightOffset: newOffset)
        pendingBaseTransform = transform
        robotRenderer?.setBaseTransform(transform)
        robotRenderer?.show()
        isGhostVisible = true
    }

    private func updatePlacementPreview(cameraTransform: simd_float4x4) {
        guard isPlacingBase else { return }
        // In ArUco mode, placement updates come from per-frame native detection
        guard !isArucoPlacementMode else { return }
        let center = CGPoint(x: scnView.bounds.midX, y: scnView.bounds.midY)
        _ = tryPreviewBase(at: center, cameraTransform: cameraTransform, logMiss: false)
    }

    private func prepareRendererForPlacementPreview() -> Bool {
        initFeasibleCapIfNeeded()
        guard let solver = ikSolver,
              let renderer = robotRenderer else {
            print("[FeasibleCap] Initialization incomplete (solver/renderer missing).")
            return false
        }

        // Preview stage always uses post-placement initial pose, ensuring consistent pose before/after confirm
        let previewFK = solver.forwardKinematics(placementInitJointAngles)
        renderer.updateTransforms(previewFK)
        renderer.setFeasibilityState(.feasible)
        renderer.show()
        isGhostVisible = true
        return true
    }

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard isPlacingBase else { return }
        let location = gesture.location(in: scnView)
        _ = tryPreviewBase(at: location, cameraTransform: cameraTransform, logMiss: true)
    }

    @discardableResult
    private func tryPreviewBase(at location: CGPoint, cameraTransform: simd_float4x4, logMiss: Bool) -> Bool {
        guard isPlacingBase else { return false }

        // Try robust placement in descending confidence order.
        let targets: [ARRaycastQuery.Target] = [.existingPlaneGeometry, .existingPlaneInfinite, .estimatedPlane]
        var raycastResult: ARRaycastResult?
        for target in targets {
            guard let query = scnView.raycastQuery(from: location, allowing: target, alignment: .horizontal) else { continue }
            if let hit = scnView.session.raycast(query).first {
                raycastResult = hit
                break
            }
        }

        guard let result = raycastResult else {
            if logMiss {
                print("[FeasibleCap] Base placement miss: no horizontal surface hit, move phone and tap again.")
            }
            return false
        }

        guard prepareRendererForPlacementPreview() else {
            return false
        }

        let hitPos = SIMD3<Float>(
            result.worldTransform.columns.3.x,
            result.worldTransform.columns.3.y,
            result.worldTransform.columns.3.z
        )
        pendingBaseHitPosition = hitPos
        if pendingBaseYaw == nil {
            let camPos = SIMD3<Float>(
                cameraTransform.columns.3.x,
                cameraTransform.columns.3.y,
                cameraTransform.columns.3.z
            )
            var toCamera = camPos - hitPos
            toCamera.y = 0
            if length(toCamera) < 1e-4 {
                toCamera = SIMD3<Float>(0, 0, -1)
            } else {
                toCamera = normalize(toCamera)
            }
            // Default to keep the arm on the user-back side rather than facing the camera.
            pendingBaseYaw = atan2(toCamera.x, toCamera.z) + Float.pi
        }

        let transform = buildBaseTransform(hitPosition: hitPos, yaw: pendingBaseYaw ?? 0, heightOffset: pendingBaseHeightOffset)
        pendingBaseTransform = transform
        hasPlacementPreview = true
        robotRenderer?.setBaseTransform(transform)
        robotRenderer?.show()
        isGhostVisible = true
        feasibilityState = .feasible
        robotRenderer?.setFeasibilityState(.feasible)
        return true
    }

    private func buildBaseTransform(hitPosition: SIMD3<Float>, yaw: Float, heightOffset: Float) -> simd_float4x4 {
        let position = SIMD3<Float>(hitPosition.x, hitPosition.y + heightOffset, hitPosition.z)
        let translation = makeTransform(xyz: position, rpy: .zero)
        let yawRot = makeTransform(xyz: .zero, rpy: SIMD3<Float>(0, yaw, 0))
        let zUpToYUp = makeTransform(xyz: .zero, rpy: SIMD3<Float>(-Float.pi * 0.5, 0, 0))
        return translation * yawRot * zUpToYUp
    }

    private func beginFrameProcessing() -> Bool {
        frameProcessingLock.lock()
        defer { frameProcessingLock.unlock() }
        if isFrameProcessing {
            return false
        }
        isFrameProcessing = true
        return true
    }

    private func endFrameProcessing() {
        frameProcessingLock.lock()
        isFrameProcessing = false
        frameProcessingLock.unlock()
    }

    private func setJointAngles(_ angles: [Float]) {
        guard robotBasePlaced,
              let solver = ikSolver,
              let renderer = robotRenderer else { return }
        previousJointAngles = angles
        let fk = solver.forwardKinematics(angles)
        renderer.updateTransforms(fk)
        renderer.setFeasibilityState(.feasible)
        feasibilityState = .feasible
        renderer.show()
        isGhostVisible = true
    }

    private func updateDistanceToEE(cameraTransform cam: simd_float4x4) {
        guard robotBasePlaced, !isClutchEngaged,
              let solver = ikSolver else {
            distanceToEE = -1
            angleToEE = -1
            return
        }
        let fk = solver.forwardKinematics(previousJointAngles)
        // EE pose is in base frame → convert to world frame
        let eeWorld = robotBaseTransform * fk.eePose
        let dx = cam.columns.3.x - eeWorld.columns.3.x
        let dy = cam.columns.3.y - eeWorld.columns.3.y
        let dz = cam.columns.3.z - eeWorld.columns.3.z
        distanceToEE = sqrtf(dx * dx + dy * dy + dz * dz)

        // Rotation difference: use corrected camera (180° Y + -90° Z + 45° X bracket) to match gripper
        let bracketAngle: Float = 45 * .pi / 180
        let cB = cosf(bracketAngle)
        let sB = sinf(bracketAngle)
        let rc0Raw = SIMD3(-cam.columns.1.x, -cam.columns.1.y, -cam.columns.1.z)
        let rc1 = SIMD3(-cam.columns.0.x, -cam.columns.0.y, -cam.columns.0.z)
        let rc2Raw = SIMD3(-cam.columns.2.x, -cam.columns.2.y, -cam.columns.2.z)
        let rc0 = rc0Raw * cB + rc2Raw * sB
        let rc2 = -rc0Raw * sB + rc2Raw * cB
        let camRot = simd_float3x3(rc0, rc1, rc2)
        let eeRot = simd_float3x3(
            SIMD3(eeWorld.columns.0.x, eeWorld.columns.0.y, eeWorld.columns.0.z),
            SIMD3(eeWorld.columns.1.x, eeWorld.columns.1.y, eeWorld.columns.1.z),
            SIMD3(eeWorld.columns.2.x, eeWorld.columns.2.y, eeWorld.columns.2.z)
        )
        let dR = camRot * eeRot.transpose
        let trace = dR.columns.0.x + dR.columns.1.y + dR.columns.2.z
        let cosAngle = min(max((trace - 1) / 2, -1), 1)
        angleToEE = acosf(cosAngle) * 180 / .pi
    }

    func correctGhostArmToCamera() {
        guard robotBasePlaced, !isClutchEngaged,
              let solver = ikSolver,
              let renderer = robotRenderer,
              let checker = feasibilityChecker else { return }

        // Camera→EE convention: 180° Y flip + (-90°) Z rotation
        // Combined: col0 = -cam.col1, col1 = -cam.col0, col2 = -cam.col2
        var camCorrected = cameraTransform
        camCorrected.columns.0 = -cameraTransform.columns.1
        camCorrected.columns.1 = -cameraTransform.columns.0
        camCorrected.columns.2 = -cameraTransform.columns.2
        // Compensate camera bracket: camera is pitched down 45° → right-multiply R_y(+45°)
        let a: Float = 45 * .pi / 180
        let cosA = cosf(a)
        let sinA = sinf(a)
        // R_y mixes X and Z columns: new_col0 = col0*cos + col2*sin, new_col2 = -col0*sin + col2*cos
        let c0 = camCorrected.columns.0
        let c2 = camCorrected.columns.2
        camCorrected.columns.0 = c0 * cosA + c2 * sinA
        camCorrected.columns.2 = -c0 * sinA + c2 * cosA
        // Camera pose in base frame → IK target
        let targetEE_base = robotBaseTransform.inverse * camCorrected

        let ikResult = solver.solve(target: targetEE_base, warmStart: previousJointAngles)
        previousJointAngles = ikResult.jointAngles
        renderer.updateTransforms(ikResult.fkResult)

        let result = checker.evaluate(ikResult: ikResult, timestamp: CACurrentMediaTime())
        let newState = result.state
        feasibilityState = newState
        feasibilityReason = feasibilityReasonText(result)
        renderer.setFeasibilityState(newState)
    }

    func updateGhostArm(cameraTransform: simd_float4x4, timestamp: Double) {
        guard isClutchEngaged, robotBasePlaced,
              let solver = ikSolver,
              let renderer = robotRenderer,
              let checker = feasibilityChecker,
              let cameraRef = clutchCameraRef,
              let eeRef = clutchEERef else { return }

        // Camera displacement delta (world frame)
        let dp_world = SIMD3<Float>(
            cameraTransform.columns.3.x - cameraRef.columns.3.x,
            cameraTransform.columns.3.y - cameraRef.columns.3.y,
            cameraTransform.columns.3.z - cameraRef.columns.3.z
        )

        // Rotation part of base inverse transform (3x3)
        let baseInv = robotBaseTransform.inverse
        let baseRot3 = simd_float3x3(
            SIMD3(baseInv.columns.0.x, baseInv.columns.0.y, baseInv.columns.0.z),
            SIMD3(baseInv.columns.1.x, baseInv.columns.1.y, baseInv.columns.1.z),
            SIMD3(baseInv.columns.2.x, baseInv.columns.2.y, baseInv.columns.2.z)
        )
        let dp_base = baseRot3 * dp_world

        // Rotation delta: dR_world = curRot * refRot^T, transform to base frame
        let refRot3 = simd_float3x3(
            SIMD3(cameraRef.columns.0.x, cameraRef.columns.0.y, cameraRef.columns.0.z),
            SIMD3(cameraRef.columns.1.x, cameraRef.columns.1.y, cameraRef.columns.1.z),
            SIMD3(cameraRef.columns.2.x, cameraRef.columns.2.y, cameraRef.columns.2.z)
        )
        let curRot3 = simd_float3x3(
            SIMD3(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z),
            SIMD3(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z),
            SIMD3(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        )
        let dR_world = curRot3 * refRot3.transpose
        let dR_base = baseRot3 * dR_world * baseRot3.transpose

        // Build target pose = eeRef + deltas
        let eeRefRot3 = simd_float3x3(
            SIMD3(eeRef.columns.0.x, eeRef.columns.0.y, eeRef.columns.0.z),
            SIMD3(eeRef.columns.1.x, eeRef.columns.1.y, eeRef.columns.1.z),
            SIMD3(eeRef.columns.2.x, eeRef.columns.2.y, eeRef.columns.2.z)
        )
        let targetRot = dR_base * eeRefRot3
        let eeRefPos = SIMD3<Float>(eeRef.columns.3.x, eeRef.columns.3.y, eeRef.columns.3.z)
        let targetPos = eeRefPos + dp_base

        var targetPose = matrix_identity_float4x4
        targetPose.columns.0 = SIMD4(targetRot.columns.0, 0)
        targetPose.columns.1 = SIMD4(targetRot.columns.1, 0)
        targetPose.columns.2 = SIMD4(targetRot.columns.2, 0)
        targetPose.columns.3 = SIMD4(targetPos, 1)

        // IK solve
        let ikResult = solver.solve(target: targetPose, warmStart: previousJointAngles)
        renderer.updateTransforms(ikResult.fkResult)

        // Feasibility evaluation (3 levels: feasible / warning / infeasible)
        let result = checker.evaluate(ikResult: ikResult, timestamp: timestamp)
        let newState = result.state
        if newState != feasibilityState {
            feasibilityState = newState
            renderer.setFeasibilityState(newState)
            hapticManager?.transientPulse()
            switch newState {
            case .feasible:
                hapticManager?.stopWarning()
            case .warning:
                hapticManager?.setWarningMode(.mild)
            case .infeasible:
                hapticManager?.setWarningMode(.strong)
            }
        }
        feasibilityReason = feasibilityReasonText(result)

        previousJointAngles = ikResult.jointAngles
    }

    private func feasibilityReasonText(_ result: FeasibilityResult) -> String {
        var reasons: [String] = []
        if !result.ikConverged { reasons.append("IK not converged") }
        if !result.withinJointLimits { reasons.append("Joint limit exceeded") }
        if !result.withinVelocityLimits { reasons.append("Velocity limit exceeded") }
        if result.selfCollision { reasons.append("Self-collision") }
        if result.manipulability < 1e-5 {
            reasons.append("At singularity")
        } else if result.nearSingularity {
            reasons.append("Near singularity")
        }
        return reasons.joined(separator: " | ")
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scnView.session.pause()
        // Do NOT reset hasStartedARSession — navigation to child views (e.g. DataManagementView)
        // triggers viewWillDisappear, and resetting causes setupARSession() to re-run on return,
        // which restarts Bonjour advertising and breaks rapid_driver mDNS discovery.
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasStartedARSession else {
            // Resume AR session after returning from a child view
            let configuration = createARConfiguration()
            scnView.session.run(configuration)
            return
        }
        hasStartedARSession = true
        setupARSession()
    }

    static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "unknown"
            }
        }
        return machine
    }
}
