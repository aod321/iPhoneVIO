import Foundation

/// Three-level feasibility state for ghost arm feedback
enum FeasibilityState: Equatable {
    case feasible
    case warning    // approaching singularity / near collision
    case infeasible
}

struct FeasibilityResult {
    let state: FeasibilityState
    let rawState: FeasibilityState       // pre-debounce state (for offline analysis)
    let ikConverged: Bool
    let positionError: Float             // meters (from IK)
    let orientationError: Float          // radians (from IK)
    let withinJointLimits: Bool
    let withinVelocityLimits: Bool
    let nearSingularity: Bool
    let manipulability: Float
    let selfCollision: Bool
    let maxJointRateRatio: Float         // max_i |q̇_i| / (q̇_max_i × safetyFactor)
}

class FeasibilityChecker {
    private let joints: [JointDef]
    private var previousAngles: [Float]?
    private var previousTimestamp: Double = 0
    private let pauseThreshold: Double = 0.5

    /// Safety factor: use 50% of hardware max velocity as feasibility threshold
    private let velocitySafetyFactor: Float = 0.5

    // -- Singularity thresholds --
    /// Manipulability below this → infeasible (at singularity)
    private let manipCriticalThreshold: Float = 1e-5
    /// Manipulability below this → warning (approaching singularity)
    private let manipWarnThreshold: Float = 5e-4
    /// Joint angle threshold for known singularity configs (rad, ~5°)
    private let singularityAngleThreshold: Float = 0.087

    // -- Self-collision --
    private let collisionChecker = SelfCollisionChecker()

    // -- Debounce --
    private let infeasibleDebounceCount = 5
    private let feasibleDebounceCount = 5
    private var consecutiveInfeasibleFrames = 0
    private var consecutiveFeasibleFrames = 0
    private var consecutiveWarningFrames = 0
    private var currentState: FeasibilityState = .feasible

    // -- Velocity sliding window --
    private let velocityWindowSize = 5
    private var velocityViolationHistory: [Bool] = []
    private let velocityViolationThreshold = 4

    init(joints: [JointDef]) {
        self.joints = joints
    }

    func evaluate(ikResult: IKResult, timestamp: Double) -> FeasibilityResult {
        let q = ikResult.jointAngles
        let ikOk = ikResult.converged

        // 1. Joint position limits
        var limitsOk = true
        for (i, angle) in q.enumerated() where i < joints.count {
            if angle < joints[i].posLower - 0.01 || angle > joints[i].posUpper + 0.01 {
                limitsOk = false
                break
            }
        }

        // 2. Joint velocity limits (only when IK converged both frames)
        var velocityOk = true
        var maxJointRateRatio: Float = 0
        if ikOk, let prevQ = previousAngles, previousTimestamp > 0 {
            let dt = timestamp - previousTimestamp
            if dt > 0.001 && dt < pauseThreshold {
                var frameViolation = false
                for (i, angle) in q.enumerated() where i < joints.count {
                    let rate = abs(angle - prevQ[i]) / Float(dt)
                    let limit = joints[i].velLimit * velocitySafetyFactor
                    if limit > 0 {
                        let ratio = rate / limit
                        maxJointRateRatio = max(maxJointRateRatio, ratio)
                    }
                    if rate > limit {
                        frameViolation = true
                    }
                }
                velocityViolationHistory.append(frameViolation)
                if velocityViolationHistory.count > velocityWindowSize {
                    velocityViolationHistory.removeFirst()
                }
                let violationCount = velocityViolationHistory.filter { $0 }.count
                velocityOk = violationCount < velocityViolationThreshold
            }
        }

        // 3. Singularity detection
        let w = ikResult.manipulability
        let atSingularity = w < manipCriticalThreshold
        let nearSingularity = w < manipWarnThreshold

        // Also check known RM75 singularity configs by joint angles
        let elbowSingular = joints.count > 3 && abs(q[3]) < singularityAngleThreshold   // q4≈0
        let wristSingular = joints.count > 5 && abs(q[5]) < singularityAngleThreshold    // q6≈0
        let knownSingular = elbowSingular || wristSingular

        // 4. Self-collision
        let collisionResult = collisionChecker.check(linkTransforms: ikResult.fkResult.linkTransforms)

        // Always update previous angles to avoid false velocity spikes
        // when IK recovers after several non-converged frames
        previousAngles = q
        previousTimestamp = timestamp

        // Determine raw state
        let rawState: FeasibilityState
        if !ikOk || !limitsOk || !velocityOk || atSingularity || collisionResult.colliding {
            rawState = .infeasible
        } else if nearSingularity || knownSingular {
            rawState = .warning
        } else {
            rawState = .feasible
        }

        // Debounce state transitions
        switch rawState {
        case .infeasible:
            consecutiveFeasibleFrames = 0
            consecutiveWarningFrames = 0
            consecutiveInfeasibleFrames += 1
            if currentState != .infeasible && consecutiveInfeasibleFrames >= infeasibleDebounceCount {
                currentState = .infeasible
            }
        case .warning:
            consecutiveFeasibleFrames = 0
            consecutiveInfeasibleFrames = 0
            consecutiveWarningFrames += 1
            if currentState == .feasible && consecutiveWarningFrames >= infeasibleDebounceCount {
                currentState = .warning
            } else if currentState == .infeasible && consecutiveWarningFrames >= feasibleDebounceCount {
                currentState = .warning
            }
        case .feasible:
            consecutiveInfeasibleFrames = 0
            consecutiveWarningFrames = 0
            consecutiveFeasibleFrames += 1
            if currentState != .feasible && consecutiveFeasibleFrames >= feasibleDebounceCount {
                currentState = .feasible
            }
        }

        return FeasibilityResult(
            state: currentState,
            rawState: rawState,
            ikConverged: ikOk,
            positionError: ikResult.positionError,
            orientationError: ikResult.orientationError,
            withinJointLimits: limitsOk,
            withinVelocityLimits: velocityOk,
            nearSingularity: nearSingularity || knownSingular,
            manipulability: w,
            selfCollision: collisionResult.colliding,
            maxJointRateRatio: maxJointRateRatio
        )
    }

    func reset() {
        previousAngles = nil
        previousTimestamp = 0
        consecutiveInfeasibleFrames = 0
        consecutiveFeasibleFrames = 0
        consecutiveWarningFrames = 0
        currentState = .feasible
        velocityViolationHistory.removeAll()
    }
}
