import Foundation

// Measuring with the LiDAR point cloud (many camera frames in ARKit's world, metres, y up):
// the inside of a box or drawer (`fitBox`), and something lying on a table (`fitObject`).
// A 1:1 port of src/scan/vision/box.ts in CadSHAPE – change both. The TypeScript side has the
// same tests with the same synthetic clouds (tests/box.test.ts).

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
            if dm.valid(k), z < maxDistance, (dm.confidence?[k] ?? 2) >= minConfidence {
                let ray = K.ray((Double(i) + 0.5) * sx, (Double(j) + 0.5) * sy)
                out.append(pose.world(ray * Double(z)))
            }
            i += step
        }
        j += step
    }
    return out
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
    var floor: [Double] = []
    for i in 0..<n where abs(H[i] - f0) < 0.004 && A[i] * A[i] + B[i] * B[i] < 0.1 * 0.1 { floor.append(H[i]) }
    if floor.count < 20 { return nil }
    let f = median(floor)
    for i in 0..<n { H[i] -= f }

    // 2. Looking out from the cross-hair in every direction: the nearest wall (inner face or the
    //    inner edge of the rim). A few points must agree, so a stray point does not count.
    let bins = 360
    var buckets = [[(r: Double, a: Double, b: Double)]](repeating: [], count: bins)
    var wallPoints = 0
    for i in 0..<n {
        if H[i] < 0.006 || H[i] > 0.4 { continue }
        let r = (A[i] * A[i] + B[i] * B[i]).squareRoot()
        if r < 0.01 || r > 0.6 { continue }
        var k = Int(((atan2(B[i], A[i]) + .pi) / (2 * .pi)) * Double(bins))
        if k >= bins { k = bins - 1 }
        buckets[k].append((r, A[i], B[i]))
        wallPoints += 1
    }
    var edge = [P2?](repeating: nil, count: bins)
    for k in 0..<bins {
        let list = buckets[k].sorted { $0.r < $1.r }
        if list.count < 3 { continue }
        var j = 0
        while j + 2 < list.count {
            if list[j + 2].r - list[j].r < 0.005 {
                edge[k] = P2(list[j + 1].a, list[j + 1].b)
                break
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
            if H[i] < 0.006 || H[i] > 0.4 { continue }
            for k in 0..<4 {
                let o = offset(k, RX[i], RY[i])
                if o >= -0.004 && o <= 0.02 && inSpan(k, RX[i], RY[i], 0.01) { heights[k].append(H[i]) }
            }
        }
        let sideH = heights.filter { $0.count >= 10 }.map { quantile($0, 0.95) }
        return sideH.isEmpty ? nil : median(sideH)
    }
    var height = wallHeight()
    for win in [0.004, 0.003, 0.003] {
        let top = (height ?? 0.4) - 0.004
        var lists: [[Double]] = [[], [], [], []]
        for i in 0..<n {
            if H[i] < 0.006 || H[i] > top { continue }
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
    /// Footprint seen from above, mm, centred on its middle, x right and y away as seen by the camera.
    public var outline: [P2]
    /// The footprint on the table (world, m), for drawing over the camera picture.
    public var outlineWorld: [V3]
    /// Outer size of the footprint (mm) along x and y.
    public var width: Double
    public var length: Double
    /// How high it stands above the table (mm, near the top – 85th percentile) and its middle height.
    public var height: Double
    public var midHeight: Double
    /// Middle of the footprint on the table (world, m).
    public var centre: V3
    /// The outline's x (camera right, flattened) and y (away) directions and the table's up (world).
    public var xAxis: V3
    public var yAxis: V3
    public var up: V3
    /// LiDAR points within reach (60 cm across).
    public var points: Int
    /// True when the edge was sharpened with the camera picture (`refineOutline`).
    public var sharpened = false
}

/// Something lying on a table: the table is the most common level below the cross-hair, the
/// object is everything standing up from it that joins the point under the cross-hair.
public func fitObject(_ points: [V3], aim: V3, up: V3 = V3(0, 1, 0), right: V3? = nil, cellMM: Double = 2) -> ObjectFit? {
    let F = flatFrame(up)
    // Axes on the table: x as the camera's right (flattened), y away.
    var ux = F.u
    if let right {
        let flat = right - F.up * vdot(right, F.up)
        if vlength(flat) > 0.1 { ux = vnormalized(flat) }
    }
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
    var counts: [Int: Int] = [:]
    for i in 0..<n {
        if X[i] * X[i] + Y[i] * Y[i] > 0.35 * 0.35 || H[i] > -0.003 || H[i] < -0.4 { continue }
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
    let table = median(level)
    // How much the table's points scatter: what stands up must stand clear of that.
    let scatter = 1.4826 * median(level.map { abs($0 - table) })
    for i in 0..<n { H[i] -= table }

    // 2. What stands up from it, on a grid seen from above.
    let cell = cellMM / 1000
    let R = Int((0.3 / cell).rounded(.up))
    let size = 2 * R + 1
    var grid = [UInt16](repeating: 0, count: size * size)
    var hmax = [Double](repeating: 0, count: size * size)
    let above = max(0.003, 4 * scatter)
    for i in 0..<n {
        if H[i] < above || H[i] > 0.4 { continue }
        let gx = Int((X[i] / cell).rounded()) + R
        let gy = Int((Y[i] / cell).rounded()) + R
        if gx < 0 || gy < 0 || gx >= size || gy >= size { continue }
        let k = gy * size + gx
        if grid[k] < UInt16.max { grid[k] += 1 }
        hmax[k] = max(hmax[k], H[i])
    }
    var occ = grid.map { $0 > 0 ? UInt8(1) : UInt8(0) }
    // Close small gaps between the LiDAR's points (grow, shrink), then drop lone specks (shrink, grow).
    occ = shrinkCells(growCells(occ, size), size)
    occ = growCells(shrinkCells(occ, size), size)

    // 3. The part joined to the cross-hair (or the nearest one within 1 cm).
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
    // Touching the edge of the 60 cm window: not one object on a table.
    for i in 0..<size where part[i] == 1 || part[(size - 1) * size + i] == 1 || part[i * size] == 1 || part[i * size + size - 1] == 1 { return nil }
    fillCellHoles(&part, size)

    // 4. The outline round the cells, in mm, centred.
    let loop = traceCells(part, size)
    if loop.count < 4 { return nil }
    let mmLoop = loop.map { P2((Double($0.x) - Double(R) - 0.5) * cellMM, (Double($0.y) - Double(R) - 0.5) * cellMM) }
    // A cell counts when any point falls in it, and the points scatter: the edge comes out about half
    // a cell plus the scatter too far out. Pull it back in.
    let smooth = insetLoop(simplifyLoop(chaikin(mmLoop), cellMM * 0.35), cellMM / 2 + min(2, scatter * 1000))
    let xs = smooth.map(\.x), ys = smooth.map(\.y)
    let x0 = xs.min() ?? 0, x1 = xs.max() ?? 0, y0 = ys.min() ?? 0, y1 = ys.max() ?? 0
    let mx = (x0 + x1) / 2, my = (y0 + y1) / 2
    var hs: [Double] = []
    for k in 0..<part.count where part[k] == 1 && hmax[k] > 0 { hs.append(hmax[k]) }
    func toWorld(_ x: Double, _ y: Double) -> V3 { aim + ux * (x / 1000) + uy * (y / 1000) + F.up * table }
    return ObjectFit(
        outline: smooth.map { P2(r1($0.x - mx), r1($0.y - my)) },
        outlineWorld: smooth.map { toWorld($0.x, $0.y) },
        width: r1(x1 - x0),
        length: r1(y1 - y0),
        height: r1(quantile(hs, 0.85) * 1000),
        midHeight: r1(median(hs) * 1000),
        centre: toWorld(mx, my),
        xAxis: ux,
        yAxis: uy,
        up: F.up,
        points: usable
    )
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
func fillCellHoles(_ m: inout [UInt8], _ size: Int) {
    var outside = [UInt8](repeating: 0, count: m.count)
    var stack: [Int] = []
    func push(_ k: Int) {
        if m[k] == 0 && outside[k] == 0 {
            outside[k] = 1
            stack.append(k)
        }
    }
    for i in 0..<size {
        push(i)
        push((size - 1) * size + i)
        push(i * size)
        push(i * size + size - 1)
    }
    while let k = stack.popLast() {
        let x = k % size, y = k / size
        if x > 0 { push(k - 1) }
        if x < size - 1 { push(k + 1) }
        if y > 0 { push(k - size) }
        if y < size - 1 { push(k + size) }
    }
    for k in 0..<m.count where outside[k] == 0 { m[k] = 1 }
}

/// The outer boundary of the cells as a loop of cell corners (corner (x, y) is the top-left of
/// cell (x, y)), walking with the cells on the right (y down).
func traceCells(_ m: [UInt8], _ size: Int) -> [(x: Int, y: Int)] {
    func on(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < size && y < size && m[y * size + x] == 1 }
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
}

/// Circle through 2D points: algebraic (Kåsa) start, then a few geometric (Gauss–Newton) steps.
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
        var m = [[Double]](repeating: [0, 0, 0], count: 3)
        var g = [0.0, 0.0, 0.0]
        for p in pts {
            let dx = p.x - mx - cu, dy = p.y - my - cv
            let d = max(1e-12, (dx * dx + dy * dy).squareRoot())
            let e = d - r
            let row = [-dx / d, -dy / d, -1.0]
            for i in 0..<3 {
                g[i] += row[i] * e
                for j in 0..<3 { m[i][j] += row[i] * row[j] }
            }
        }
        guard let step = solve3(m, g.map { -$0 }) else { break }
        cu += step[0]
        cv += step[1]
        r += step[2]
        if abs(step[0]) + abs(step[1]) + abs(step[2]) < 1e-9 { break }
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

/// A pipe, rod or hose seen from the side: the LiDAR points within `reach` of the cross-hair (and
/// joined to it), the axis direction where they fall on one circle best (tried over the half
/// sphere, then finer), and that circle's diameter. Stray points are dropped and the circle fitted again.
public func fitCylinder(_ points: [V3], aim: V3, reach: Double = 0.05) -> CylinderFit? {
    var near = connectedNear(points.filter { vlength($0 - aim) < reach }, aim: aim)
    if near.count < 60 { return nil }
    if near.count > 1500 {
        let step = Double(near.count) / 1500
        near = (0..<1500).map { near[Int(Double($0) * step)] }
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
    var best: (axis: V3, res: Double)? = nil
    let N = 500
    for i in 0..<N {
        let z = 1 - (Double(i) + 0.5) / Double(N)
        let rr = (1 - z * z).squareRoot()
        let t = Double(i) * 2.399963229728653
        let axis = V3(rr * cos(t), z, rr * sin(t))
        if let sc = score(axis, near), best == nil || sc.res < best!.res { best = (axis, sc.res) }
    }
    guard var found = best else { return nil }
    for span in [0.08, 0.02] {
        let base = found.axis
        let (p1, p2) = basis(base)
        for i in -4...4 {
            for j in -4...4 {
                let axis = vnormalized(base + p1 * (Double(i) / 4 * span) + p2 * (Double(j) / 4 * span))
                if let sc = score(axis, near), sc.res < found.res { found = (axis, sc.res) }
            }
        }
    }
    // Drop what is off the surface, fit again.
    let axis = found.axis
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
    let (e1, e2) = basis(axis)
    let centre = e1 * done.c.cx + e2 * done.c.cy + axis * vdot(aim, axis)
    return CylinderFit(diameter: r1(done.c.r * 2000), axis: axis, centre: centre, residual: r1(done.res * 1000), points: pts.count)
}

// MARK: Two surfaces

/// The surface round a point (LiDAR points within `reach`), for measuring a gap.
public func surfaceNear(_ points: [V3], at p: V3, reach: Double = 0.03) -> (plane: Plane, point: V3)? {
    let near = points.filter { vlength($0 - p) < reach }
    guard let fit = fitPlane(near, threshold: 0.004), fit.inliers >= 20 else { return nil }
    // The plane through the aimed point's foot.
    let q = p - fit.plane.normal * (vdot(fit.plane.normal, p) - fit.plane.offset)
    return (fit.plane, q)
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
/// table-level and the top-level outline land), take the strongest brightness step, and lay it back
/// on the table – at table level where the side faces the camera (its bottom edge is what shows),
/// at the top where it faces away. Points without a clear step keep the LiDAR edge (a running
/// median along the loop smooths single wrong steps). Nil when too little of the edge was found.
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
        var bestS = Double.nan
        var bestG = 0.0
        if vals.count >= 3 {
            for k in 1..<(vals.count - 1) {
                let grad = abs(vals[k + 1] - vals[k - 1]) / (2 * step)
                if grad.isFinite && grad > bestG {
                    bestG = grad
                    // Parabola through the neighbouring gradients for a sub-pixel peak.
                    let gm = k >= 2 ? abs(vals[k] - vals[k - 2]) / (2 * step) : grad
                    let gp = k + 2 < vals.count ? abs(vals[k + 2] - vals[k]) / (2 * step) : grad
                    let den = gm - 2 * grad + gp
                    let off = abs(den) > 1e-9 ? max(-0.5, min(0.5, 0.5 * (gm - gp) / den)) : 0
                    bestS = s0 + (Double(k) + off) * step
                }
            }
        }
        if !(bestG >= 6) || !bestS.isFinite { continue }
        let pix = (i0 + u * bestS) * scale
        // Which edge the picture shows: a side facing the camera is seen down to the table (the bottom
        // edge), a side facing away only to its top edge.
        let at = toWorld(p.x, p.y)
        let nWorld = fit.xAxis * nrm.x + fit.yAxis * nrm.y
        let level = vdot(nWorld, pose.position - at) > 0 ? 0 : H
        guard let w = rayToLevel(pix.x, pix.y, intrinsics: K, pose: pose, base: fit.centre, up: fit.up, h: level) else { continue }
        let d = w - fit.centre
        let shift = (vdot(d, fit.xAxis) * 1000 - p.x) * nrm.x + (vdot(d, fit.yAxis) * 1000 - p.y) * nrm.y
        if abs(shift) <= 4 { shifts[i] = shift }
    }
    let found = shifts.compactMap { $0 }.count
    if Double(found) < Double(n) * 0.6 { return nil }
    let moved: [P2] = (0..<n).map { i in
        var win: [Double] = []
        for k in -3...3 { if let v = shifts[(i + k + n) % n] { win.append(v) } }
        return even[i] + outward[i] * (win.isEmpty ? 0 : median(win))
    }
    let out = simplifyLoop(moved, 0.25)
    let xs = out.map(\.x), ys = out.map(\.y)
    let x0 = xs.min() ?? 0, x1 = xs.max() ?? 0, y0 = ys.min() ?? 0, y1 = ys.max() ?? 0
    let mx = (x0 + x1) / 2, my = (y0 + y1) / 2
    var r = fit
    r.outline = out.map { P2(r1($0.x - mx), r1($0.y - my)) }
    r.outlineWorld = out.map { toWorld($0.x, $0.y) }
    r.width = r1(x1 - x0)
    r.length = r1(y1 - y0)
    r.centre = toWorld(mx, my)
    r.sharpened = true
    return r
}

@inline(__always) func vdot2(_ a: P2, _ b: P2) -> Double { a.x * b.x + a.y * b.y }
