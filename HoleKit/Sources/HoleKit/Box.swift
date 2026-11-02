import Foundation

// Measuring with the LiDAR point cloud (many camera frames in ARKit's world, metres, y up):
// the inside of a box or drawer (`fitBox`).
// A port of `fitBox` in src/scan/vision/box.ts in CadSHAPE – change both. The TypeScript side has
// the same tests with the same synthetic clouds (tests/box.test.ts). Not yet in the TypeScript:
// the box's noise and clutter rules (tests in RealisticSpaceTests.swift). The app no longer
// measures things on a table, pipes or gaps; those fits were removed here (the TypeScript keeps them).

/// Value at fraction q (0…1) of the sorted values.
public func quantile(_ values: [Double], _ q: Double) -> Double {
    if values.isEmpty { return .nan }
    let s = values.sorted()
    let i = min(s.count - 1, max(0, Int((q * Double(s.count - 1)).rounded())))
    return s[i]
}

@inline(__always) func median(_ v: [Double]) -> Double { quantile(v, 0.5) }

/// Two directions across `up` (u, v).
func flatFrame(_ up: V3) -> (u: V3, v: V3, up: V3) {
    let n = vnormalized(up)
    let seed = abs(n.x) < 0.9 ? V3(1, 0, 0) : V3(0, 0, 1)
    let u = vnormalized(vcross(seed, n))
    let v = vcross(n, u)
    return (u, v, n)
}

/// Where the camera is and which way it looks: the columns of ARKit's camera transform.
public struct CameraPose {
    /// The camera's x (right in the sensor's landscape picture), y (up) and z (backwards) in the world.
    public var x: V3
    public var y: V3
    public var z: V3
    public var position: V3

    public init(x: V3, y: V3, z: V3, position: V3) {
        self.x = x
        self.y = y
        self.z = z
        self.position = position
    }

    /// A point in camera coordinates (x right, y down, z forward – as `Intrinsics`) to the world.
    public func world(_ c: V3) -> V3 { position + x * c.x + y * (-c.y) + z * (-c.z) }
}

/// The LiDAR depth as world points: every `step`-th pixel ARKit is sure of, nearer than `maxDistance`.
/// `imageWidth`/`imageHeight` are of the full camera picture (the depth map covers the same view).
public func cloudPoints(_ dm: DepthMap, intrinsics K: Intrinsics, imageWidth: Double, imageHeight: Double, pose: CameraPose,
                        step: Int = 2, minConfidence: UInt8 = 2, maxDistance: Float = 1.2) -> [V3] {
    let sx = imageWidth / Double(dm.width)
    let sy = imageHeight / Double(dm.height)
    var out: [V3] = []
    out.reserveCapacity((dm.width / step + 1) * (dm.height / step + 1))
    var j = 0
    while j < dm.height {
        var i = 0
        while i < dm.width {
            let k = j * dm.width + i
            let z = dm.depth[k]
            if dm.valid(k), z < maxDistance, (dm.confidence?[k] ?? 2) >= minConfidence, !flying(dm, i, j, z) {
                let ray = K.ray((Double(i) + 0.5) * sx, (Double(j) + 0.5) * sy)
                out.append(pose.world(ray * Double(z)))
            }
            i += step
        }
        j += step
    }
    return out
}

/// A "flying pixel": at the outline of a thing the depth sensor mixes the near and the far
/// surface and gives points hanging in the air between them. They make a thing's footprint grow
/// and a box's walls move in. Such a pixel lies clearly between its two neighbours along a row or
/// a column (one much nearer, one much farther). A real edge pixel is close to one side, and a
/// wall seen at a slant changes far less per pixel, so both stay.
func flying(_ dm: DepthMap, _ i: Int, _ j: Int, _ z: Float) -> Bool {
    let limit = max(Float(0.025), 0.05 * z)
    for (di, dj) in [(1, 0), (0, 1)] {
        let a = (i - di, j - dj), b = (i + di, j + dj)
        guard a.0 >= 0, a.1 >= 0, b.0 < dm.width, b.1 < dm.height else { continue }
        let ka = a.1 * dm.width + a.0, kb = b.1 * dm.width + b.0
        guard dm.valid(ka), dm.valid(kb) else { continue }
        let da = dm.depth[ka] - z, db = dm.depth[kb] - z
        if abs(da) > limit && abs(db) > limit && da * db < 0 { return true }
    }
    return false
}

/// The world point under a picture point (full-picture pixels): median depth of a small patch.
public func pointAt(_ dm: DepthMap, intrinsics K: Intrinsics, imageWidth: Double, imageHeight: Double, pose: CameraPose, u: Double, v: Double) -> V3? {
    let sx = imageWidth / Double(dm.width)
    let sy = imageHeight / Double(dm.height)
    let ci = Int(u / sx), cj = Int(v / sy)
    guard ci >= 0, cj >= 0, ci < dm.width, cj < dm.height else { return nil }
    var zs: [Double] = []
    for j in max(0, cj - 2)...min(dm.height - 1, cj + 2) {
        for i in max(0, ci - 2)...min(dm.width - 1, ci + 2) where dm.valid(j * dm.width + i) {
            zs.append(Double(dm.depth[j * dm.width + i]))
        }
    }
    if zs.count < 5 { return nil }
    return pose.world(K.ray(u, v) * median(zs))
}

/// Share (0…1) of the depth pixels within `radius` depth-map pixels of a picture point (full-picture
/// pixels) that are valid and of high confidence. Dark or glossy things give few: then the app can
/// take `minConfidence: 1` and say the size is less sure.
public func confidentShare(_ dm: DepthMap, aroundPixel u: Double, v: Double, imageWidth: Double, imageHeight: Double, radius: Int = 20) -> Double {
    guard imageWidth > 0, imageHeight > 0, u.isFinite, v.isFinite else { return 0 }
    let ci = Int(max(-1e6, min(1e6, u / imageWidth * Double(dm.width))).rounded(.down))
    let cj = Int(max(-1e6, min(1e6, v / imageHeight * Double(dm.height))).rounded(.down))
    let r = min(max(0, radius), 4096)
    let i0 = max(0, ci - r), i1 = min(dm.width - 1, ci + r)
    let j0 = max(0, cj - r), j1 = min(dm.height - 1, cj + r)
    if i0 > i1 || j0 > j1 { return 0 }
    var total = 0, good = 0
    for j in j0...j1 {
        for i in i0...i1 {
            let di = i - ci, dj = j - cj
            if di * di + dj * dj > r * r { continue }
            total += 1
            let k = j * dm.width + i
            if dm.valid(k) && (dm.confidence?[k] ?? 2) >= 2 { good += 1 }
        }
    }
    return total > 0 ? Double(good) / Double(total) : 0
}

// MARK: The inside of a box

public struct BoxFit {
    /// Inside, mm. Width is the side across the view (left–right), length the side away from you.
    public var width: Double
    public var length: Double
    /// Height of the walls above the floor (mm); nil when the rim was not seen.
    public var height: Double?
    /// Thickness of the walls at the rim (mm); nil when unsure.
    public var wall: Double?
    /// Floor corners (world, m), in order round the box.
    public var corners: [V3]
    /// Which walls had enough points: −x, +x, −y, +y of the box's own axes.
    public var seen: [Bool]
    /// ± mm, how sure the width and length are.
    public var spread: Double
    public var floorPoints: Int
    public var wallPoints: Int

    public var allWallsSeen: Bool { seen.allSatisfy { $0 } }
}

private struct Side {
    var pos: Double
    var n: Int
    var sigma: Double
}

private func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

/// The inside of a box. `aim` is where the cross-hair hits the floor (world, m); `right` is the
/// camera's right as seen on the screen (to tell width from length).
public func fitBox(_ points: [V3], aim: V3, up: V3 = V3(0, 1, 0), right: V3? = nil) -> BoxFit? {
    let F = flatFrame(up)
    let n = points.count
    var A = [Double](repeating: 0, count: n)
    var B = [Double](repeating: 0, count: n)
    var H = [Double](repeating: 0, count: n)
    for i in 0..<n {
        let d = points[i] - aim
        A[i] = vdot(d, F.u)
        B[i] = vdot(d, F.v)
        H[i] = vdot(d, F.up)
    }

    // 1. The floor: level round the cross-hair.
    var near: [Double] = []
    for i in 0..<n where A[i] * A[i] + B[i] * B[i] < 0.05 * 0.05 && abs(H[i]) < 0.02 { near.append(H[i]) }
    if near.count < 20 { return nil }
    let f0 = median(near)
    // Noisy depth spreads the floor: widen its band to match (4 mm for clean data, as before).
    let band = max(0.004, min(0.012, 2.5 * 1.4826 * median(near.map { abs($0 - f0) })))
    var floor: [Double] = []
    for i in 0..<n where abs(H[i] - f0) < band && A[i] * A[i] + B[i] * B[i] < 0.1 * 0.1 { floor.append(H[i]) }
    if floor.count < 20 { return nil }
    let f = median(floor)
    for i in 0..<n { H[i] -= f }
    // What stands clear of the floor's noise is wall (or clutter); 6 mm at the least.
    let floorNoise = max(0.006, 3 * 1.4826 * median(floor.map { abs($0 - f) }))

    // 2. Looking out from the cross-hair in every direction: the nearest wall (inner face or the
    //    inner edge of the rim). A few points must agree, so a stray point does not count.
    let bins = 360
    var buckets = [[(r: Double, a: Double, b: Double, h: Double)]](repeating: [], count: bins)
    var wallPoints = 0
    for i in 0..<n {
        if H[i] < floorNoise || H[i] > 0.4 { continue }
        let r = (A[i] * A[i] + B[i] * B[i]).squareRoot()
        if r < 0.01 || r > 0.6 { continue }
        var k = Int(((atan2(B[i], A[i]) + .pi) / (2 * .pi)) * Double(bins))
        if k >= bins { k = bins - 1 }
        if k < 0 { k = 0 }
        buckets[k].append((r, A[i], B[i], H[i]))
        wallPoints += 1
    }
    // Roughly how high the walls stand (the top in most directions). Something on the floor that
    // reaches less than half of that (or 25 mm) is clutter, not a wall: look further out.
    var tops: [Double] = []
    for k in 0..<bins where buckets[k].count >= 3 { tops.append(quantile(buckets[k].map { $0.h }, 0.9)) }
    let need = tops.isEmpty ? 0 : min(0.025, 0.5 * median(tops))
    var edge = [P2?](repeating: nil, count: bins)
    for k in 0..<bins {
        let list = buckets[k].sorted { $0.r < $1.r }
        if list.count < 3 { continue }
        var j = 0
        while j + 2 < list.count {
            if list[j + 2].r - list[j].r < 0.005 {
                // A wall (or the rim on top of it) stands up right behind its inner edge.
                var tall = 0
                var m = j
                while m < list.count && list[m].r <= list[j].r + 0.015 {
                    if list[m].h >= need { tall += 1 }
                    m += 1
                }
                if tall >= 2 {
                    edge[k] = P2(list[j + 1].a, list[j + 1].b)
                    break
                }
            }
            j += 1
        }
    }
    let hits = edge.compactMap { $0 }
    if hits.count < 60 { return nil }

    // 3. Which way the box is turned: the turn where the edge points pile up on the fewest lines
    //    (sharpest 2 mm profile along both axes) – first every degree, then every tenth.
    func sharpness(_ t: Double) -> Double {
        let ct = cos(t), st = sin(t)
        var px: [Int: Int] = [:], py: [Int: Int] = [:]
        for h in hits {
            let kx = Int(((h.x * ct + h.y * st) / 0.002).rounded())
            let ky = Int(((-h.x * st + h.y * ct) / 0.002).rounded())
            px[kx, default: 0] += 1
            py[ky, default: 0] += 1
        }
        var sum = 0.0
        for v in px.values { sum += Double(v * v) }
        for v in py.values { sum += Double(v * v) }
        return sum
    }
    var theta = 0.0
    var best = -1.0
    for d in 0..<90 {
        let v = sharpness(Double(d) * .pi / 180)
        if v > best {
            best = v
            theta = Double(d) * .pi / 180
        }
    }
    let coarse = theta
    for i in 0...20 {
        let t = coarse + (Double(i) * 0.1 - 1) * .pi / 180
        let v = sharpness(t)
        if v > best {
            best = v
            theta = t
        }
    }
    let c = cos(theta), s = sin(theta)
    func rot(_ a: Double, _ b: Double) -> P2 { P2(a * c + b * s, -a * s + b * c) }

    // 4. The four walls: each edge point belongs to the nearest wall (not near a corner); the wall
    //    is the median. Start from the outermost points, then tighten.
    let E = hits.map { rot($0.x, $0.y) }
    var lim = [quantile(E.map(\.x), 0.04), quantile(E.map(\.x), 0.96), quantile(E.map(\.y), 0.04), quantile(E.map(\.y), 0.96)]
    var sides = lim.map { Side(pos: $0, n: 0, sigma: 0.01) }
    for iter in 0..<8 {
        let tol = iter < 2 ? 0.05 : 0.012
        var lists: [[Double]] = [[], [], [], []]
        for e in E {
            let d = [abs(e.x - lim[0]), abs(e.x - lim[1]), abs(e.y - lim[2]), abs(e.y - lim[3])]
            var k = 0
            for j in 1..<4 where d[j] < d[k] { k = j }
            if d[k] > tol { continue }
            let along = k < 2 ? e.y : e.x
            let lo = k < 2 ? lim[2] : lim[0]
            let hi = k < 2 ? lim[3] : lim[1]
            if along < lo + 0.008 || along > hi - 0.008 { continue }
            lists[k].append(k < 2 ? e.x : e.y)
        }
        sides = (0..<4).map { k -> Side in
            let l = lists[k]
            if l.count < 5 { return Side(pos: lim[k], n: l.count, sigma: 0.01) }
            let m = median(l)
            let mad = median(l.map { abs($0 - m) })
            return Side(pos: m, n: l.count, sigma: max(0.0005, 1.4826 * mad))
        }
        lim = sides.map(\.pos)
    }
    if lim[1] - lim[0] < 0.01 || lim[3] - lim[2] < 0.01 { return nil }
    let seen = sides.map { $0.n >= 5 }

    // 5. Height of the walls (top of the rim right beside each wall), then each wall again from all
    //    the points on its inner face (the nearest point per direction leans inwards with noise).
    var RX = [Double](repeating: 0, count: n)
    var RY = [Double](repeating: 0, count: n)
    for i in 0..<n {
        let p = rot(A[i], B[i])
        RX[i] = p.x
        RY[i] = p.y
    }
    func offset(_ k: Int, _ x: Double, _ y: Double) -> Double {
        switch k {
        case 0: return lim[0] - x
        case 1: return x - lim[1]
        case 2: return lim[2] - y
        default: return y - lim[3]
        }
    }
    func inSpan(_ k: Int, _ x: Double, _ y: Double, _ m: Double) -> Bool {
        let along = k < 2 ? y : x
        return k < 2 ? (along > lim[2] + m && along < lim[3] - m) : (along > lim[0] + m && along < lim[1] - m)
    }
    func wallHeight() -> Double? {
        var heights: [[Double]] = [[], [], [], []]
        for i in 0..<n {
            if H[i] < floorNoise || H[i] > 0.4 { continue }
            for k in 0..<4 {
                let o = offset(k, RX[i], RY[i])
                if o >= -0.004 && o <= 0.02 && inSpan(k, RX[i], RY[i], 0.01) { heights[k].append(H[i]) }
            }
        }
        let sideH = heights.filter { $0.count >= 10 }.map { quantile($0, 0.95) }
        return sideH.isEmpty ? nil : median(sideH)
    }
    var height = wallHeight()
    // Noisy walls need a wider window to pull the wall out to its middle.
    let sigmas = sides.filter { $0.n >= 5 }.map(\.sigma)
    let w0 = max(0.003, min(0.01, 2 * (sigmas.isEmpty ? 0.0015 : median(sigmas))))
    for win in [w0 * 4 / 3, w0, w0, w0, w0] {
        // Only the middle of the wall: low down are clutter and the floor's noise, at the top the
        // rim's rounded edge and flying pixels.
        let bottom = height.map { max(floorNoise, 0.25 * $0) } ?? floorNoise
        let top = height.map { 0.85 * $0 } ?? 0.396
        var lists: [[Double]] = [[], [], [], []]
        for i in 0..<n {
            if H[i] < bottom || H[i] > top { continue }
            for k in 0..<4 where abs(offset(k, RX[i], RY[i])) < win && inSpan(k, RX[i], RY[i], 0.01) {
                lists[k].append(k < 2 ? RX[i] : RY[i])
            }
        }
        lim = (0..<4).map { k in lists[k].count >= 10 ? median(lists[k]) : lim[k] }
    }
    height = wallHeight()
    var wall: Double? = nil
    if let height {
        var thick: [Double] = []
        for k in 0..<4 {
            var top: [Double] = []
            for i in 0..<n where abs(H[i] - height) < 0.004 {
                let o = offset(k, RX[i], RY[i])
                if o > -0.002 && o < 0.02 && inSpan(k, RX[i], RY[i], 0.01) { top.append(o) }
            }
            if top.count >= 8 { thick.append(quantile(top, 0.9)) }
        }
        if !thick.isEmpty {
            let t = median(thick) * 1000
            wall = t >= 0.4 && t <= 25 ? r1(t) : nil
        }
    }

    // 6. Width across the view, length away from it.
    let ax = F.u * c + F.v * s
    let ay = F.u * (-s) + F.v * c
    let sx = (lim[1] - lim[0]) * 1000
    let sy = (lim[3] - lim[2]) * 1000
    let swap: Bool
    if let right { swap = abs(vdot(ay, right)) > abs(vdot(ax, right)) } else { swap = sy > sx }
    func prec(_ a: Side, _ b: Side) -> Double {
        let ea = a.sigma / Double(max(1, a.n)).squareRoot()
        let eb = b.sigma / Double(max(1, b.n)).squareRoot()
        return (ea * ea + eb * eb).squareRoot() * 1000
    }
    let spread = 1.5 + 2 * max(prec(sides[0], sides[1]), prec(sides[2], sides[3]))
    let base = aim + F.up * f
    func at(_ x: Double, _ y: Double) -> V3 { base + ax * x + ay * y }
    return BoxFit(
        width: r1(swap ? sy : sx),
        length: r1(swap ? sx : sy),
        height: height.map { r1($0 * 1000) },
        wall: wall,
        corners: [at(lim[0], lim[2]), at(lim[1], lim[2]), at(lim[1], lim[3]), at(lim[0], lim[3])],
        seen: seen,
        spread: r1(spread),
        floorPoints: floor.count,
        wallPoints: wallPoints
    )
}

// MARK: Projection

/// A world point to full-picture pixels (nil behind the camera).
public func project(_ p: V3, intrinsics K: Intrinsics, pose: CameraPose) -> P2? {
    let d = p - pose.position
    let cx = vdot(d, pose.x), cy = -vdot(d, pose.y), cz = -vdot(d, pose.z)
    if cz <= 1e-6 { return nil }
    return P2(K.fx * cx / cz + K.cx, K.fy * cy / cz + K.cy)
}
