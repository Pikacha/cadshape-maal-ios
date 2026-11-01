import Foundation

/// A short-lived observation attached to the measured wall, rather than to an old camera image.
public struct TrackedHoleOutline {
    private var worldPoints: [V3] = []
    private var observedAt = -Double.infinity
    private var misses = 0
    /// Frames in a row without a hole before the outline goes away. One blurry frame or a
    /// reflection must not make the found circle blink off.
    public static let allowedMisses = 3
    /// How long an outline stays without a new observation (s).
    public static let maxAge = 0.6

    public init() {}

    public mutating func update(_ measurement: FrameMeasurement?, intrinsics: Intrinsics, scale: Double, pose: CameraPose, timestamp: Double) {
        guard let measurement, scale.isFinite, scale > 0 else { return missed() }
        var points: [V3] = []
        for p in measurement.outline {
            guard let hit = measurement.plane.hit(intrinsics.ray(p.x * scale, p.y * scale)) else { return missed() }
            points.append(pose.world(hit))
        }
        misses = 0
        worldPoints = points
        observedAt = timestamp
    }

    private mutating func missed() {
        misses += 1
        if misses >= Self.allowedMisses { worldPoints = [] }
    }

    public func projected(intrinsics: Intrinsics, pose: CameraPose, timestamp: Double) -> [P2] {
        let age = timestamp - observedAt
        guard age >= 0, age <= Self.maxAge, worldPoints.count >= 3 else { return [] }
        let pixels = worldPoints.compactMap { project($0, intrinsics: intrinsics, pose: pose) }
        // Never join a partial contour across points that have gone behind the camera.
        return pixels.count == worldPoints.count ? pixels : []
    }
}
