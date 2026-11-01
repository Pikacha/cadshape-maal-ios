import Foundation

// Measuring with the LiDAR point cloud (many camera frames in ARKit's world, metres, y up):
// the inside of a box or drawer (`fitBox`), and something lying on a table (`fitObject`).
// A 1:1 port of src/scan/vision/box.ts in CadSHAPE – change both. The TypeScript side has the
// same tests with the same synthetic clouds (tests/box.test.ts). Not yet in the TypeScript: the
// box's noise and clutter rules, the object's smallest rectangle, refineOutline's step choice,
// fitCylinder's normals, wall removal and coverage (tests in RealisticSpaceTests.swift).

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

// MARK: Something on a table

public struct ObjectFit {
    /// Footprint seen from above, mm, centred on its middle, along `xAxis` and `yAxis`.
    public var outline: [P2]
    /// The footprint on the table (world, m), for drawing over the camera picture.
    public var outlineWorld: [V3]
    /// Outer size of the footprint (mm): the smallest rectangle round it, width its longer side
    /// (along x), length the shorter (along y). The same however the phone is turned.
    public var width: Double
    public var length: Double
    /// How high it stands above the table (mm, near the top – 85th percentile) and its middle height.
    public var height: Double
    public var midHeight: Double
    /// Middle of the footprint on the table (world, m).
    public var centre: V3
    /// The outline's x (the rectangle's long side, pointing as much to the camera's right as it can)
    /// and y (up × x: away when x is right) directions and the table's up (world).
    public var xAxis: V3
    public var yAxis: V3
    public var up: V3
    /// LiDAR points within reach (60 cm across).
    public var points: Int
    /// True when the edge was sharpened with the camera picture (`refineOutline`).
    public var sharpened = false
}

/// The camera's right laid flat on the table (any level direction when there is none, or it
/// points along `up`).
func flatRight(_ F: (u: V3, v: V3, up: V3), _ right: V3?) -> V3 {
    if let right {
        let flat = right - F.up * vdot(right, F.up)
        if vlength(flat) > 0.1 { return vnormalized(flat) }
    }
    return F.u
}

/// The table under the cross-hair: the fullest 2 mm level within 35 cm that lies below `limit`
/// (`X`, `Y` across and `H` up from the aim, m). Its median height and how much its points scatter.
func tableLevel(_ X: [Double], _ Y: [Double], _ H: [Double], limit: Double) -> (height: Double, scatter: Double)? {
    let n = min(X.count, Y.count, H.count)
    var counts: [Int: Int] = [:]
    for i in 0..<n {
        if X[i] * X[i] + Y[i] * Y[i] > 0.35 * 0.35 || H[i] > limit || H[i] < -0.4 { continue }
        counts[Int((H[i] / 0.002).rounded(.down)), default: 0] += 1
    }
    var tk = 0, tc = 0
    for (k, c) in counts {
        let sum = c + (counts[k - 1] ?? 0) + (counts[k + 1] ?? 0)
        if sum > tc || (sum == tc && k < tk) {
            tc = sum
            tk = k
        }
    }
    if tc < 50 { return nil }
    var level: [Double] = []
    for i in 0..<n where abs(H[i] - (Double(tk) + 0.5) * 0.002) < 0.004 && X[i] * X[i] + Y[i] * Y[i] < 0.35 * 0.35 { level.append(H[i]) }
    if level.isEmpty { return nil }
    let table = median(level)
    return (table, 1.4826 * median(level.map { abs($0 - table) }))
}

/// What stands up from the table (between `cut` and 40 cm, `H` above the table) on a grid seen from
/// above: the part joined to the cross-hair (or the nearest one within 1 cm), with its gaps closed,
/// and the mean height of each of its cells that has points. Nil when there is none, it is a
/// speck, or it reaches the edge of the 60 cm window (then it is not one thing on a table).
private func objectCells(_ X: [Double], _ Y: [Double], _ H: [Double], cut: Double, cellMM: Double) -> (part: [UInt8], size: Int, R: Int, heights: [Double])? {
    let cell = cellMM / 1000
    let R = Int((0.3 / cell).rounded(.up))
    let size = 2 * R + 1
    var count = [Int32](repeating: 0, count: size * size)
    var sum = [Double](repeating: 0, count: size * size)
    for i in 0..<H.count {
        if H[i] < cut || H[i] > 0.4 { continue }
        let gx = Int((X[i] / cell).rounded()) + R
        let gy = Int((Y[i] / cell).rounded()) + R
        if gx < 0 || gy < 0 || gx >= size || gy >= size { continue }
        let k = gy * size + gx
        count[k] += 1
        sum[k] += H[i]
    }
    var occ = count.map { $0 > 0 ? UInt8(1) : UInt8(0) }
    // Close small gaps between the LiDAR's points (grow, shrink), then drop lone specks (shrink, grow).
    occ = shrinkCells(growCells(occ, size), size)
    occ = growCells(shrinkCells(occ, size), size)

    var start = -1
    var bestD = Int.max
    let reach = Int((0.01 / cell).rounded(.up))
    for dy in -reach...reach {
        for dx in -reach...reach {
            let k = (R + dy) * size + R + dx
            if occ[k] == 1 && dx * dx + dy * dy < bestD {
                bestD = dx * dx + dy * dy
                start = k
            }
        }
    }
    if start < 0 { return nil }
    var part = [UInt8](repeating: 0, count: size * size)
    var stack = [start]
    part[start] = 1
    var cells = 0
    while let k = stack.popLast() {
        cells += 1
        let x = k % size, y = k / size
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            let nx = x + dx, ny = y + dy
            if nx < 0 || ny < 0 || nx >= size || ny >= size { continue }
            let j = ny * size + nx
            if occ[j] == 1 && part[j] == 0 {
                part[j] = 1
                stack.append(j)
            }
        }
    }
    if cells < 12 { return nil }
    for i in 0..<size where part[i] == 1 || part[(size - 1) * size + i] == 1 || part[i * size] == 1 || part[i * size + size - 1] == 1 { return nil }
    fillCellHoles(&part, size)
    var heights: [Double] = []
    for k in 0..<part.count where part[k] == 1 && count[k] > 0 { heights.append(sum[k] / Double(count[k])) }
    if heights.isEmpty { return nil }
    return (part, size, R, heights)
}

/// Something lying on a table: the table is the most common level below the cross-hair, the
/// object is everything standing up from it that joins the point under the cross-hair.
public func fitObject(_ points: [V3], aim: V3, up: V3 = V3(0, 1, 0), right: V3? = nil, cellMM: Double = 2) -> ObjectFit? {
    let F = flatFrame(up)
    // Axes on the table: x as the camera's right (flattened), y away.
    let ux = flatRight(F, right)
    let uy = vcross(F.up, ux)
    let n = points.count
    var X = [Double](repeating: 0, count: n)
    var Y = [Double](repeating: 0, count: n)
    var H = [Double](repeating: 0, count: n)
    var usable = 0
    for i in 0..<n {
        let d = points[i] - aim
        X[i] = vdot(d, ux)
        Y[i] = vdot(d, uy)
        H[i] = vdot(d, F.up)
        if X[i] * X[i] + Y[i] * Y[i] < 0.35 * 0.35 { usable += 1 }
    }
    if usable < 200 { return nil }

    // 1. The table: the fullest 2 mm level below the cross-hair.
    guard let level = tableLevel(X, Y, H, limit: -0.003) else { return nil }
    let table = level.height
    // How much the table's points scatter: what stands up must stand clear of that.
    let scatter = level.scatter
    for i in 0..<n { H[i] -= table }

    // 2. What stands up from it and joins the cross-hair, on a grid seen from above.
    let above = max(0.003, 4 * scatter)
    guard var seg = objectCells(X, Y, H, cut: above, cellMM: cellMM) else { return nil }
    // Flying pixels hang between the top edge and the table behind it and make the footprint grow.
    // Cutting at half the height puts the edge in the middle of such a ramp – but at most 6 mm
    // above the noise, so a rounded thing keeps most of its foot.
    var cut = above
    let lifted = max(above, min(0.5 * median(seg.heights), above + 0.006))
    if lifted > above + 0.0005, let again = objectCells(X, Y, H, cut: lifted, cellMM: cellMM) {
        seg = again
        cut = lifted
    }
    let R = seg.R, size = seg.size

    // 3. The outline round the cells, in mm, round the cross-hair.
    let loop = traceCells(seg.part, size)
    if loop.count < 4 { return nil }
    let mmLoop = loop.map { P2((Double($0.x) - Double(R) - 0.5) * cellMM, (Double($0.y) - Double(R) - 0.5) * cellMM) }
    // A cell counts when any point falls in it, and the points scatter: the edge comes out about half
    // a cell plus the scatter too far out. Pull it back in.
    let smooth = insetLoop(simplifyLoop(chaikin(mmLoop), cellMM * 0.35), cellMM / 2 + min(2, scatter * 1000))

    // 4. Its size: the smallest rectangle round it, the straight sides placed from the points of
    //    the thing itself (those in its cells).
    let cell = cellMM / 1000
    var mine: [P2] = []
    for i in 0..<n where H[i] >= cut && H[i] <= 0.4 {
        let gx = Int((X[i] / cell).rounded()) + R
        let gy = Int((Y[i] / cell).rounded()) + R
        if gx < 0 || gy < 0 || gx >= size || gy >= size || seg.part[gy * size + gx] == 0 { continue }
        mine.append(P2(X[i] * 1000, Y[i] * 1000))
    }
    guard let sq = squareUp(smooth, points: mine) else { return nil }
    func toWorld(_ p: P2) -> V3 { aim + ux * (p.x / 1000) + uy * (p.y / 1000) + F.up * table }
    return ObjectFit(
        outline: sq.outline,
        outlineWorld: smooth.map { toWorld($0) },
        width: sq.width,
        length: sq.length,
        height: r1(quantile(seg.heights, 0.85) * 1000),
        midHeight: r1(median(seg.heights) * 1000),
        centre: toWorld(sq.mid),
        xAxis: ux * sq.dir.x + uy * sq.dir.y,
        yAxis: ux * (-sq.dir.y) + uy * sq.dir.x,
        up: F.up,
        points: usable
    )
}

/// Convex hull (monotone chain), anticlockwise, without repeated points.
func convexHull(_ pts: [P2]) -> [P2] {
    let s = pts.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
    if s.count < 3 { return s }
    func turn(_ o: P2, _ a: P2, _ b: P2) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
    var lower: [P2] = []
    for p in s {
        while lower.count >= 2 && turn(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
        lower.append(p)
    }
    var upper: [P2] = []
    for p in s.reversed() {
        while upper.count >= 2 && turn(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
        upper.append(p)
    }
    return Array(lower.dropLast()) + Array(upper.dropLast())
}

/// The smallest-area rectangle round points (rotating calipers: one side lies on a hull edge).
/// `dir` is along its longer side, pointing to +x (or +y when straight across); `mid` its middle.
func minAreaRect(_ pts: [P2]) -> (dir: P2, long: Double, short: Double, mid: P2)? {
    let h = convexHull(pts)
    if h.count < 3 { return nil }
    var best: (area: Double, e: P2, a0: Double, a1: Double, b0: Double, b1: Double)? = nil
    for i in 0..<h.count {
        let d = h[(i + 1) % h.count] - h[i]
        let l = vlen2(d)
        if l < 1e-9 { continue }
        let e = d / l
        var a0 = Double.infinity, a1 = -Double.infinity, b0 = Double.infinity, b1 = -Double.infinity
        for p in h {
            let a = p.x * e.x + p.y * e.y, b = -p.x * e.y + p.y * e.x
            a0 = min(a0, a)
            a1 = max(a1, a)
            b0 = min(b0, b)
            b1 = max(b1, b)
        }
        let area = (a1 - a0) * (b1 - b0)
        if best == nil || area < best!.area { best = (area, e, a0, a1, b0, b1) }
    }
    guard let r = best else { return nil }
    let nrm = P2(-r.e.y, r.e.x)
    let mid = r.e * ((r.a0 + r.a1) / 2) + nrm * ((r.b0 + r.b1) / 2)
    let sa = r.a1 - r.a0, sb = r.b1 - r.b0
    var dir = sa >= sb ? r.e : nrm
    if dir.x < 0 || (dir.x == 0 && dir.y < 0) { dir = -dir }
    return (dir, max(sa, sb), min(sa, sb), mid)
}

/// A footprint's size however it lies (mm, in a flat x/y frame): the smallest rectangle round it.
/// A grid outline is a staircase whose steps depend on how the thing is turned against the grid,
/// so each straight side is then placed from the thing's own `points` (same frame, mm) instead:
/// at the 90th percentile of those within 8 mm of it. Width is the longer side, along `dir`
/// (pointing to +x); `outline` is the footprint in that frame, centred on the rectangle.
func squareUp(_ loop: [P2], points: [P2]) -> (dir: P2, width: Double, length: Double, mid: P2, outline: [P2])? {
    guard let rect = minAreaRect(loop) else { return nil }
    var dir = rect.dir
    var nrm = P2(-dir.y, dir.x)
    let L = rect.long, S = rect.short
    let mid = rect.mid
    func frame(_ p: P2) -> P2 {
        let d = p - mid
        return P2(vdot2(d, dir), vdot2(d, nrm))
    }
    // The outline every 0.5 mm and the points near it, in the rectangle's frame.
    var even: [P2] = []
    for i in 0..<loop.count {
        let a = loop[i], b = loop[(i + 1) % loop.count]
        let k = max(1, Int((vlen2(b - a) / 0.5).rounded(.up)))
        for j in 0..<k { even.append(frame(a + (b - a) * (Double(j) / Double(k)))) }
    }
    var near: [P2] = []
    for p in points {
        let q = frame(p)
        if abs(q.x) < L / 2 + 10 && abs(q.y) < S / 2 + 10 { near.append(q) }
    }
    // The sides +x, −x, +y, −y as distances from the middle.
    var pos = [L / 2, L / 2, S / 2, S / 2]
    for k in 0..<4 {
        let sign: Double = k % 2 == 0 ? 1 : -1
        // Only the middle 70 % of a side: the corners are rounded.
        let span = (k < 2 ? S : L) / 2 * 0.7
        func split(_ q: P2) -> (across: Double, along: Double) {
            k < 2 ? (across: q.x * sign, along: q.y) : (across: q.y * sign, along: q.x)
        }
        var onSide: [Double] = []
        for q in even {
            let s = split(q)
            if abs(s.along) < span && s.across > 0 { onSide.append(s.across) }
        }
        if onSide.count < 8 { continue }
        let line = median(onSide)
        // A curved side (an oval) keeps the rectangle's: its middle is not where the edge is.
        let straight = onSide.filter { abs($0 - line) < 2 }.count
        if Double(straight) < 0.65 * Double(onSide.count) { continue }
        var across: [Double] = []
        for q in near {
            let s = split(q)
            if abs(s.along) < span && abs(s.across - line) < 8 { across.append(s.across) }
        }
        if across.count < 20 { continue }
        pos[k] = quantile(across, 0.9)
    }
    let centre = mid + dir * ((pos[0] - pos[1]) / 2) + nrm * ((pos[2] - pos[3]) / 2)
    var width = pos[0] + pos[1], length = pos[2] + pos[3]
    if length > width {
        swap(&width, &length)
        dir = nrm
        if dir.x < 0 || (dir.x == 0 && dir.y < 0) { dir = -dir }
        nrm = P2(-dir.y, dir.x)
    }
    let outline = loop.map { p -> P2 in
        let d = p - centre
        return P2(r1(vdot2(d, dir)), r1(vdot2(d, nrm)))
    }
    return (dir, r1(width), r1(length), centre, outline)
}

// MARK: Cells and loops

func growCells(_ m: [UInt8], _ size: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: m.count)
    for y in 0..<size {
        for x in 0..<size {
            var on: UInt8 = 0
            outer: for dy in -1...1 {
                for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0 && ny >= 0 && nx < size && ny < size && m[ny * size + nx] == 1 {
                        on = 1
                        break outer
                    }
                }
            }
            out[y * size + x] = on
        }
    }
    return out
}

func shrinkCells(_ m: [UInt8], _ size: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: m.count)
    for y in 0..<size {
        for x in 0..<size {
            var on: UInt8 = 1
            outer: for dy in -1...1 {
                for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    if nx < 0 || ny < 0 || nx >= size || ny >= size || m[ny * size + nx] == 0 {
                        on = 0
                        break outer
                    }
                }
            }
            out[y * size + x] = on
        }
    }
    return out
}

/// Fills enclosed gaps (what the outside can not reach is inside).
func fillCellHoles(_ m: inout [UInt8], _ size: Int) { fillCellHoles(&m, width: size, height: size) }

func fillCellHoles(_ m: inout [UInt8], width w: Int, height h: Int) {
    var outside = [UInt8](repeating: 0, count: m.count)
    var stack: [Int] = []
    func push(_ k: Int) {
        if m[k] == 0 && outside[k] == 0 {
            outside[k] = 1
            stack.append(k)
        }
    }
    for i in 0..<w {
        push(i)
        push((h - 1) * w + i)
    }
    for j in 0..<h {
        push(j * w)
        push(j * w + w - 1)
    }
    while let k = stack.popLast() {
        let x = k % w, y = k / w
        if x > 0 { push(k - 1) }
        if x < w - 1 { push(k + 1) }
        if y > 0 { push(k - w) }
        if y < h - 1 { push(k + w) }
    }
    for k in 0..<m.count where outside[k] == 0 { m[k] = 1 }
}

/// The outer boundary of the cells as a loop of cell corners (corner (x, y) is the top-left of
/// cell (x, y)), walking with the cells on the right (y down).
func traceCells(_ m: [UInt8], _ size: Int) -> [(x: Int, y: Int)] { traceCells(m, width: size, height: size) }

func traceCells(_ m: [UInt8], width: Int, height: Int) -> [(x: Int, y: Int)] {
    let size = width
    func on(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < width && y < height && m[y * width + x] == 1 }
    guard let first = m.firstIndex(of: 1) else { return [] }
    let sx = first % size, sy = first / size
    let DX = [1, 0, -1, 0], DY = [0, 1, 0, -1]
    func rightCell(_ x: Int, _ y: Int, _ d: Int) -> (Int, Int) { [(x, y), (x - 1, y), (x - 1, y - 1), (x, y - 1)][d] }
    func leftCell(_ x: Int, _ y: Int, _ d: Int) -> (Int, Int) { [(x, y - 1), (x, y), (x - 1, y), (x - 1, y - 1)][d] }
    var out: [(x: Int, y: Int)] = []
    var x = sx, y = sy, d = 0
    for _ in 0..<(4 * m.count) {
        out.append((x, y))
        x += DX[d]
        y += DY[d]
        if x == sx && y == sy { break }
        // Prefer turning right (keeps cells that only touch at a corner apart), then straight, then left.
        for t in [1, 0, 3, 2] {
            let nd = (d + t) % 4
            let r = rightCell(x, y, nd), l = leftCell(x, y, nd)
            if on(r.0, r.1) && !on(l.0, l.1) {
                d = nd
                break
            }
        }
    }
    // Keep only the corners where the direction changes.
    let n = out.count
    return out.enumerated().filter { i, p in
        let a = out[(i - 1 + n) % n], b = out[(i + 1) % n]
        return (p.x - a.x) * (b.y - p.y) - (p.y - a.y) * (b.x - p.x) != 0
    }.map { $0.element }
}

/// One round of corner cutting (smooths the staircase of the grid).
func chaikin(_ pts: [P2]) -> [P2] {
    var out: [P2] = []
    for i in 0..<pts.count {
        let a = pts[i], b = pts[(i + 1) % pts.count]
        out.append(a * 0.75 + b * 0.25)
        out.append(a * 0.25 + b * 0.75)
    }
    return out
}

/// Douglas–Peucker on a closed loop: drops points closer than `tol` to the line through their neighbours.
func simplifyLoop(_ pts: [P2], _ tol: Double) -> [P2] {
    if pts.count < 8 { return pts }
    var far = 0
    var fd = -1.0
    for i in 1..<pts.count {
        let d = vlen2(pts[i] - pts[0])
        if d > fd {
            fd = d
            far = i
        }
    }
    func run(_ a: ArraySlice<P2>) -> [P2] {
        let a = Array(a)
        if a.count < 3 { return a }
        let p = a[0], q = a[a.count - 1]
        let len = max(1e-9, vlen2(q - p))
        var k = -1
        var dk = -1.0
        for i in 1..<(a.count - 1) {
            let d = abs((q.x - p.x) * (p.y - a[i].y) - (p.x - a[i].x) * (q.y - p.y)) / len
            if d > dk {
                dk = d
                k = i
            }
        }
        if dk <= tol { return [p, q] }
        let left = run(a[0...k])
        return Array(left.dropLast()) + run(a[k...])
    }
    let first = run(pts[0...far])
    let second = run(ArraySlice(Array(pts[far...]) + [pts[0]]))
    return Array(first.dropLast()) + Array(second.dropLast())
}

@inline(__always) func vlen2(_ p: P2) -> Double { (p.x * p.x + p.y * p.y).squareRoot() }

/// Moves every point of a loop `d` inwards (along the mean of its two edges' normals).
func insetLoop(_ pts: [P2], _ d: Double) -> [P2] {
    let n = pts.count
    if n < 3 || d <= 0 { return pts }
    var a = 0.0
    for i in 0..<n {
        let p = pts[i], q = pts[(i + 1) % n]
        a += p.x * q.y - q.x * p.y
    }
    let sign = a > 0 ? 1.0 : -1.0
    func normal(_ p: P2, _ q: P2) -> P2 {
        let e = q - p
        let l = max(1e-12, vlen2(e))
        return P2(-e.y / l * sign, e.x / l * sign)
    }
    return (0..<n).map { i in
        let p = pts[i]
        let n1 = normal(pts[(i - 1 + n) % n], p)
        let n2 = normal(p, pts[(i + 1) % n])
        let m = n1 + n2
        let ml = vlen2(m)
        if ml < 1e-6 { return p }
        // Keep the offset from each edge at d (limited at sharp corners).
        let k = d / max(0.5, ml / 2)
        return p + m / ml * k
    }
}

/// Area of a loop (mm²).
public func loopArea(_ pts: [P2]) -> Double {
    var a = 0.0
    for i in 0..<pts.count {
        let p = pts[i], q = pts[(i + 1) % pts.count]
        a += p.x * q.y - q.x * p.y
    }
    return abs(a) / 2
}

// MARK: A pipe or rod

public struct CylinderFit {
    /// Outside diameter (mm).
    public var diameter: Double
    /// The axis direction and a point on it near the cross-hair (world).
    public var axis: V3
    public var centre: V3
    /// Median distance of the points from the fitted surface (mm).
    public var residual: Double
    public var points: Int
    /// How much of the round the points cover (degrees). About 180 when seen from the side; much
    /// below ~90 (the flanks not seen) and the diameter is unsure.
    public var coverage: Double = 0
}

/// A symmetric 3 × 3 system [a b c; b d e; c e f] · x = (p, q, s), by Cramer's rule.
@inline(__always) func solveSymmetric3(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double, _ f: Double,
                                       _ p: Double, _ q: Double, _ s: Double) -> (Double, Double, Double)? {
    let det = a * (d * f - e * e) - b * (b * f - e * c) + c * (b * e - d * c)
    if abs(det) < 1e-18 || !det.isFinite { return nil }
    let x = (p * (d * f - e * e) - b * (q * f - e * s) + c * (q * e - d * s)) / det
    let y = (a * (q * f - e * s) - p * (b * f - e * c) + c * (b * s - q * c)) / det
    let z = (a * (d * s - q * e) - b * (b * s - q * c) + p * (b * e - d * c)) / det
    return (x, y, z)
}

/// Circle through 2D points: algebraic (Kåsa) start, then a few geometric (Gauss–Newton) steps.
/// Sums only (no arrays per point): it runs a few hundred times per pipe.
public func circleFitGeometric(_ pts: [P2]) -> (cx: Double, cy: Double, r: Double)? {
    let n = Double(pts.count)
    if pts.count < 5 { return nil }
    var mx = 0.0, my = 0.0
    for p in pts {
        mx += p.x
        my += p.y
    }
    mx /= n
    my /= n
    var suu = 0.0, suv = 0.0, svv = 0.0, suuu = 0.0, svvv = 0.0, suvv = 0.0, svuu = 0.0
    for p in pts {
        let u = p.x - mx, v = p.y - my
        suu += u * u
        suv += u * v
        svv += v * v
        suuu += u * u * u
        svvv += v * v * v
        suvv += u * v * v
        svuu += v * u * u
    }
    let det = suu * svv - suv * suv
    if abs(det) < 1e-18 { return nil }
    let a = (suuu + suvv) / 2, b = (svvv + svuu) / 2
    var cu = (a * svv - b * suv) / det
    var cv = (b * suu - a * suv) / det
    var r = (cu * cu + cv * cv + (suu + svv) / n).squareRoot()
    // Geometric refinement: minimise Σ (|p − c| − r)².
    for _ in 0..<8 {
        // JᵀJ and Jᵀe with the row (−dx/d, −dy/d, −1).
        var a00 = 0.0, a01 = 0.0, a02 = 0.0, a11 = 0.0, a12 = 0.0
        var g0 = 0.0, g1 = 0.0, g2 = 0.0
        for p in pts {
            let dx = p.x - mx - cu, dy = p.y - my - cv
            let d = max(1e-12, (dx * dx + dy * dy).squareRoot())
            let e = d - r
            let j0 = -dx / d, j1 = -dy / d
            a00 += j0 * j0
            a01 += j0 * j1
            a02 -= j0
            a11 += j1 * j1
            a12 -= j1
            g0 += j0 * e
            g1 += j1 * e
            g2 -= e
        }
        guard let step = solveSymmetric3(a00, a01, a02, a11, a12, n, -g0, -g1, -g2) else { break }
        cu += step.0
        cv += step.1
        r += step.2
        if abs(step.0) + abs(step.1) + abs(step.2) < 1e-9 { break }
    }
    return r > 0 && r.isFinite ? (cu + mx, cv + my, r) : nil
}

/// The points joined to the one nearest `aim` (4 mm cells, neighbours touching): a wall or table
/// behind the pipe is left out when there is a gap to it.
public func connectedNear(_ pts: [V3], aim: V3, cell: Double = 0.004) -> [V3] {
    if pts.isEmpty { return pts }
    struct Key: Hashable { var x: Int; var y: Int; var z: Int }
    func key(_ p: V3) -> Key { Key(x: Int((p.x / cell).rounded(.down)), y: Int((p.y / cell).rounded(.down)), z: Int((p.z / cell).rounded(.down))) }
    var cells: [Key: [Int]] = [:]
    for (i, p) in pts.enumerated() { cells[key(p), default: []].append(i) }
    var start = 0
    var bd = Double.infinity
    for (i, p) in pts.enumerated() {
        let d = vlength(p - aim)
        if d < bd {
            bd = d
            start = i
        }
    }
    let k0 = key(pts[start])
    var seen: Set<Key> = [k0]
    var stack = [k0]
    var out: [V3] = []
    while let k = stack.popLast() {
        for i in cells[k] ?? [] { out.append(pts[i]) }
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    let nk = Key(x: k.x + dx, y: k.y + dy, z: k.z + dz)
                    if !seen.contains(nk) && cells[nk] != nil {
                        seen.insert(nk)
                        stack.append(nk)
                    }
                }
            }
        }
    }
    return out
}

/// Surface normals from the points within `radius` of each (nil where there are too few, or they lie
/// on a line). Neighbours through a voxel hash.
func pointNormals(_ pts: [V3], radius: Double) -> [V3?] {
    struct Key: Hashable { var x: Int; var y: Int; var z: Int }
    func key(_ p: V3) -> Key { Key(x: Int((p.x / radius).rounded(.down)), y: Int((p.y / radius).rounded(.down)), z: Int((p.z / radius).rounded(.down))) }
    var cells: [Key: [Int]] = [:]
    for (i, p) in pts.enumerated() { cells[key(p), default: []].append(i) }
    let r2 = radius * radius
    var out = [V3?](repeating: nil, count: pts.count)
    for (i, p) in pts.enumerated() {
        let k = key(p)
        var m = 0
        var sx = 0.0, sy = 0.0, sz = 0.0, xx = 0.0, xy = 0.0, xz = 0.0, yy = 0.0, yz = 0.0, zz = 0.0
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    guard let list = cells[Key(x: k.x + dx, y: k.y + dy, z: k.z + dz)] else { continue }
                    for j in list {
                        let q = pts[j] - p
                        if q.x * q.x + q.y * q.y + q.z * q.z > r2 { continue }
                        m += 1
                        sx += q.x
                        sy += q.y
                        sz += q.z
                        xx += q.x * q.x
                        xy += q.x * q.y
                        xz += q.x * q.z
                        yy += q.y * q.y
                        yz += q.y * q.z
                        zz += q.z * q.z
                    }
                }
            }
        }
        if m < 6 { continue }
        let w = 1 / Double(m)
        let mx = sx * w, my = sy * w, mz = sz * w
        let c: [[Double]] = [
            [xx * w - mx * mx, xy * w - mx * my, xz * w - mx * mz],
            [xy * w - mx * my, yy * w - my * my, yz * w - my * mz],
            [xz * w - mx * mz, yz * w - my * mz, zz * w - mz * mz],
        ]
        let (vals, vecs) = eigenSymmetric3(c)
        let order = [0, 1, 2].sorted { vals[$0] < vals[$1] }
        if vals[order[1]] <= 1e-12 { continue }
        let lo = order[0]
        out[i] = vnormalized(V3(vecs[0][lo], vecs[1][lo], vecs[2][lo]))
    }
    return out
}

/// The direction square to the normals (the smallest of Σ n nᵀ): on a cylinder that is the axis.
/// Nil when it is not clear (too few normals, or a plane or a ball rather than a cylinder).
func axisFromNormals(_ normals: [V3?]) -> V3? {
    var s00 = 0.0, s01 = 0.0, s02 = 0.0, s11 = 0.0, s12 = 0.0, s22 = 0.0
    var used = 0
    for case let n? in normals {
        s00 += n.x * n.x
        s01 += n.x * n.y
        s02 += n.x * n.z
        s11 += n.y * n.y
        s12 += n.y * n.z
        s22 += n.z * n.z
        used += 1
    }
    if used < 20 { return nil }
    let (vals, vecs) = eigenSymmetric3([[s00, s01, s02], [s01, s11, s12], [s02, s12, s22]])
    let order = [0, 1, 2].sorted { vals[$0] < vals[$1] }
    if vals[order[0]] > 0.5 * vals[order[1]] { return nil }
    let k = order[0]
    return vnormalized(V3(vecs[0][k], vecs[1][k], vecs[2][k]))
}

/// A wall or table right behind the pipe that touches it (so `connectedNear` kept it): the plane on
/// which most points lie with their normals agreeing, with the cross-hair more than 5 mm in front
/// of it and (nearly) the farthest out – a big pipe's own flank is nearly flat too, but there the
/// other flank stands farther out than the cross-hair. Its points (within 4 mm) when they are
/// more than a quarter of all, else nil.
func wallBehind(_ pts: [V3], normals: [V3?], aim: V3) -> [Bool]? {
    let withNormal = normals.indices.filter { normals[$0] != nil }
    if withNormal.count < 12 { return nil }
    let agree = cos(25 * Double.pi / 180)
    var seed: UInt64 = 0x2545F4914F6CDD1D
    func rand(_ n: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 33) % UInt64(n))
    }
    func support(_ n: V3, _ o: Double) -> Int {
        var c = 0
        for j in 0..<pts.count where abs(vdot(n, pts[j]) - o) < 0.004 {
            if let m = normals[j], abs(vdot(m, n)) > agree { c += 1 }
        }
        return c
    }
    var best: (n: V3, o: Double, c: Int)? = nil
    for _ in 0..<150 {
        let i = withNormal[rand(withNormal.count)]
        guard let n = normals[i] else { continue }
        let o = vdot(n, pts[i])
        if abs(vdot(n, aim) - o) <= 0.005 { continue }
        let c = support(n, o)
        if best == nil || c > best!.c { best = (n: n, o: o, c: c) }
    }
    guard var plane = best else { return nil }
    var inliers: [V3] = []
    for j in 0..<pts.count where abs(vdot(plane.n, pts[j]) - plane.o) < 0.004 {
        if let m = normals[j], abs(vdot(m, plane.n)) > agree { inliers.append(pts[j]) }
    }
    if let ls = leastSquaresPlane(inliers), abs(vdot(ls.normal, aim) - ls.offset) > 0.005 {
        let c = support(ls.normal, ls.offset)
        if c >= plane.c { plane = (n: ls.normal, o: ls.offset, c: c) }
    }
    let side = vdot(plane.n, aim) - plane.o
    if abs(side) <= 0.005 { return nil }
    var out = [Bool](repeating: false, count: pts.count)
    var count = 0
    var ahead: [Double] = []
    ahead.reserveCapacity(pts.count)
    for j in 0..<pts.count {
        let d = vdot(plane.n, pts[j]) - plane.o
        ahead.append(side > 0 ? d : -d)
        if abs(d) < 0.004 {
            out[j] = true
            count += 1
        }
    }
    if abs(side) < 0.8 * quantile(ahead, 0.98) { return nil }
    if Double(count) <= 0.25 * Double(pts.count) { return nil }
    return out
}

/// A pipe, rod or hose seen from the side: the LiDAR points within `reach` of the cross-hair (and
/// joined to it, a wall touching it from behind left out), the axis square to their surface
/// normals, refined to where the points fall on one circle best, and that circle's diameter.
/// Stray points are dropped and the circle fitted again. Nil below 12 mm: too few, too noisy
/// LiDAR points across it to tell.
public func fitCylinder(_ points: [V3], aim: V3, reach: Double = 0.05) -> CylinderFit? {
    var near = connectedNear(points.filter { vlength($0 - aim) < reach }, aim: aim)
    if near.count < 60 { return nil }
    if near.count > 1500 {
        let step = Double(near.count) / 1500
        near = (0..<1500).map { near[Int(Double($0) * step)] }
    }
    var normals = pointNormals(near, radius: 0.008)
    if let wall = wallBehind(near, normals: normals, aim: aim) {
        var keptPoints: [V3] = []
        var keptNormals: [V3?] = []
        for j in 0..<near.count where !wall[j] {
            keptPoints.append(near[j])
            keptNormals.append(normals[j])
        }
        if keptPoints.count >= 60 {
            near = keptPoints
            normals = keptNormals
        }
    }
    func basis(_ axis: V3) -> (V3, V3) {
        let seed = abs(axis.x) < 0.9 ? V3(1, 0, 0) : V3(0, 1, 0)
        let e1 = vnormalized(vcross(seed, axis))
        return (e1, vcross(axis, e1))
    }
    func flat(_ axis: V3, _ pts: [V3]) -> [P2] {
        let (e1, e2) = basis(axis)
        return pts.map { P2(vdot($0, e1), vdot($0, e2)) }
    }
    func score(_ axis: V3, _ pts: [V3]) -> (c: (cx: Double, cy: Double, r: Double), res: Double)? {
        let f = flat(axis, pts)
        guard let c = circleFitGeometric(f), c.r >= 0.0015, c.r <= 0.2 else { return nil }
        let res = median(f.map { abs(((($0.x - c.cx) * ($0.x - c.cx) + ($0.y - c.cy) * ($0.y - c.cy)).squareRoot()) - c.r) })
        return (c, res)
    }
    // 1. The axis: on a cylinder every surface normal stands square to it. Noisy points need a
    //    wider patch per normal; when even that is unclear, try directions over the half sphere
    //    (on fewer points).
    var start = axisFromNormals(normals)
    if start == nil { start = axisFromNormals(pointNormals(near, radius: 0.014)) }
    if start == nil {
        let every = max(1, near.count / 400 + (near.count % 400 == 0 ? 0 : 1))
        let few = stride(from: 0, to: near.count, by: every).map { near[$0] }
        var best: (axis: V3, res: Double)? = nil
        let N = 300
        for i in 0..<N {
            let z = 1 - (Double(i) + 0.5) / Double(N)
            let rr = (1 - z * z).squareRoot()
            let t = Double(i) * 2.399963229728653
            let axis = V3(rr * cos(t), z, rr * sin(t))
            if let sc = score(axis, few), best == nil || sc.res < best!.res { best = (axis: axis, res: sc.res) }
        }
        start = best?.axis
    }
    guard let axis0 = start else { return nil }
    // 2. A small search round it (±6°, then finer): where the points fall on one circle best.
    var found = (axis: axis0, res: score(axis0, near)?.res ?? Double.infinity)
    for span in [0.1, 0.03, 0.01] {
        let base = found.axis
        let (p1, p2) = basis(base)
        for i in -2...2 {
            for j in -2...2 where i != 0 || j != 0 {
                let axis = vnormalized(base + p1 * (Double(i) / 2 * span) + p2 * (Double(j) / 2 * span))
                if let sc = score(axis, near), sc.res < found.res { found = (axis: axis, res: sc.res) }
            }
        }
    }
    if !found.res.isFinite { return nil }
    // One way round for the axis (it has none of its own), so frames compare.
    let axis = found.axis.y < 0 || (found.axis.y == 0 && found.axis.x < 0) ? -found.axis : found.axis
    // 3. Drop what is off the surface, fit again.
    var pts = near
    var fit = score(axis, pts)
    for _ in 0..<2 {
        guard let current = fit else { break }
        let f = flat(axis, pts)
        let keep = max(0.002, 3 * current.res)
        var kept: [V3] = []
        for (i, q) in f.enumerated() where abs(((q.x - current.c.cx) * (q.x - current.c.cx) + (q.y - current.c.cy) * (q.y - current.c.cy)).squareRoot() - current.c.r) < keep {
            kept.append(pts[i])
        }
        if kept.count < 30 { break }
        pts = kept
        fit = score(axis, pts)
    }
    guard let done = fit else { return nil }
    let diameter = done.c.r * 2000
    if diameter < 12 { return nil }
    // 4. How much of the round is seen: 360° less the widest gap without points (5° steps; a
    //    few lone points do not close a gap).
    var bins = [Int](repeating: 0, count: 72)
    for q in flat(axis, pts) {
        let a = atan2(q.y - done.c.cy, q.x - done.c.cx)
        let k = Int(((a + .pi) / (2 * .pi) * 72).rounded(.down))
        bins[min(71, max(0, k))] += 1
    }
    let enough = max(2, pts.count / 400)
    var gap = 0, run = 0
    for k in 0..<144 {
        if bins[k % 72] < enough {
            run += 1
            gap = max(gap, run)
        } else {
            run = 0
        }
    }
    let coverage = gap >= 72 ? 0 : Double(72 - gap) * 5
    let (e1, e2) = basis(axis)
    let centre = e1 * done.c.cx + e2 * done.c.cy + axis * vdot(aim, axis)
    return CylinderFit(diameter: r1(diameter), axis: axis, centre: centre, residual: r1(done.res * 1000), points: pts.count, coverage: coverage)
}

// MARK: Two surfaces

/// The surface round a point (LiDAR points within `reach`), for measuring a gap.
public func surfaceNear(_ points: [V3], at p: V3, reach: Double = 0.03) -> (plane: Plane, point: V3)? {
    let near = points.filter { vlength($0 - p) < reach }
    guard let fit = fitPlane(near, threshold: 0.004), fit.inliers >= 20 else { return nil }
    // A small patch locates the selected surface, but its normal is noisy. A gap measured
    // farther along that plane amplifies this tilt error. Refine with a wider patch of
    // points agreeing with the selected plane; do not average in a nearby raised surface.
    var plane = fit.plane
    let residual = median(near.map { abs(vdot(plane.normal, $0) - plane.offset) })
    let tolerance = min(0.003, max(0.002, residual * 4))
    for radius in [reach * 2, reach * 3] {
        let support = points.filter {
            vlength($0 - p) < radius && abs(vdot(plane.normal, $0) - plane.offset) < tolerance
        }
        if support.count >= fit.inliers, let refined = leastSquaresPlane(support) { plane = refined }
    }
    // The plane through the aimed point's foot.
    let q = p - plane.normal * (vdot(plane.normal, p) - plane.offset)
    return (plane, q)
}

/// The gap between two surfaces (mm, from the second point straight to the first surface) and the
/// angle between them (degrees, 0 = parallel).
public func gapBetween(_ a: (plane: Plane, point: V3), _ b: (plane: Plane, point: V3)) -> (gapMM: Double, angle: Double) {
    let gap = abs(vdot(a.plane.normal, b.point) - a.plane.offset) * 1000
    let c = min(1, abs(vdot(a.plane.normal, b.plane.normal)))
    return (r1(gap), r1(acos(c) * 180 / .pi))
}

// MARK: A sharper edge from the camera picture

/// A world point to full-picture pixels (nil behind the camera).
public func project(_ p: V3, intrinsics K: Intrinsics, pose: CameraPose) -> P2? {
    let d = p - pose.position
    let cx = vdot(d, pose.x), cy = -vdot(d, pose.y), cz = -vdot(d, pose.z)
    if cz <= 1e-6 { return nil }
    return P2(K.fx * cx / cz + K.cx, K.fy * cy / cz + K.cy)
}

/// A full-picture pixel's ray where it meets the level `h` above `base` along `up` (world).
public func rayToLevel(_ u: Double, _ v: Double, intrinsics K: Intrinsics, pose: CameraPose, base: V3, up: V3, h: Double) -> V3? {
    let rc = K.ray(u, v)
    let dir = pose.x * rc.x - pose.y * rc.y - pose.z * rc.z
    let denom = vdot(dir, up)
    if abs(denom) < 1e-9 { return nil }
    let t = (vdot(base, up) + h - vdot(pose.position, up)) / denom
    if t <= 0 { return nil }
    return pose.position + dir * t
}

private func sampleGray(_ g: GrayImage, _ x: Double, _ y: Double) -> Double {
    let fx = x - 0.5, fy = y - 0.5
    let i = Int(fx.rounded(.down)), j = Int(fy.rounded(.down))
    if i < 0 || j < 0 || i + 1 >= g.width || j + 1 >= g.height { return .nan }
    let a = fx - Double(i), b = fy - Double(j)
    let k = j * g.width + i
    let p = g.pixels
    let top = (1 - a) * Double(p[k]) + a * Double(p[k + 1])
    let bottom = (1 - a) * Double(p[k + g.width]) + a * Double(p[k + g.width + 1])
    return (1 - b) * top + b * bottom
}

/// The LiDAR footprint is good to a couple of mm; the camera picture has the edge to a fraction of
/// a mm. For each point round the outline: look across the edge in the picture (between where the
/// table-level and the top-level outline land), take the clear brightness step nearest the LiDAR
/// edge, and lay it back on the table – at table level where the side faces the camera (its bottom
/// edge is what shows), at the top where it faces away. Points without a clear step keep the LiDAR
/// edge (a running median along the loop smooths single wrong steps). Nil when too little of the
/// edge was found, or the steps are not the same way round (dark to light) along most of it.
/// `scale`: full-picture pixels per pixel of `gray`.
public func refineOutline(_ fit: ObjectFit, gray g: GrayImage, scale: Double, intrinsics K: Intrinsics, pose: CameraPose) -> ObjectFit? {
    let H = fit.height / 1000
    func toWorld(_ x: Double, _ y: Double) -> V3 { fit.centre + fit.xAxis * (x / 1000) + fit.yAxis * (y / 1000) }
    // Even points every ~1,5 mm round the loop.
    let loop = fit.outline
    var even: [P2] = []
    for i in 0..<loop.count {
        let a = loop[i], b = loop[(i + 1) % loop.count]
        let n = max(1, Int((vlen2(b - a) / 1.5).rounded(.up)))
        for k in 0..<n { even.append(a + (b - a) * (Double(k) / Double(n))) }
    }
    let n = even.count
    if n < 12 { return nil }
    // Smooth the LiDAR edge's small zigzags first (its normals would point every which way).
    for _ in 0..<3 {
        let prev = even
        for i in 0..<n {
            var sum = P2(0, 0)
            for k in -2...2 { sum += prev[(i + k + n) % n] }
            even[i] = sum / 5
        }
    }
    var mid = P2(0, 0)
    for p in even { mid += p / Double(n) }
    func px(_ p: V3) -> P2? { project(p, intrinsics: K, pose: pose).map { $0 / scale } }
    var shifts = [Double?](repeating: nil, count: n)
    var polarity = [Int8](repeating: 0, count: n)
    var outward = [P2](repeating: P2(0, 0), count: n)
    for i in 0..<n {
        let p = even[i]
        let prev = even[(i - 3 + n) % n], next = even[(i + 3) % n]
        var nrm = P2(next.y - prev.y, -(next.x - prev.x))
        nrm /= max(1e-12, vlen2(nrm))
        if vdot2(nrm, p - mid) < 0 { nrm = -nrm }
        outward[i] = nrm
        // The search line in the picture: ±4 mm across the edge, at the table and at the top.
        var ends: [P2] = []
        for d in [-4.0, 4.0] {
            for h in [0.0, H] {
                if let q = px(toWorld(p.x + nrm.x * d, p.y + nrm.y * d) + fit.up * h) { ends.append(q) }
            }
        }
        if ends.count < 4 { continue }
        let i0 = ends[0], t0 = ends[1], i1 = ends[2], t1 = ends[3]
        let dir = ((i1 + t1) - (i0 + t0)) / 2
        let len = vlen2(dir)
        if len < 2 { continue }
        let u = dir / len
        func along(_ q: P2) -> Double { vdot2(q - i0, u) }
        let s0 = min(along(i0), along(t0)) - 2
        let s1 = max(along(i1), along(t1)) + 2
        let step = 0.5
        var vals: [Double] = []
        var s = s0
        while s <= s1 {
            let q = i0 + u * s
            vals.append(sampleGray(g, q.x, q.y))
            s += step
        }
        // Which edge the picture shows: a side facing the camera is seen down to the table (the bottom
        // edge), a side facing away only to its top edge.
        let at = toWorld(p.x, p.y)
        let nWorld = fit.xAxis * nrm.x + fit.yAxis * nrm.y
        let level = vdot(nWorld, pose.position - at) > 0 ? 0 : H
        // Brightness steps along the line (signed: + is darker inside, lighter outside).
        var grads = [Double](repeating: .nan, count: vals.count)
        var top = 0.0
        if vals.count >= 3 {
            for k in 1..<(vals.count - 1) {
                let g = (vals[k + 1] - vals[k - 1]) / (2 * step)
                grads[k] = g
                if g.isFinite { top = max(top, abs(g)) }
            }
        }
        if !(top >= 6) { continue }
        // A shadow or a print on the thing can step harder than its edge: of the clear steps (at
        // least 0.6 of the strongest), take the one nearest the LiDAR edge.
        let lidarS = px(at + fit.up * level).map(along) ?? (s0 + s1) / 2
        var bestK = -1
        var bestD = Double.infinity
        for k in 1..<(vals.count - 1) {
            let a = abs(grads[k])
            guard a.isFinite, a >= 0.6 * top, a >= 6 else { continue }
            let l = abs(grads[k - 1]), r = abs(grads[k + 1])
            if (l.isFinite && l > a) || (r.isFinite && r > a) { continue }
            let dist = abs(s0 + Double(k) * step - lidarS)
            if dist < bestD {
                bestD = dist
                bestK = k
            }
        }
        if bestK < 1 { continue }
        let a = abs(grads[bestK])
        // Parabola through the neighbouring gradients for a sub-pixel peak.
        let gm = abs(grads[bestK - 1]).isFinite ? abs(grads[bestK - 1]) : a
        let gp = abs(grads[bestK + 1]).isFinite ? abs(grads[bestK + 1]) : a
        let den = gm - 2 * a + gp
        let off = abs(den) > 1e-9 ? max(-0.5, min(0.5, 0.5 * (gm - gp) / den)) : 0
        let bestS = s0 + (Double(bestK) + off) * step
        if !bestS.isFinite { continue }
        let pix = (i0 + u * bestS) * scale
        guard let w = rayToLevel(pix.x, pix.y, intrinsics: K, pose: pose, base: fit.centre, up: fit.up, h: level) else { continue }
        let d = w - fit.centre
        let shift = (vdot(d, fit.xAxis) * 1000 - p.x) * nrm.x + (vdot(d, fit.yAxis) * 1000 - p.y) * nrm.y
        if abs(shift) <= 4 {
            shifts[i] = shift
            polarity[i] = grads[bestK] > 0 ? 1 : -1
        }
    }
    // A real outline is the same kind of step all round (a dark thing on a light table, or the
    // other way round). Mixed steps are shadows, prints and the table's grain: keep the LiDAR edge.
    let darkInside = polarity.filter { $0 > 0 }.count
    let lightInside = polarity.filter { $0 < 0 }.count
    let majority: Int8 = darkInside >= lightInside ? 1 : -1
    if Double(max(darkInside, lightInside)) < 0.7 * Double(darkInside + lightInside) { return nil }
    for i in 0..<n where polarity[i] != 0 && polarity[i] != majority { shifts[i] = nil }
    let found = shifts.compactMap { $0 }.count
    if Double(found) < Double(n) * 0.6 { return nil }
    let moved: [P2] = (0..<n).map { i in
        var win: [Double] = []
        for k in -3...3 { if let v = shifts[(i + k + n) % n] { win.append(v) } }
        return even[i] + outward[i] * (win.isEmpty ? 0 : median(win))
    }
    let out = simplifyLoop(moved, 0.25)
    // The picture's edge has no grid steps: the smallest rectangle round it is the size.
    guard let sq = squareUp(out, points: []) else { return nil }
    var r = fit
    r.outline = sq.outline
    r.outlineWorld = out.map { toWorld($0.x, $0.y) }
    r.width = sq.width
    r.length = sq.length
    r.centre = toWorld(sq.mid.x, sq.mid.y)
    r.xAxis = fit.xAxis * sq.dir.x + fit.yAxis * sq.dir.y
    r.yAxis = fit.xAxis * (-sq.dir.y) + fit.yAxis * sq.dir.x
    r.sharpened = true
    return r
}

@inline(__always) func vdot2(_ a: P2, _ b: P2) -> Double { a.x * b.x + a.y * b.y }
