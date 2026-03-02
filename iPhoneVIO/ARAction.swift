import SwiftUI
import Network

enum CollectionMode: String, CaseIterable {
    case feasiblecap = "feasiblecap"
    case baseline = "baseline"
}

enum ARAction {
    case connectToEndpoint(NWEndpoint)
    case disconnect
    case resetOrigin
    // FeasibleCap
    case startBasePlacement
    case startArucoPlacement
    case confirmBasePlacement
    case cancelBasePlacement
    case rotateBaseYaw(Float)
    case adjustBaseHeight(Float)
    case toggleClutch
    case setZeroPose
    case setHomePose
    case resetGhostArm
    case correctToCamera
    // Collection mode & task label
    case setCollectionMode(CollectionMode)
    case setTaskLabel(String)
    // Real robot teleop
    case toggleTeleopClutch
}
