import Foundation

// «Se delen i AR»: does the drawn part, placed in the room, go into the real thing behind it?
// Each point of the part is looked up in the LiDAR depth: the real surface is that far away along
// the same line from the camera. Behind it (by a little) = inside the real thing.

extension CameraPose {
    /// A world point in camera coordinates (x right, y down, z forward – as `Intrinsics`). The inverse of `world`.
    public func camera(_ w: V3) -> V3 {
        let d = w - position
        return V3(vdot(d, x), -vdot(d, y), -vdot(d, z))
    }
}

public struct Clearance {
    /// Smallest air between the part and the real surface behind it (mm), among points closer than 5 cm. Nil = nothing near.
    public var gapMM: Double?
    /// Deepest a point of the part goes into the real thing (mm). 0 = nowhere.
    public var hitMM: Double
    /// The points that go in (world), for red marks.
    public var hits: [V3]
    /// How many points the depth could check (in view, depth known).
    public var checked: Int

    public init(gapMM: Double?, hitMM: Double, hits: [V3], checked: Int) {
        self.gapMM = gapMM
        self.hitMM = hitMM
        self.hits = hits
        self.checked = checked
    }
}

/// Checks `points` (world, m) against the LiDAR depth of one frame. A point more than `near` behind
/// the real surface is hidden behind something closer (a hand, the edge of a table) – not a hit.
/// `tolerance` (m) is how far behind still counts as resting against it (LiDAR noise).
public func depthClearance(_ points: [V3], depth dm: DepthMap, intrinsics K: Intrinsics, imageWidth: Double, imageHeight: Double, pose: CameraPose,
                           tolerance: Double = 0.0025, near: Double = 0.03, maxHits: Int = 24) -> Clearance {
    let sx = imageWidth / Double(dm.width)
    let sy = imageHeight / Double(dm.height)
    var gap: Double? = nil
    var deepest = 0.0
    var hits: [(V3, Double)] = []
    var checked = 0
    for p in points {
        let c = pose.camera(p)
        if c.z < 0.08 { continue }
        let u = K.fx * c.x / c.z + K.cx
        let v = K.fy * c.y / c.z + K.cy
        let i = Int(u / sx), j = Int(v / sy)
        guard i >= 0, j >= 0, i < dm.width, j < dm.height else { continue }
        let k = j * dm.width + i
        guard dm.valid(k), (dm.confidence?[k] ?? 2) >= 1 else { continue }
        checked += 1
        let real = Double(dm.depth[k])
        let behind = c.z - real
        if behind > tolerance && behind < near {
            deepest = max(deepest, behind)
            hits.append((p, behind))
        } else if behind <= tolerance {
            let air = max(0, -behind)
            if air < 0.05 { gap = min(gap ?? air, air) }
        }
    }
    let marks = hits.sorted { $0.1 > $1.1 }.prefix(maxHits).map { $0.0 }
    return Clearance(gapMM: gap.map { $0 * 1000 }, hitMM: deepest * 1000, hits: Array(marks), checked: checked)
}

/// The angle between two surfaces from their normals, as one sees it in a corner: 90° for a wall and
/// a shelf, 180° for one flat surface, 0° for two facing each other.
public func cornerAngle(_ a: V3, _ b: V3) -> Double {
    let c = max(-1, min(1, vdot(vnormalized(a), vnormalized(b))))
    return 180 - acos(c) * 180 / .pi
}
