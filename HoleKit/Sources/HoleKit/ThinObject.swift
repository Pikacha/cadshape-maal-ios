import Foundation

// Thin things on a table – a spanner, a ruler, a flat tool under ~8 mm – stand too little above the
// table for the LiDAR to tell them from it (its noise is a few mm). Their outline comes from a
// foreground mask of the camera picture instead (e.g. Vision's subject mask), laid onto the table
// that the LiDAR does see.

/// One decimal (mm).
private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

/// Whether a point lies inside a closed loop (even–odd rule).
func insideLoop(_ p: P2, _ loop: [P2]) -> Bool {
    var inside = false
    var j = loop.count - 1
    for i in 0..<loop.count {
        let a = loop[i], b = loop[j]
        if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        j = i
    }
    return inside
}

/// A thin thing lying on a table, from a foreground mask (non-zero = the thing, `width` × `height`
/// mask pixels, row by row). `aim` is the cross-hair in mask pixels, `maskToImage` the full-picture
/// pixels per mask pixel (`K` is for the full picture), `points` the LiDAR cloud (world) and
/// `aimWorld` the LiDAR point under the cross-hair. The result has the conventions of `fitObject`;
/// its height is the LiDAR's (at least 1 mm). Nil when the mask part is tiny, runs off the picture
/// on most sides, there is no table, or the footprint is not between 5 and 600 mm long.
public func objectFromMask(_ mask: [UInt8], width: Int, height: Int, aim: P2, maskToImage: Double,
                           intrinsics K: Intrinsics, pose: CameraPose, points: [V3], aimWorld: V3,
                           up: V3 = V3(0, 1, 0), right: V3? = nil) -> ObjectFit? {
    guard width > 2, height > 2, mask.count == width * height, maskToImage > 0, maskToImage.isFinite,
          aim.x.isFinite, aim.y.isFinite else { return nil }

    // 1. The table, as `fitObject` finds it – but the cross-hair may be on the table itself or on a
    //    thing a few mm high, so levels up to 1 cm above it count too.
    let F = flatFrame(up)
    let ux = flatRight(F, right)
    let uy = vcross(F.up, ux)
    let n = points.count
    var X = [Double](repeating: 0, count: n)
    var Y = [Double](repeating: 0, count: n)
    var H = [Double](repeating: 0, count: n)
    var usable = 0
    for i in 0..<n {
        let d = points[i] - aimWorld
        X[i] = vdot(d, ux)
        Y[i] = vdot(d, uy)
        H[i] = vdot(d, F.up)
        if X[i] * X[i] + Y[i] * Y[i] < 0.35 * 0.35 { usable += 1 }
    }
    if usable < 100 { return nil }
    guard let level = tableLevel(X, Y, H, limit: 0.01) else { return nil }
    // A point on the table straight under (or over) the cross-hair's LiDAR point.
    let base = aimWorld + F.up * level.height
    for i in 0..<n { H[i] -= level.height }

    // 2. The part of the mask under the cross-hair, or the nearest one within 5 % of the picture.
    let reach = max(2, Int((0.05 * Double(max(width, height))).rounded()))
    if aim.x < -Double(reach) || aim.y < -Double(reach) || aim.x > Double(width + reach) || aim.y > Double(height + reach) { return nil }
    let ai = min(width - 1, max(0, Int(aim.x.rounded(.down))))
    let aj = min(height - 1, max(0, Int(aim.y.rounded(.down))))
    var start = -1
    if mask[aj * width + ai] != 0 {
        start = aj * width + ai
    } else {
        var bestD = Int.max
        for j in max(0, aj - reach)...min(height - 1, aj + reach) {
            for i in max(0, ai - reach)...min(width - 1, ai + reach) where mask[j * width + i] != 0 {
                let d = (i - ai) * (i - ai) + (j - aj) * (j - aj)
                if d <= reach * reach && d < bestD {
                    bestD = d
                    start = j * width + i
                }
            }
        }
    }
    if start < 0 { return nil }
    var part = [UInt8](repeating: 0, count: mask.count)
    var stack = [start]
    part[start] = 1
    var cells = 0
    // Which picture borders it runs off: left, right, top, bottom.
    var touches = [false, false, false, false]
    let steps = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    while let k = stack.popLast() {
        cells += 1
        let x = k % width, y = k / width
        if x == 0 { touches[0] = true }
        if x == width - 1 { touches[1] = true }
        if y == 0 { touches[2] = true }
        if y == height - 1 { touches[3] = true }
        for (dx, dy) in steps {
            let nx = x + dx, ny = y + dy
            if nx < 0 || ny < 0 || nx >= width || ny >= height { continue }
            let j = ny * width + nx
            if mask[j] != 0 && part[j] == 0 {
                part[j] = 1
                stack.append(j)
            }
        }
    }
    // A speck, the table itself (a mask gone wrong) or something only partly in view.
    if cells < 40 || Double(cells) > 0.5 * Double(mask.count) { return nil }
    if touches.filter({ $0 }).count >= 3 { return nil }
    fillCellHoles(&part, width: width, height: height)

    // 3. Its outline (mask pixel corners, the steps smoothed), laid onto the table along each
    //    pixel's ray: mm in the table's x (camera right) / y (away) frame round `base`.
    let corners = traceCells(part, width: width, height: height)
    if corners.count < 4 { return nil }
    let loopPx = simplifyLoop(chaikin(corners.map { P2(Double($0.x), Double($0.y)) }), 0.2)
    func onTable(_ q: P2, _ h: Double) -> P2? {
        guard let w = rayToLevel(q.x * maskToImage, q.y * maskToImage, intrinsics: K, pose: pose, base: base, up: F.up, h: h) else { return nil }
        let d = w - base
        // Straight down onto the table.
        return P2(vdot(d, ux) * 1000, vdot(d, uy) * 1000)
    }
    var px: [P2] = []
    var foot: [P2] = []
    for q in loopPx {
        if let t = onTable(q, 0) {
            px.append(q)
            foot.append(t)
        }
    }
    if foot.count < 4 || Double(foot.count) < 0.9 * Double(loopPx.count) { return nil }

    // 4. How high it stands: the LiDAR points over the footprint (they barely rise above the
    //    table's noise, but their middle does).
    let xs = foot.map(\.x), ys = foot.map(\.y)
    let x0 = (xs.min() ?? 0) / 1000, x1 = (xs.max() ?? 0) / 1000
    let y0 = (ys.min() ?? 0) / 1000, y1 = (ys.max() ?? 0) / 1000
    var hs: [Double] = []
    for i in 0..<n where H[i] > -0.01 && H[i] < 0.05 && X[i] >= x0 && X[i] <= x1 && Y[i] >= y0 && Y[i] <= y1 {
        if insideLoop(P2(X[i] * 1000, Y[i] * 1000), foot) { hs.append(H[i]) }
    }
    let h = max(0.001, hs.count >= 5 ? median(hs) : 0)

    // 5. Where a side faces away from the camera, the picture shows its top edge, which the ray
    //    meets `h` above the table – nearer the thing than at table level.
    if h > 0.0015 {
        let m = foot.count
        var area = 0.0
        for i in 0..<m {
            let p = foot[i], q = foot[(i + 1) % m]
            area += p.x * q.y - q.x * p.y
        }
        let ccw = area > 0 ? 1.0 : -1.0
        let flat = foot
        for i in 0..<m {
            let e = flat[(i + 1) % m] - flat[(i - 1 + m) % m]
            let l = vlen2(e)
            if l < 1e-9 { continue }
            // Outward: right of the direction of travel on an anticlockwise loop.
            let out = P2(e.y, -e.x) / l * ccw
            let at = base + ux * (flat[i].x / 1000) + uy * (flat[i].y / 1000)
            let outWorld = ux * out.x + uy * out.y
            if vdot(outWorld, pose.position - at) <= 0, let top = onTable(px[i], h) { foot[i] = top }
        }
    }
    foot = simplifyLoop(foot, 0.25)

    // 6. Its size and frame as `fitObject` gives them.
    guard let sq = squareUp(foot, points: []), sq.width >= 5, sq.width <= 600 else { return nil }
    func toWorld(_ p: P2) -> V3 { base + ux * (p.x / 1000) + uy * (p.y / 1000) }
    return ObjectFit(
        outline: sq.outline,
        outlineWorld: foot.map { toWorld($0) },
        width: sq.width,
        length: sq.length,
        height: round1(h * 1000),
        midHeight: round1(h * 1000),
        centre: toWorld(sq.mid),
        xAxis: ux * sq.dir.x + uy * sq.dir.y,
        yAxis: ux * (-sq.dir.y) + uy * sq.dir.x,
        up: F.up,
        points: usable
    )
}
