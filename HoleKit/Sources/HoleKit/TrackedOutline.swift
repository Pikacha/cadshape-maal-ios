import Foundation

/// A short-lived observation attached to the measured wall, rather than to an old camera image.
public struct TrackedHoleOutline {
    private var worldPoints: [V3] = []
    private var observedAt = -Double.infinity
    public init() {}
    public mutating func update(_ measurement: FrameMeasurement?, intrinsics: Intrinsics, scale: Double, pose: CameraPose, timestamp: Double) {
        worldPoints = []
        observedAt = timestamp
        guard let measurement, scale.isFinite, scale > 0 else { return }
        for p in measurement.outline {
            guard let hit = measurement.plane.hit(intrinsics.ray(p.x * scale, p.y * scale)) else {
                worldPoints = []
                return
            }
            worldPoints.append(pose.world(hit))
        }
    }
    public func projected(intrinsics: Intrinsics, pose: CameraPose, timestamp: Double) -> [P2] {
        let age = timestamp - observedAt
        guard age >= 0, age <= 0.35, worldPoints.count >= 3 else { return [] }
        let pixels = worldPoints.compactMap { project($0, intrinsics: intrinsics, pose: pose) }
        // Never join a partial contour across points that have gone behind the camera.
        return pixels.count == worldPoints.count ? pixels : []
    }
}
