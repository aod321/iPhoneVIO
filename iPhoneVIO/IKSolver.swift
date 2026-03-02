import simd
import Accelerate

struct FKResult {
    let linkTransforms: [simd_float4x4]  // 8 transforms: base_link + 7 links
    let eePose: simd_float4x4
}

struct IKResult {
    let jointAngles: [Float]
    let fkResult: FKResult
    let converged: Bool
    let positionError: Float
    let orientationError: Float
    let manipulability: Float  // sqrt(det(J * J^T)), near 0 = singularity
}

class IKSolver {
    let model: RobotKinematics
    private let dof: Int
    private let maxIterations = 30
    private let positionTolerance: Float = 0.005   // 5mm (ghost arm visualization)
    private let orientationTolerance: Float = 0.05  // ~2.9° (ghost arm visualization)
    private let lambdaSq: Float = 0.01             // DLS damping λ²
    private let maxJointStepPerIteration: Float = 0.15  // rad, improves numerical stability

    // Precomputed: parent index for each joint (index into links array)
    private let parentIndices: [Int]
    // Map from link name to index in model.links
    private let linkNameToIndex: [String: Int]

    init(model: RobotKinematics) {
        self.model = model
        self.dof = model.dof

        var nameToIdx: [String: Int] = [:]
        for (i, link) in model.links.enumerated() {
            nameToIdx[link.name] = i
        }
        self.linkNameToIndex = nameToIdx

        var parents: [Int] = []
        for joint in model.joints {
            parents.append(nameToIdx[joint.parentLink] ?? 0)
        }
        self.parentIndices = parents
    }

    // MARK: - Forward Kinematics

    func forwardKinematics(_ q: [Float]) -> FKResult {
        var linkTransforms = [simd_float4x4](repeating: matrix_identity_float4x4, count: model.links.count)
        // base_link transform is identity (index 0)

        for (i, joint) in model.joints.enumerated() {
            let parentIdx = parentIndices[i]
            let parentT = linkTransforms[parentIdx]
            let jointT = joint.originTransform
            let rot = rotationAboutAxis(joint.axis, angle: q[i])

            guard let childIdx = linkNameToIndex[joint.childLink] else { continue }
            linkTransforms[childIdx] = parentT * jointT * rot
        }

        let eePose = linkTransforms.last ?? matrix_identity_float4x4
        return FKResult(linkTransforms: linkTransforms, eePose: eePose)
    }

    // MARK: - Jacobian (6x7)

    func computeJacobian(_ q: [Float], fk: FKResult) -> [Float] {
        let eePos = SIMD3<Float>(fk.eePose.columns.3.x, fk.eePose.columns.3.y, fk.eePose.columns.3.z)
        var jacobian = [Float](repeating: 0, count: 6 * dof)

        for i in 0..<dof {
            let joint = model.joints[i]
            let parentIdx = parentIndices[i]
            let parentT = fk.linkTransforms[parentIdx]
            let jointFrameT = parentT * joint.originTransform

            // World-frame rotation axis
            let localAxis = joint.axis
            let zAxis = SIMD3<Float>(
                jointFrameT.columns.0.x * localAxis.x + jointFrameT.columns.1.x * localAxis.y + jointFrameT.columns.2.x * localAxis.z,
                jointFrameT.columns.0.y * localAxis.x + jointFrameT.columns.1.y * localAxis.y + jointFrameT.columns.2.y * localAxis.z,
                jointFrameT.columns.0.z * localAxis.x + jointFrameT.columns.1.z * localAxis.y + jointFrameT.columns.2.z * localAxis.z
            )

            // Joint position in world
            let pJoint = SIMD3<Float>(jointFrameT.columns.3.x, jointFrameT.columns.3.y, jointFrameT.columns.3.z)

            // Linear: z × (p_ee - p_joint)
            let dp = eePos - pJoint
            let linear = cross(zAxis, dp)

            // Column-major: jacobian[row + col * 6]
            jacobian[0 + i * 6] = linear.x
            jacobian[1 + i * 6] = linear.y
            jacobian[2 + i * 6] = linear.z
            jacobian[3 + i * 6] = zAxis.x
            jacobian[4 + i * 6] = zAxis.y
            jacobian[5 + i * 6] = zAxis.z
        }

        return jacobian
    }

    // MARK: - DLS IK Solve

    func solve(target: simd_float4x4, warmStart: [Float]) -> IKResult {
        var q = warmStart
        assert(q.count == dof)

        var lastFK = forwardKinematics(q)
        var posErr: Float = 0
        var oriErr: Float = 0

        for _ in 0..<maxIterations {
            lastFK = forwardKinematics(q)

            // Compute error (6-vector)
            let error = computeError(current: lastFK.eePose, target: target)
            posErr = sqrt(error[0]*error[0] + error[1]*error[1] + error[2]*error[2])
            oriErr = sqrt(error[3]*error[3] + error[4]*error[4] + error[5]*error[5])

            if posErr < positionTolerance && oriErr < orientationTolerance {
                let w = computeManipulability(q, fk: lastFK)
                return IKResult(jointAngles: q, fkResult: lastFK, converged: true,
                                positionError: posErr, orientationError: oriErr,
                                manipulability: w)
            }

            // Compute Jacobian (6x7, column-major)
            let J = computeJacobian(q, fk: lastFK)

            // DLS: dq = J^T * (J*J^T + λ²I)^{-1} * e
            // 1. Compute A = J * J^T (6x6)
            var A = [Float](repeating: 0, count: 36)
            // J is 6x7 column-major: J[r,c] = J[r + c*6]
            // A = J * J^T : A[r1,r2] = sum_k J[r1,k] * J[r2,k]
            for r1 in 0..<6 {
                for r2 in r1..<6 {
                    var sum: Float = 0
                    for k in 0..<dof {
                        sum += J[r1 + k * 6] * J[r2 + k * 6]
                    }
                    A[r1 + r2 * 6] = sum
                    A[r2 + r1 * 6] = sum
                }
            }

            // Add damping: A += λ²I
            for i in 0..<6 {
                A[i + i * 6] += lambdaSq
            }

            // 2. Solve A * x = e for x (6x1)
            var rhs = error
            var n: Int32 = 6
            var nrhs: Int32 = 1
            var lda: Int32 = 6
            var ipiv = [Int32](repeating: 0, count: 6)
            var ldb: Int32 = 6
            var info: Int32 = 0
            sgesv_(&n, &nrhs, &A, &lda, &ipiv, &rhs, &ldb, &info)

            if info != 0 {
                // Solve failed, return current state
                break
            }

            // 3. dq = J^T * x  (7x1 = 7x6 * 6x1)
            var dq = [Float](repeating: 0, count: dof)
            for j in 0..<dof {
                var sum: Float = 0
                for r in 0..<6 {
                    sum += J[r + j * 6] * rhs[r]
                }
                dq[j] = sum
            }

            // 4. Update and clamp
            for j in 0..<dof {
                let boundedStep = max(-maxJointStepPerIteration, min(maxJointStepPerIteration, dq[j]))
                q[j] += boundedStep
                q[j] = max(model.joints[j].posLower, min(model.joints[j].posUpper, q[j]))
            }
        }

        lastFK = forwardKinematics(q)
        let finalError = computeError(current: lastFK.eePose, target: target)
        posErr = sqrt(finalError[0]*finalError[0] + finalError[1]*finalError[1] + finalError[2]*finalError[2])
        oriErr = sqrt(finalError[3]*finalError[3] + finalError[4]*finalError[4] + finalError[5]*finalError[5])

        let w = computeManipulability(q, fk: lastFK)
        return IKResult(jointAngles: q, fkResult: lastFK,
                        converged: posErr < positionTolerance && oriErr < orientationTolerance,
                        positionError: posErr, orientationError: oriErr,
                        manipulability: w)
    }

    // MARK: - Manipulability

    /// Compute manipulability index w = sqrt(det(J * J^T)) via LU factorization
    func computeManipulability(_ q: [Float], fk: FKResult) -> Float {
        let J = computeJacobian(q, fk: fk)

        // Compute A = J * J^T (6x6, column-major)
        var A = [Float](repeating: 0, count: 36)
        for r1 in 0..<6 {
            for r2 in r1..<6 {
                var sum: Float = 0
                for k in 0..<dof {
                    sum += J[r1 + k * 6] * J[r2 + k * 6]
                }
                A[r1 + r2 * 6] = sum
                A[r2 + r1 * 6] = sum
            }
        }

        // LU factorization to compute determinant
        var m: Int32 = 6
        var n: Int32 = 6
        var lda: Int32 = 6
        var ipiv = [Int32](repeating: 0, count: 6)
        var info: Int32 = 0
        sgetrf_(&m, &n, &A, &lda, &ipiv, &info)

        if info != 0 { return 0 }

        // det = product of diagonal elements (with sign from pivots)
        var det: Float = 1.0
        for i in 0..<6 {
            det *= A[i + i * 6]
            if ipiv[i] != Int32(i + 1) { det = -det }
        }

        // w = sqrt(|det|) since det(J*J^T) >= 0 for real J
        return sqrt(max(0, det))
    }

    // MARK: - Error Computation

    private func computeError(current: simd_float4x4, target: simd_float4x4) -> [Float] {
        // Position error
        let posError = SIMD3<Float>(
            target.columns.3.x - current.columns.3.x,
            target.columns.3.y - current.columns.3.y,
            target.columns.3.z - current.columns.3.z
        )

        // Orientation error via axis-angle from R_err = R_target * R_current^T
        let Rc = simd_float3x3(
            SIMD3<Float>(current.columns.0.x, current.columns.0.y, current.columns.0.z),
            SIMD3<Float>(current.columns.1.x, current.columns.1.y, current.columns.1.z),
            SIMD3<Float>(current.columns.2.x, current.columns.2.y, current.columns.2.z)
        )
        let Rt = simd_float3x3(
            SIMD3<Float>(target.columns.0.x, target.columns.0.y, target.columns.0.z),
            SIMD3<Float>(target.columns.1.x, target.columns.1.y, target.columns.1.z),
            SIMD3<Float>(target.columns.2.x, target.columns.2.y, target.columns.2.z)
        )
        let Re = Rt * Rc.transpose

        // Axis-angle from rotation matrix
        let oriError = axisAngleFromRotation(Re)

        return [posError.x, posError.y, posError.z, oriError.x, oriError.y, oriError.z]
    }

    private func axisAngleFromRotation(_ R: simd_float3x3) -> SIMD3<Float> {
        // Using the skew-symmetric part: axis * sin(theta) = 0.5 * [R32-R23, R13-R31, R21-R12]
        let v = SIMD3<Float>(
            R[1][2] - R[2][1],  // R32 - R23 (simd index order is [column][row])
            R[2][0] - R[0][2],  // R13 - R31
            R[0][1] - R[1][0]   // R21 - R12
        ) * 0.5

        let sinTheta = length(v)
        let cosTheta = (R[0][0] + R[1][1] + R[2][2] - 1) * 0.5
        let clampedCosTheta = max(-1.0, min(1.0, cosTheta))

        if sinTheta < 1e-3 {
            if clampedCosTheta > 0 {
                return .zero  // No rotation
            } else {
                // theta ≈ π, need to extract axis from diagonal
                let diag = SIMD3<Float>(R[0][0], R[1][1], R[2][2])
                let maxIdx = diag.x >= diag.y && diag.x >= diag.z ? 0 : (diag.y >= diag.z ? 1 : 2)
                var axis = SIMD3<Float>.zero
                axis[maxIdx] = sqrt(max(0, (diag[maxIdx] + 1) * 0.5))
                let denom = 4 * axis[maxIdx]
                if denom > 1e-6 {
                    for j in 0..<3 where j != maxIdx {
                        axis[j] = (R[j][maxIdx] + R[maxIdx][j]) / denom
                    }
                }
                if length(axis) > 1e-6 {
                    axis = normalize(axis)
                } else {
                    axis = SIMD3<Float>(1, 0, 0)
                }
                return axis * Float.pi
            }
        }

        let theta = atan2(sinTheta, clampedCosTheta)
        return v * (theta / sinTheta)
    }
}
