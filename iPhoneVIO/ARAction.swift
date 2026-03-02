import SwiftUI
import Network

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
    // Real robot teleop
    case toggleTeleopClutch
}
