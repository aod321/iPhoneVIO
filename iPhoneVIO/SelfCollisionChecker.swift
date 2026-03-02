import simd

struct CollisionSphere {
    let linkIndex: Int
    let localPosition: SIMD3<Float>  // in link-local frame
    let radius: Float
}

struct CollisionPair {
    let sphereA: Int
    let sphereB: Int
}

struct CollisionResult {
    let colliding: Bool
    let collidingLinkA: Int  // -1 if no collision
    let collidingLinkB: Int
    let minDistance: Float   // smallest gap (negative = penetration)
}

class SelfCollisionChecker {
    private let spheres: [CollisionSphere]
    private let checkPairs: [CollisionPair]
    private let safetyMargin: Float = 0.01  // 10mm

    /// Initialize with RM75 approximate geometry.
    /// Link indices match FK linkTransforms: 0=base_link, 1=Link1, ..., 7=Link7
    init() {
        // Sphere placement based on RM75 dimensions:
        // d1=240.5mm, d3=256mm, d5=210mm, d7=144mm, base φ107mm
        var spheres: [CollisionSphere] = []

        // base_link: center of base body
        spheres.append(CollisionSphere(linkIndex: 0, localPosition: SIMD3(0, 0, 0.05), radius: 0.06))

        // Link1: shoulder joint module
        spheres.append(CollisionSphere(linkIndex: 1, localPosition: SIMD3(0, 0, 0), radius: 0.05))

        // Link2: upper arm (long link, 256mm to next joint) — two spheres
        spheres.append(CollisionSphere(linkIndex: 2, localPosition: SIMD3(0, 0, 0.05), radius: 0.045))
        spheres.append(CollisionSphere(linkIndex: 2, localPosition: SIMD3(0, 0, 0.18), radius: 0.045))

        // Link3: elbow joint module
        spheres.append(CollisionSphere(linkIndex: 3, localPosition: SIMD3(0, 0, 0), radius: 0.045))

        // Link4: forearm (210mm to next joint) — two spheres
        spheres.append(CollisionSphere(linkIndex: 4, localPosition: SIMD3(0, 0, 0.04), radius: 0.04))
        spheres.append(CollisionSphere(linkIndex: 4, localPosition: SIMD3(0, 0, 0.14), radius: 0.04))

        // Link5: wrist module
        spheres.append(CollisionSphere(linkIndex: 5, localPosition: SIMD3(0, 0, 0), radius: 0.04))

        // Link6: wrist rotation module
        spheres.append(CollisionSphere(linkIndex: 6, localPosition: SIMD3(0, 0, 0.04), radius: 0.035))

        // Link7: end-effector flange + gripper
        spheres.append(CollisionSphere(linkIndex: 7, localPosition: SIMD3(0, 0, 0), radius: 0.03))

        self.spheres = spheres

        // Build check pairs: only non-adjacent links (gap >= 2 in kinematic chain)
        var pairs: [CollisionPair] = []
        for i in 0..<spheres.count {
            for j in (i + 1)..<spheres.count {
                let linkA = spheres[i].linkIndex
                let linkB = spheres[j].linkIndex
                // Skip same link and adjacent links
                if abs(linkA - linkB) >= 3 {
                    pairs.append(CollisionPair(sphereA: i, sphereB: j))
                }
            }
        }
        self.checkPairs = pairs
    }

    func check(linkTransforms: [simd_float4x4]) -> CollisionResult {
        // Compute world positions of all spheres
        var worldPositions = [SIMD3<Float>](repeating: .zero, count: spheres.count)
        for (i, sphere) in spheres.enumerated() {
            guard sphere.linkIndex < linkTransforms.count else { continue }
            let T = linkTransforms[sphere.linkIndex]
            let local = SIMD4<Float>(sphere.localPosition, 1)
            let world = T * local
            worldPositions[i] = SIMD3(world.x, world.y, world.z)
        }

        var minGap: Float = .greatestFiniteMagnitude
        var colA = -1, colB = -1

        for pair in checkPairs {
            let sA = spheres[pair.sphereA]
            let sB = spheres[pair.sphereB]
            let dist = simd_distance(worldPositions[pair.sphereA], worldPositions[pair.sphereB])
            let gap = dist - sA.radius - sB.radius - safetyMargin

            if gap < minGap {
                minGap = gap
                colA = sA.linkIndex
                colB = sB.linkIndex
            }
        }

        return CollisionResult(
            colliding: minGap < 0,
            collidingLinkA: minGap < 0 ? colA : -1,
            collidingLinkB: minGap < 0 ? colB : -1,
            minDistance: minGap
        )
    }
}
