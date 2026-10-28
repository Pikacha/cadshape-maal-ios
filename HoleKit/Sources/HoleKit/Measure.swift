import Foundation

/// LiDAR depth for the camera picture: z distance in metres (row by row), covering the same view as the picture.
public struct DepthMap {
    public let width: Int
    public let height: Int
    public var depth: [Float]
    /// 0 = low, 1 = medium, 2 = high confidence (ARKit). Nil = all usable.
    public var confidence: [UInt8]?

    public init(width: Int, height: Int, depth: [Float], confidence: [UInt8]?) {
        precondition(depth.count == width * height, "depth count")
        self.width = width
        self.height = height
        self.depth = depth
        self.confidence = confidence
    }

    func valid(_ k: Int) -> Bool {
        let z = depth[k]
        return z.isFinite && z > 0.05 && z < 10
    }
}

/// What one camera frame gives.
public struct FrameInput {
    /// The camera picture, scaled down by `scale`.
    public var gray: GrayImage
    /// Full-picture pixels per pixel of `gray`.
    public var scale: Double
    /// Of the full picture.
    public var intrinsics: Intrinsics
    public var depth: DepthMap?
    /// The surface from ARKit (raycast) when there is no LiDAR.
    public var fallbackPlane: Plane?
    /// Where to look for the hole (coordinates in `gray`).
    public var seed: P2
    /// Only a fallback: averaged depth can lag the current camera picture.
    public var usedSmoothedDepth: Bool

    public init(gray: GrayImage, scale: Double, intrinsics: Intrinsics, depth: DepthMap?, fallbackPlane: Plane?, seed: P2, usedSmoothedDepth: Bool = false) {
        self.gray = gray
        self.scale = scale
        self.intrinsics = intrinsics
        self.depth = depth
        self.fallbackPlane = fallbackPlane
        self.seed = seed
        self.usedSmoothedDepth = usedSmoothedDepth
    }
}

/// How the hole's edge was found.
public enum HoleSource: String {
    /// Brightness edge in the picture (sharpest).
    case picture
    /// Depth jump in the LiDAR map (when the hole does not stand out in the picture).
    case depth
}

public struct FrameMeasurement {
    /// Hole outline in `gray` coordinates (thinned out, for drawing).
    public var outline: [P2]
    /// The hole on the wall/ceiling, mm, as seen from the camera (x right, y up), centred.
    public var outlineMM: [P2]
    public var plane: Plane
    /// LiDAR points the surface rests on (0 = surface from ARKit raycast).
    public var planePoints: Int
    /// Middle of the hole in `gray` coordinates.
    public var centroid: P2
    /// √area of the hole (mm).
    public var sizeMM: Double
    /// Width and height of the hole on the surface (mm, camera's right and up).
    public var widthMM: Double
    public var heightMM: Double
    public var source: HoleSource
    /// Middle of the hole on the surface, camera coordinates (m, x right, y down, z forward).
    public var centre: V3 = V3(0, 0, 0)
    /// How deep the hole is behind the surface (mm, from LiDAR), when it has a bottom the LiDAR sees.
    public var depthMM: Double?
    /// Millimetres across one analysis pixel at the detected edge, including perspective.
    public var edgeResolutionMM = 0.0
    public var edgePixels = 0.0
    public var planeResidualMM = 0.0
    public var planeInlierRatio = 0.0
    public var usedSmoothedDepth = false
    /// A second clear edge round the hole (shadow, chamfer, ring): the hole measured there instead.
    public var edgeAlternative: EdgeAlternative?
    /// The phone's hole calibration was applied to the sizes and outlines.
    public var calibrated = false
}

/// The hole measured at the other of two clear edges (see EdgeProfile).
public struct EdgeAlternative {
    public var outlineMM: [P2]
    public var sizeMM: Double
    public var widthMM: Double
    public var heightMM: Double
    /// The other edge lies inside the found one (the found edge may include a ring round the hole).
    public var inward: Bool
    /// Share of the brightness step at the other edge (0…1).
    public var share: Double

    public init(outlineMM: [P2], sizeMM: Double, widthMM: Double, heightMM: Double, inward: Bool, share: Double) {
        self.outlineMM = outlineMM
        self.sizeMM = sizeMM
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.inward = inward
        self.share = share
    }
}

public enum MeasureFailure: Error {
    case noHole
    case noSurface
}

/// Hole outline from the picture (or the LiDAR depth), the surface around it from LiDAR, and the
/// outline laid onto that surface in mm.
public func measureFrame(_ input: FrameInput) -> Result<FrameMeasurement, MeasureFailure> {
    let g = input.gray.blurred()
    let K = input.intrinsics
    let s = input.scale

    if let hole = findHole(g, seed: input.seed) {
        var plane: Plane? = nil
        var used = 0
        var residualMM = 0.0, inlierRatio = 0.0
        if let dm = input.depth, let fit = surfaceAround(hole, gray: g, depth: dm, intrinsics: K, scale: s) {
            plane = fit.plane
            used = fit.inliers
            residualMM = fit.residualMM
            inlierRatio = fit.ratio
        }
        if plane == nil { plane = input.fallbackPlane }
        guard let surface = plane else { return .failure(.noSurface) }
        let full = hole.outline.map { $0 * s }
        guard let m = layOnto(full, surface, K) else { return .failure(.noSurface) }
        var r = result(outlineGray: hole.outline, mm: m, plane: surface, used: used, source: .picture)
        r.edgeResolutionMM = edgeResolution(full, plane: surface, intrinsics: K, dx: s, dy: s)
        guard r.edgeResolutionMM.isFinite && r.edgeResolutionMM > 0 else { return .failure(.noSurface) }
        r.edgePixels = Double(min(hole.maxX - hole.minX + 1, hole.maxY - hole.minY + 1))
        r.planeResidualMM = residualMM
        r.planeInlierRatio = inlierRatio
        r.usedSmoothedDepth = input.usedSmoothedDepth
        r.centre = centreOn(full, surface, K) ?? r.centre
        if let dm = input.depth { r.depthMM = depthInside(hole, gray: g, depth: dm, plane: surface, intrinsics: K, scale: s) }
        if let prof = edgeProfile(g, outline: hole.outline), let off = prof.altOffset {
            let altGray = shiftOutline(hole.outline, normals: prof.normals, offset: off)
            if let altMM = layOnto(altGray.map { $0 * s }, surface, K) {
                let a = result(outlineGray: altGray, mm: altMM, plane: surface, used: used, source: .picture)
                r.edgeAlternative = EdgeAlternative(outlineMM: a.outlineMM, sizeMM: a.sizeMM, widthMM: a.widthMM, heightMM: a.heightMM, inward: off < 0, share: prof.altShare)
            }
        }
        return .success(r)
    }

    // Nothing in the picture: try the depth (a hole that is as light as the wall, but deep).
    guard let dm = input.depth else { return .failure(.noHole) }
    let sx = Double(g.width) * s / Double(dm.width)
    let sy = Double(g.height) * s / Double(dm.height)
    let seed = P2(input.seed.x * s / sx, input.seed.y * s / sy)
    guard let dh = depthHole(dm, intrinsics: K, sx: sx, sy: sy, seed: seed) else { return .failure(.noHole) }
    let full = dh.outline.map { P2($0.x * sx, $0.y * sy) }
    guard let m = layOnto(full, dh.plane, K) else { return .failure(.noSurface) }
    var r = result(outlineGray: full.map { $0 / s }, mm: m, plane: dh.plane, used: dh.inliers, source: .depth)
    r.edgeResolutionMM = edgeResolution(full, plane: dh.plane, intrinsics: K, dx: sx, dy: sy)
    guard r.edgeResolutionMM.isFinite && r.edgeResolutionMM > 0 else { return .failure(.noSurface) }
    let xs = dh.outline.map(\.x), ys = dh.outline.map(\.y)
    r.edgePixels = min((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
    r.planeResidualMM = dh.residualMM
    r.planeInlierRatio = dh.ratio
    r.usedSmoothedDepth = input.usedSmoothedDepth
    r.centre = centreOn(full, dh.plane, K) ?? r.centre
    r.depthMM = dh.depthMM
    return .success(r)
}

/// Pixel footprint on the measured plane; interpolating an edge does not remove this resolution limit.
func edgeResolution(_ outline: [P2], plane: Plane, intrinsics K: Intrinsics, dx: Double, dy: Double) -> Double {
    var largest = 0.0
    for i in stride(from: 0, to: outline.count, by: max(1, outline.count / 32)) {
        let p = outline[i]
        guard let a = plane.hit(K.ray(p.x, p.y)),
              let x = plane.hit(K.ray(p.x + dx, p.y)),
              let y = plane.hit(K.ray(p.x, p.y + dy)) else { return .infinity }
        largest = max(largest, max(vlength(x - a), vlength(y - a)) * 1000)
    }
    return largest
}

func surfaceResidualMM(_ points: [V3], plane: Plane, threshold: Double) -> Double {
    let residuals = points.map { abs(vdot(plane.normal, $0) - plane.offset) }.filter { $0 < threshold }
    return (residuals.reduce(0) { $0 + $1 * $1 } / Double(max(1, residuals.count))).squareRoot() * 1000
}

/// The middle of an outline (full-picture pixels) on the surface, camera coordinates (m).
func centreOn(_ outline: [P2], _ plane: Plane, _ K: Intrinsics) -> V3? {
    var sum = V3(0, 0, 0)
    var n = 0
    for p in outline {
        guard let hit = plane.hit(K.ray(p.x, p.y)) else { return nil }
        sum += hit
        n += 1
    }
    return n > 0 ? sum / Double(n) : nil
}

/// Holes deeper than this are taken as going through (the LiDAR sees the room behind).
let maxDepthMM = 250.0

/**
 * How deep a hole is: the median of how far the LiDAR depth inside the hole (away from its edge,
 * where depth mixes) lies behind the surface, measured straight out from the surface (mm).
 * Nil when the inside has too little depth (open cavity, dark or glossy bottom) or is very deep.
 */
func depthInside(_ hole: Hole, gray g: GrayImage, depth dm: DepthMap, plane: Plane, intrinsics K: Intrinsics, scale s: Double) -> Double? {
    let w = g.width
    let h = g.height
    let sx = Double(w) / Double(dm.width)
    let sy = Double(h) / Double(dm.height)
    let margin = Int(max(2, 1.5 * max(sx, sy)))
    func deepInside(_ x: Int, _ y: Int) -> Bool {
        for (dx, dy) in [(0, 0), (-margin, 0), (margin, 0), (0, -margin), (0, margin)] {
            let xx = x + dx, yy = y + dy
            if xx < 0 || yy < 0 || xx >= w || yy >= h || hole.mask[yy * w + xx] == 0 { return false }
        }
        return true
    }
    var gaps: [Double] = []
    let jy0 = max(0, Int(Double(hole.minY) / sy)), jy1 = min(dm.height - 1, Int(Double(hole.maxY) / sy) + 1)
    let ix0 = max(0, Int(Double(hole.minX) / sx)), ix1 = min(dm.width - 1, Int(Double(hole.maxX) / sx) + 1)
    if jy0 > jy1 || ix0 > ix1 { return nil }
    for j in jy0...jy1 {
        for i in ix0...ix1 {
            let gx = (Double(i) + 0.5) * sx, gy = (Double(j) + 0.5) * sy
            if !deepInside(Int(gx), Int(gy)) { continue }
            let k = j * dm.width + i
            if !dm.valid(k) || (dm.confidence?[k] ?? 2) == 0 { continue }
            let ray = K.ray(gx * s, gy * s)
            let d = vdot(plane.normal, ray)
            if d <= 1e-9 { continue }
            let gap = Double(dm.depth[k]) - plane.offset / d
            if gap > 0.003 { gaps.append(gap) }
        }
    }
    if gaps.count < 4 { return nil }
    gaps.sort()
    let mm = gaps[gaps.count / 2] * abs(plane.normal.z) * 1000
    return mm < maxDepthMM ? mm : nil
}

/// The outline (full-picture pixels) laid onto the surface, in plane millimetres.
func layOnto(_ outline: [P2], _ plane: Plane, _ K: Intrinsics) -> [P2]? {
    let frame = PlaneFrame(plane)
    var mm: [P2] = []
    mm.reserveCapacity(outline.count)
    for p in outline {
        guard let hit = plane.hit(K.ray(p.x, p.y)) else { return nil }
        mm.append(frame.mm(hit))
    }
    return mm
}

func result(outlineGray: [P2], mm: [P2], plane: Plane, used: Int, source: HoleSource) -> FrameMeasurement {
    var c = P2(0, 0)
    for p in mm { c += p }
    c /= Double(max(1, mm.count))
    let centred = mm.map { $0 - c }
    var lo = P2(.infinity, .infinity), hi = P2(-.infinity, -.infinity)
    for p in centred {
        lo = P2(min(lo.x, p.x), min(lo.y, p.y))
        hi = P2(max(hi.x, p.x), max(hi.y, p.y))
    }
    var gc = P2(0, 0)
    for p in outlineGray { gc += p }
    gc /= Double(max(1, outlineGray.count))
    let thin = stride(from: 0, to: outlineGray.count, by: max(1, outlineGray.count / 400)).map { outlineGray[$0] }
    let thinMM = stride(from: 0, to: centred.count, by: max(1, centred.count / 1500)).map { centred[$0] }
    return FrameMeasurement(
        outline: thin, outlineMM: thinMM, plane: plane, planePoints: used, centroid: gc,
        sizeMM: abs(polygonArea(centred)).squareRoot(), widthMM: hi.x - lo.x, heightMM: hi.y - lo.y, source: source
    )
}

/// The wall/ceiling around a hole: LiDAR points in a band around it (not in it – there the depth is
/// the hole's inside, and right at the edge the depth mixes the two).
func surfaceAround(_ hole: Hole, gray g: GrayImage, depth dm: DepthMap, intrinsics K: Intrinsics, scale s: Double) -> (plane: Plane, inliers: Int, residualMM: Double, ratio: Double)? {
    let w = g.width
    let h = g.height
    let bw = Double(hole.maxX - hole.minX + 1)
    let bh = Double(hole.maxY - hole.minY + 1)
    let rx0 = Double(hole.minX) - bw, rx1 = Double(hole.maxX) + bw
    let ry0 = Double(hole.minY) - bh, ry1 = Double(hole.maxY) + bh
    let sx = Double(w) / Double(dm.width)
    let sy = Double(h) / Double(dm.height)
    let margin = Int(max(3, 1.5 * max(sx, sy)))
    func nearHole(_ x: Int, _ y: Int) -> Bool {
        for (dx, dy) in [(0, 0), (-margin, 0), (margin, 0), (0, -margin), (0, margin)] {
            let xx = x + dx, yy = y + dy
            if xx >= 0 && yy >= 0 && xx < w && yy < h && hole.mask[yy * w + xx] == 1 { return true }
        }
        return false
    }
    var high: [V3] = []
    var medium: [V3] = []
    for j in 0..<dm.height {
        let gy = (Double(j) + 0.5) * sy
        if gy < ry0 || gy > ry1 { continue }
        for i in 0..<dm.width {
            let gx = (Double(i) + 0.5) * sx
            if gx < rx0 || gx > rx1 { continue }
            let k = j * dm.width + i
            if !dm.valid(k) { continue }
            let c = dm.confidence?[k] ?? 2
            if c == 0 { continue }
            if nearHole(Int(gx), Int(gy)) { continue }
            let p = K.ray(gx * s, gy * s) * Double(dm.depth[k])
            if c >= 2 { high.append(p) } else { medium.append(p) }
        }
    }
    let pts = high.count >= 60 ? high : high + medium
    guard let fit = fitPlane(pts), fit.inliers >= 20 else { return nil }
    return (fit.plane, fit.inliers, surfaceResidualMM(pts, plane: fit.plane, threshold: 0.008), Double(fit.inliers) / Double(pts.count))
}

/// The hole from LiDAR alone: the patch around the aimed point that lies clearly behind the
/// surface around it (or has no depth at all – an open hole into a dark cavity).
/// Works in depth-map pixels; `sx`, `sy` = full-picture pixels per depth pixel.
func depthHole(_ dm: DepthMap, intrinsics K: Intrinsics, sx: Double, sy: Double, seed: P2) -> (outline: [P2], plane: Plane, inliers: Int, depthMM: Double?, residualMM: Double, ratio: Double)? {
    let w = dm.width
    let h = dm.height
    let si = Int(seed.x), sj = Int(seed.y)
    if si < 1 || sj < 1 || si >= w - 1 || sj >= h - 1 { return nil }
    let r = Int(Double(h) * 0.35)
    let i0 = max(0, si - r), i1 = min(w - 1, si + r)
    let j0 = max(0, sj - r), j1 = min(h - 1, sj + r)
    func ray(_ i: Int, _ j: Int) -> V3 { K.ray((Double(i) + 0.5) * sx, (Double(j) + 0.5) * sy) }

    var pts: [V3] = []
    for j in j0...j1 {
        for i in i0...i1 {
            let k = j * w + i
            if !dm.valid(k) || (dm.confidence?[k] ?? 2) == 0 { continue }
            pts.append(ray(i, j) * Double(dm.depth[k]))
        }
    }
    guard let fit = fitPlane(pts, threshold: 0.012), fit.inliers >= 40 else { return nil }
    let plane = fit.plane

    // How far behind the surface each depth pixel is (m); nil = no depth there.
    func gap(_ i: Int, _ j: Int) -> Double? {
        let k = j * w + i
        if !dm.valid(k) { return nil }
        let d = vdot(plane.normal, ray(i, j))
        if d <= 1e-9 { return nil }
        return Double(dm.depth[k]) - plane.offset / d
    }
    let zs = plane.offset / max(1e-9, vdot(plane.normal, ray(si, sj)))
    let thr = max(0.015, 0.012 * zs)
    func behind(_ i: Int, _ j: Int) -> Bool {
        guard let gp = gap(i, j) else { return true }
        return gp > thr
    }
    if !behind(si, sj) { return nil }

    var region = [UInt8](repeating: 0, count: w * h)
    var stack = [si + sj * w]
    region[si + sj * w] = 1
    var count = 0
    var deep: [Double] = []
    while let k = stack.popLast() {
        let i = k % w, j = k / w
        if i <= i0 || i >= i1 || j <= j0 || j >= j1 { return nil }
        count += 1
        if let gp = gap(i, j) { deep.append(gp) }
        for q in [k - 1, k + 1, k - w, k + w] where region[q] == 0 && behind(q % w, q / w) {
            region[q] = 1
            stack.append(q)
        }
    }
    if count < 6 || count > w * h / 4 { return nil }
    // The edge: halfway between the surface and the hole's inside (the depth map is soft there).
    deep.sort()
    let inside = deep.isEmpty ? 3 * thr : deep[deep.count / 2]
    let level = max(thr, inside / 2)
    var first = -1
    for k in 0..<(w * h) where region[k] == 1 { first = k; break }
    if first < 0 { return nil }
    let outline = traceOutline(width: w, height: h, start: first, isIn: { x, y in
        x >= 0 && y >= 0 && x < w && y < h && region[y * w + x] == 1
    }, level: { ix, iy, ox, oy in
        if ox < 0 || oy < 0 || ox >= w || oy >= h { return 0.5 }
        let a = gap(ix, iy) ?? inside
        guard let b = gap(ox, oy) else { return 0.5 }
        return a == b ? 0.5 : (a - level) / (a - b)
    })
    if outline.count < 8 { return nil }
    let depthMM = deep.isEmpty ? nil : inside * abs(plane.normal.z) * 1000
    return (outline, plane, fit.inliers, depthMM.flatMap { $0 < maxDepthMM ? $0 : nil },
        surfaceResidualMM(pts, plane: plane, threshold: 0.012), Double(fit.inliers) / Double(pts.count))
}
