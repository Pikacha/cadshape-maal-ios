import Foundation

public typealias V3 = SIMD3<Double>

@inline(__always) func vdot(_ a: V3, _ b: V3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
@inline(__always) public func vcross(_ a: V3, _ b: V3) -> V3 { V3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) }
@inline(__always) func vlength(_ a: V3) -> Double { vdot(a, a).squareRoot() }
@inline(__always) public func vnormalized(_ a: V3) -> V3 { a / max(1e-12, vlength(a)) }

/// The camera as a pinhole, in pixels of the full camera picture.
/// Camera coordinates: x right, y down, z forward (into the scene), metres.
public struct Intrinsics {
    public var fx: Double
    public var fy: Double
    public var cx: Double
    public var cy: Double
    public init(fx: Double, fy: Double, cx: Double, cy: Double) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
    }

    /// Direction through picture point (u, v), with z = 1.
    public func ray(_ u: Double, _ v: Double) -> V3 { V3((u - cx) / fx, (v - cy) / fy, 1) }
}

/// A flat surface: normal · p = offset, |normal| = 1, offset > 0 (the camera is at the origin).
public struct Plane {
    public var normal: V3
    public var offset: Double
    public init(normal: V3, offset: Double) {
        let n = vnormalized(normal)
        let o = offset / max(1e-12, vlength(normal))
        self.normal = o < 0 ? -n : n
        self.offset = abs(o)
    }

    /// Distance from the camera, straight out from the surface (m).
    public var distance: Double { offset }
    /// Angle between the viewing direction and the surface's normal (degrees, 0 = straight on).
    public var tilt: Double { acos(min(1, abs(normal.z))) * 180 / .pi }

    /// Where the ray from the camera meets the surface.
    public func hit(_ ray: V3) -> V3? {
        let d = vdot(normal, ray)
        if abs(d) < 1e-9 { return nil }
        let t = offset / d
        return t > 0 ? ray * t : nil
    }
}

/// Symmetric 3 × 3 eigen decomposition (Jacobi). Returns eigenvalues and eigenvectors (columns).
func eigenSymmetric3(_ m: [[Double]]) -> (values: [Double], vectors: [[Double]]) {
    var a = m
    var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
    for _ in 0..<50 {
        var p = 0, q = 1
        var big = abs(a[0][1])
        if abs(a[0][2]) > big { big = abs(a[0][2]); p = 0; q = 2 }
        if abs(a[1][2]) > big { big = abs(a[1][2]); p = 1; q = 2 }
        if big < 1e-15 { break }
        let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
        let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
        let c = 1 / (t * t + 1).squareRoot()
        let s = t * c
        for k in 0..<3 {
            let akp = a[k][p], akq = a[k][q]
            a[k][p] = c * akp - s * akq
            a[k][q] = s * akp + c * akq
        }
        for k in 0..<3 {
            let apk = a[p][k], aqk = a[q][k]
            a[p][k] = c * apk - s * aqk
            a[q][k] = s * apk + c * aqk
        }
        for k in 0..<3 {
            let vkp = v[k][p], vkq = v[k][q]
            v[k][p] = c * vkp - s * vkq
            v[k][q] = s * vkp + c * vkq
        }
    }
    return ([a[0][0], a[1][1], a[2][2]], v)
}

/// Least-squares plane through points (the direction of least spread is the normal).
func leastSquaresPlane(_ pts: [V3]) -> Plane? {
    if pts.count < 3 { return nil }
    var c = V3(0, 0, 0)
    for p in pts { c += p }
    c /= Double(pts.count)
    var m = [[Double]](repeating: [0, 0, 0], count: 3)
    for p in pts {
        let d = p - c
        let e = [d.x, d.y, d.z]
        for i in 0..<3 { for j in 0..<3 { m[i][j] += e[i] * e[j] } }
    }
    let (vals, vecs) = eigenSymmetric3(m)
    // A narrow strip/line cannot determine the wall's tilt reliably.
    let spread = vals.sorted()
    if spread[1] <= max(1e-12, spread[2] * 0.001) { return nil }
    var k = 0
    if vals[1] < vals[k] { k = 1 }
    if vals[2] < vals[k] { k = 2 }
    let n = V3(vecs[0][k], vecs[1][k], vecs[2][k])
    return Plane(normal: n, offset: vdot(n, c))
}

/// Robust plane through measured points (LiDAR): RANSAC, then least squares on the points that agree.
/// `threshold` in metres.
public func fitPlane(_ pts: [V3], iterations: Int = 150, threshold: Double = 0.008) -> (plane: Plane, inliers: Int)? {
    if pts.count < 12 { return nil }
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func rand(_ n: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 33) % UInt64(n))
    }
    var best: (Plane, Int)? = nil
    for _ in 0..<iterations {
        let a = pts[rand(pts.count)], b = pts[rand(pts.count)], c = pts[rand(pts.count)]
        let n = vcross(b - a, c - a)
        if vlength(n) < 1e-9 { continue }
        let plane = Plane(normal: vnormalized(n), offset: vdot(vnormalized(n), a))
        var count = 0
        for p in pts where abs(vdot(plane.normal, p) - plane.offset) < threshold { count += 1 }
        if best == nil || count > best!.1 { best = (plane, count) }
    }
    guard let found = best else { return nil }
    let rough = found.0
    let inliers = pts.filter { abs(vdot(rough.normal, $0) - rough.offset) < threshold }
    // RANSAC always finds some plane, even in a random cloud. Require broad support.
    if inliers.count < max(12, Int(ceil(Double(pts.count) * 0.6))) { return nil }
    guard let refined = leastSquaresPlane(inliers) else { return nil }
    return (refined, inliers.count)
}

/// Coordinates on a plane as seen from the camera: x to the right, y up (millimetres).
public struct PlaneFrame {
    public let plane: Plane
    public let u: V3
    public let v: V3

    public init(_ plane: Plane) {
        self.plane = plane
        let n = plane.normal
        // The camera's right (x) and up (−y) laid onto the plane.
        let right = V3(1, 0, 0) - n * vdot(V3(1, 0, 0), n)
        let u = vnormalized(vlength(right) > 1e-6 ? right : V3(0, 0, 1))
        var up = V3(0, -1, 0) - n * vdot(V3(0, -1, 0), n)
        up = up - u * vdot(up, u)
        self.u = u
        self.v = vnormalized(up)
    }

    /// A point on the plane (camera coordinates, m) in plane millimetres.
    public func mm(_ p: V3) -> P2 { P2(vdot(p, u) * 1000, vdot(p, v) * 1000) }
}
