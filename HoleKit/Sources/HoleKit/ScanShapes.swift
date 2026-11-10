import Foundation

// «Finn målene» on the phone: the 3D scan (Object Capture, Z up, mm) cut into thin slices; each
// slice is a circle, a (rounded) rectangle or a free outline; slices that agree become one part.
// A pill bottle → «Sylinder Ø38,8 × 17,5 · Sylinder Ø37,4 × 59». The same rules as CadSHAPE's
// src/core/scanshapes.ts (upright stack only – CadSHAPE also tries lying down). Change both.
// Last, shared rules (`sharedRules`): parts that measure the same within their noise get one value.

public enum ScanPartKind: String {
    case cylinder, cone, box, profile
}

public struct ScanPart {
    public var kind: ScanPartKind
    /// Bottom and top along Z (mm).
    public var z0: Double
    public var z1: Double
    /// Cylinder: diameter. Cone: bottom diameter.
    public var d: Double = 0
    /// Cone: top diameter.
    public var dTop: Double = 0
    /// Cylinder with a round hole (a tube).
    public var inner: Double?
    /// Box: long and short side, angle of the long side (degrees) and corner radius.
    public var w: Double = 0
    public var l: Double = 0
    public var angle: Double = 0
    public var corner: Double = 0
    /// Free outline: how many corners.
    public var points: Int = 0
    public var centre = P2(0, 0)
    /// How much the slices of this part disagree with its measures (mm, RMS) – green below 0,5.
    /// After a shared rule: the ± of the shared value (smaller, the parts measured it together).
    public var spread: Double = 0
    /// Shared rules that set a measure together with other parts, e.g. «lik diameter som del 3»
    /// (parts counted from the bottom, 1 first). Empty: the part's own measures.
    public var rules: [String] = []

    public var height: Double { z1 - z0 }

    /// «Sylinder Ø37,4 × 59» – the same words as CadSHAPE (partText).
    public var text: String {
        let h = shortMM(height)
        switch kind {
        case .cylinder:
            if let i = inner { return "Rør Ø\(shortMM(d))/Ø\(shortMM(i)) × \(h)" }
            return "Sylinder Ø\(shortMM(d)) × \(h)"
        case .cone: return "Kjegle Ø\(shortMM(d)) → Ø\(shortMM(dTop)) × \(h)"
        case .box: return "Kloss \(shortMM(w)) × \(shortMM(l)) × \(h)" + (corner > 0 ? " (hjørner R\(shortMM(corner)))" : "")
        case .profile: return "Profil \(points) punkter × \(h)"
        }
    }
}

public struct ScanShapes {
    /// Bottom first.
    public var parts: [ScanPart]
    public var height: Double
    /// Share of the height that became cylinders, cones or boxes.
    public var explained: Double

    /// Top first, one line per part.
    public var lines: [String] { parts.reversed().map(\.text) }
}

/// Up to one decimal, Norwegian comma, no «,0».
public func shortMM(_ v: Double) -> String {
    let r = (v * 10).rounded() / 10
    if r == r.rounded() { return String(Int(r)) }
    return String(format: "%.1f", r).replacingOccurrences(of: ".", with: ",")
}

private enum SliceKind { case circle, rect, free }

private struct Slice {
    var z: Double
    var kind: SliceKind
    var area: Double
    var centroid: P2
    var d: Double
    var c: P2
    var w: Double
    var l: Double
    var angle: Double
    var corner: Double
    var inner: Double?
    var corners: Int
    /// Taken over from a short neighbour: widens the height, not the measures.
    var ghost = false
}

private func polyArea(_ p: [P2]) -> Double {
    var a = 0.0
    for i in 0..<p.count {
        let q = p[(i + 1) % p.count]
        a += p[i].x * q.y - q.x * p[i].y
    }
    return a / 2
}

private func polyCentroid(_ p: [P2]) -> P2 {
    var a = 0.0, cx = 0.0, cy = 0.0
    for i in 0..<p.count {
        let q = p[(i + 1) % p.count]
        let c = p[i].x * q.y - q.x * p[i].y
        a += c
        cx += (p[i].x + q.x) * c
        cy += (p[i].y + q.y) * c
    }
    return a != 0 ? P2(cx / (3 * a), cy / (3 * a)) : p[0]
}

/// The loop with `n` evenly spaced points.
func resampleLoop(_ loop: [P2], _ n: Int) -> [P2] {
    var len = [0.0]
    for i in 0..<loop.count {
        let q = loop[(i + 1) % loop.count]
        len.append(len[i] + ((q.x - loop[i].x) * (q.x - loop[i].x) + (q.y - loop[i].y) * (q.y - loop[i].y)).squareRoot())
    }
    let total = len[loop.count]
    if !(total > 0) { return loop }
    var out: [P2] = []
    out.reserveCapacity(n)
    var j = 0
    for k in 0..<n {
        let s = total * Double(k) / Double(n)
        while j < loop.count - 1 && len[j + 1] < s { j += 1 }
        let p = loop[j], q = loop[(j + 1) % loop.count]
        let seg = len[j + 1] - len[j]
        let t = seg > 0 ? (s - len[j]) / seg : 0
        out.append(p + (q - p) * t)
    }
    return out
}

private func hullOf(_ pts: [P2]) -> [P2] {
    let p = pts.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
    if p.count < 3 { return p }
    func cross(_ o: P2, _ a: P2, _ b: P2) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
    var lo: [P2] = []
    for q in p {
        while lo.count >= 2 && cross(lo[lo.count - 2], lo[lo.count - 1], q) <= 0 { lo.removeLast() }
        lo.append(q)
    }
    var up: [P2] = []
    for q in p.reversed() {
        while up.count >= 2 && cross(up[up.count - 2], up[up.count - 1], q) <= 0 { up.removeLast() }
        up.append(q)
    }
    return Array(lo.dropLast()) + Array(up.dropLast())
}

/// Smallest rectangle round the points: centre, sides (w ≥ l), angle of the long side (−90…90°).
public func minRect(_ pts: [P2]) -> (centre: P2, w: Double, l: Double, angle: Double) {
    let h = hullOf(pts)
    var best = (area: Double.infinity, centre: P2(0, 0), w: 0.0, l: 0.0, angle: 0.0)
    for i in 0..<h.count {
        let a = h[i], b = h[(i + 1) % h.count]
        let ang = atan2(b.y - a.y, b.x - a.x)
        let cs = cos(ang), sn = sin(ang)
        var u0 = Double.infinity, u1 = -Double.infinity, v0 = Double.infinity, v1 = -Double.infinity
        for q in h {
            let u = q.x * cs + q.y * sn
            let v = -q.x * sn + q.y * cs
            u0 = min(u0, u); u1 = max(u1, u)
            v0 = min(v0, v); v1 = max(v1, v)
        }
        let area = (u1 - u0) * (v1 - v0)
        if area < best.area - 1e-9 {
            let uc = (u0 + u1) / 2, vc = (v0 + v1) / 2
            var w = u1 - u0, l = v1 - v0
            var deg = ang * 180 / .pi
            if l > w { swap(&w, &l); deg += 90 }
            while deg > 90 { deg -= 180 }
            while deg <= -90 { deg += 180 }
            best = (area, P2(uc * cs - vc * sn, uc * sn + vc * cs), w, l, deg)
        }
    }
    return (best.centre, best.w, best.l, best.angle)
}

private func roundRectDist(_ p: P2, _ c: P2, _ w: Double, _ l: Double, _ angle: Double, _ r: Double) -> Double {
    let a = angle * .pi / 180
    let dx = p.x - c.x, dy = p.y - c.y
    let u = abs(dx * cos(a) + dy * sin(a))
    let v = abs(-dx * sin(a) + dy * cos(a))
    let qx = u - (w / 2 - r), qy = v - (l / 2 - r)
    let outside = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot()
    let inside = min(max(qx, qy), 0)
    return abs(outside + inside - r)
}

/// Closed loops where the plane z = `at` cuts the triangles (corner indices into `v`).
/// Points on the same mesh edge are the same point, so the loops close exactly.
func sliceLoops(_ v: [V3], _ faces: [UInt32], _ tris: [Int], at: Double) -> [[P2]] {
    var point: [UInt64: P2] = [:]
    var segs: [(UInt64, UInt64)] = []
    for t in tris {
        let ids = [Int(faces[t]), Int(faces[t + 1]), Int(faces[t + 2])]
        var cut: [UInt64] = []
        for e in 0..<3 {
            let a = ids[e], b = ids[(e + 1) % 3]
            let da = v[a].z - at, db = v[b].z - at
            if (da > 0) != (db > 0) {
                let lo = UInt64(min(a, b)), hi = UInt64(max(a, b))
                let key = lo << 32 | hi
                if point[key] == nil {
                    let s = da / (da - db)
                    point[key] = P2(v[a].x + (v[b].x - v[a].x) * s, v[a].y + (v[b].y - v[a].y) * s)
                }
                cut.append(key)
            }
        }
        if cut.count == 2 && cut[0] != cut[1] { segs.append((cut[0], cut[1])) }
    }
    var at2: [UInt64: [Int]] = [:]
    for (i, s) in segs.enumerated() {
        at2[s.0, default: []].append(i)
        at2[s.1, default: []].append(i)
    }
    var used = [Bool](repeating: false, count: segs.count)
    var loops: [[P2]] = []
    for s in 0..<segs.count where !used[s] {
        used[s] = true
        var keys = [segs[s].0]
        var end = segs[s].1
        var closed = false
        for _ in 0..<segs.count {
            if end == keys[0] { closed = true; break }
            keys.append(end)
            guard let next = at2[end]?.first(where: { !used[$0] }) else { break }
            used[next] = true
            end = segs[next].0 == end ? segs[next].1 : segs[next].0
        }
        if closed && keys.count >= 3 { loops.append(keys.compactMap { point[$0] }) }
    }
    return loops
}

private func analyse(_ loops: [[P2]], z: Double) -> Slice? {
    let all = loops
        .map { polyArea($0) < 0 ? Array($0.reversed()) : $0 }
        .map { (l: $0, a: polyArea($0)) }
        .sorted { $0.a > $1.a }
    guard let first = all.first, first.a > 0.5 else { return nil }
    let outer = first.l
    let area = first.a
    let pts = resampleLoop(outer, 96)
    guard let circ = fitCircle(pts) else { return nil }
    let rect = minRect(pts)
    let corner = min((max(0, rect.w * rect.l - area) / (4 - .pi)).squareRoot(), rect.l / 2)
    var rmsR = 0.0
    for p in pts { let d = roundRectDist(p, rect.centre, rect.w, rect.l, rect.angle, corner); rmsR += d * d }
    rmsR = (rmsR / Double(pts.count)).squareRoot()
    let tolC = max(0.3, 0.025 * circ.radius)
    let tolR = max(0.3, 0.02 * rect.l)
    let okC = circ.radius > 0.5 && circ.rms <= tolC
    let okR = rect.l > 0.5 && rmsR <= tolR
    var kind = SliceKind.free
    if okC && (!okR || circ.rms / tolC <= rmsR / tolR || corner > 0.42 * rect.l) { kind = .circle }
    else if okR { kind = .rect }
    var inner: Double?
    if kind == .circle {
        for h in all.dropFirst() where h.a > area * 0.04 {
            guard let hc = fitCircle(resampleLoop(h.l, 64)) else { continue }
            let off = ((hc.centre.x - circ.centre.x) * (hc.centre.x - circ.centre.x) + (hc.centre.y - circ.centre.y) * (hc.centre.y - circ.centre.y)).squareRoot()
            if off < max(1, circ.radius * 0.1) && hc.rms < max(0.3, hc.radius * 0.04) { inner = hc.radius * 2; break }
        }
    }
    return Slice(z: z, kind: kind, area: area, centroid: polyCentroid(outer), d: circ.radius * 2, c: circ.centre,
                 w: rect.w, l: rect.l, angle: rect.angle, corner: corner, inner: inner, corners: outer.count)
}

private func angleDiff(_ a: Double, _ b: Double) -> Double {
    var d = abs(a - b).truncatingRemainder(dividingBy: 180)
    if d > 90 { d = 180 - d }
    return d
}

private func lineFit(_ sl: [Slice]) -> (a: Double, b: Double, rms: Double) {
    let n = Double(sl.count)
    var sz = 0.0, sd = 0.0, szz = 0.0, szd = 0.0
    for s in sl { sz += s.z; sd += s.d; szz += s.z * s.z; szd += s.z * s.d }
    let den = n * szz - sz * sz
    let a = den > 1e-12 ? (n * szd - sz * sd) / den : 0
    let b = (sd - a * sz) / n
    var rms = 0.0
    for s in sl { let e = s.d - (a * s.z + b); rms += e * e }
    return (a, b, (rms / n).squareRoot())
}

private func rmsOf(_ xs: [Double]) -> Double {
    xs.isEmpty ? 0 : (xs.reduce(0) { $0 + $1 * $1 } / Double(xs.count)).squareRoot()
}

private func dist(_ a: P2, _ b: P2) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }

private func fits(_ kind: SliceKind, _ sl: [Slice], _ s: Slice) -> Bool {
    if s.kind != kind || sl.isEmpty { return false }
    switch kind {
    case .circle:
        let c = P2(median(sl.map { $0.c.x }), median(sl.map { $0.c.y }))
        let d0 = median(sl.map(\.d))
        if dist(s.c, c) > max(1.2, d0 * 0.06) { return false }
        let tol = max(0.8, d0 * 0.035)
        if abs(s.d - d0) <= tol { return true }
        if sl.count >= 2 {
            let f = lineFit(sl + [s])
            return f.rms <= max(0.3, d0 * 0.012) && abs(s.d - (f.a * s.z + f.b)) <= tol * 0.6
        }
        return false
    case .rect:
        let w = median(sl.map(\.w)), l = median(sl.map(\.l)), ang = median(sl.map(\.angle))
        let c = P2(median(sl.map { $0.c.x }), median(sl.map { $0.c.y }))
        func tol(_ v: Double) -> Double { max(0.8, v * 0.035) }
        let square = abs(w - l) < tol(l)
        let da = square ? min(angleDiff(s.angle, ang), angleDiff(s.angle + 90, ang)) : angleDiff(s.angle, ang)
        return abs(s.w - w) <= tol(w) && abs(s.l - l) <= tol(l) && da <= 4 && dist(s.c, c) <= max(1.2, l * 0.06)
    case .free:
        let a = median(sl.map(\.area))
        let c = P2(median(sl.map { $0.centroid.x }), median(sl.map { $0.centroid.y }))
        return abs(s.area - a) <= a * 0.07 && dist(s.centroid, c) <= max(1.2, a.squareRoot() * 0.06)
    }
}

private struct Seg {
    var kind: SliceKind
    var slices: [Slice]
    var real: [Slice] { slices.filter { !$0.ghost } }
}

private func segment(_ slices: [Slice], minLen: Double, dz: Double) -> [Seg] {
    var segs: [Seg] = []
    var i = 0
    while i < slices.count {
        let s = slices[i]
        if var cur = segs.last {
            if fits(cur.kind, cur.slices, s) {
                cur.slices.append(s)
                segs[segs.count - 1] = cur
                i += 1
                continue
            }
            // One odd slice inside a run that carries on: skip it.
            if cur.slices.count >= 2 && i + 2 < slices.count && fits(cur.kind, cur.slices, slices[i + 1]) && fits(cur.kind, cur.slices, slices[i + 2]) {
                i += 1
                continue
            }
        }
        segs.append(Seg(kind: s.kind, slices: [s]))
        i += 1
    }
    func len(_ g: Seg) -> Double { Double(g.slices.count) * dz }
    func size(_ g: Seg) -> Double { median(g.slices.map(\.area)) }
    var guardCount = 0
    while segs.count > 1 && guardCount < 200 {
        guardCount += 1
        var k = -1
        var shortest = Double.infinity
        for (j, g) in segs.enumerated() where len(g) < minLen && len(g) < shortest {
            shortest = len(g)
            k = j
        }
        if k < 0 { break }
        let g = segs[k]
        let cands = [k - 1, k + 1].filter { $0 >= 0 && $0 < segs.count }
        let into = cands.min { abs(size(segs[$0]) - size(g)) < abs(size(segs[$1]) - size(g)) }!
        let extra = g.slices.map { s -> Slice in
            var q = s
            q.ghost = true
            return q
        }
        if into < k { segs[into].slices += extra } else { segs[into].slices = extra + segs[into].slices }
        segs.remove(at: k)
    }
    var j = 1
    while j < segs.count {
        let a = segs[j - 1], b = segs[j]
        let real = b.real
        if a.kind == b.kind, !real.isEmpty, fits(a.kind, a.real, real[real.count / 2]) {
            segs[j - 1].slices += b.slices
            segs.remove(at: j)
        } else {
            j += 1
        }
    }
    return segs
}

/// Finds the parts of an upright 3D scan (Z up, mm). Nil when it is empty or flat.
public func fitScanShapes(_ mesh: TriangleMesh) -> ScanShapes? {
    let v = mesh.vertices
    let f = mesh.faces
    guard let b = mesh.bounds, f.count >= 3 else { return nil }
    let z0 = b.min.z, z1 = b.max.z
    let H = z1 - z0
    if !(H > 0.5) { return nil }
    let n = max(24, min(200, Int((H / 0.5).rounded())))
    let dz = H / Double(n)
    // Each triangle only goes to the slices it crosses.
    var buckets = [[Int]](repeating: [], count: n)
    var t = 0
    while t + 2 < f.count {
        let a = Int(f[t]), bb = Int(f[t + 1]), c = Int(f[t + 2])
        if a < v.count && bb < v.count && c < v.count {
            let lo = min(v[a].z, v[bb].z, v[c].z), hi = max(v[a].z, v[bb].z, v[c].z)
            let i0 = max(0, Int(ceil((lo - z0) / dz - 0.5 - 1e-6)))
            let i1 = min(n - 1, Int(floor((hi - z0) / dz - 0.5 + 1e-6)))
            if i0 <= i1 { for i in i0...i1 { buckets[i].append(t) } }
        }
        t += 3
    }
    var slices: [Slice] = []
    for i in 0..<n {
        let z = z0 + (Double(i) + 0.5) * dz
        if let s = analyse(sliceLoops(v, f, buckets[i], at: z + 1e-4), z: z) { slices.append(s) }
    }
    if slices.count < 3 { return nil }
    let segs = segment(slices, minLen: max(1.2, H * 0.03, dz * 2.5), dz: dz)
    var parts: [ScanPart] = []
    var explained = 0.0
    for (i, g) in segs.enumerated() {
        let use = g.real.isEmpty ? g.slices : g.real
        let lo = i == 0 ? z0 : (segs[i - 1].slices.last!.z + g.slices[0].z) / 2
        let hi = i == segs.count - 1 ? z1 : (g.slices.last!.z + segs[i + 1].slices[0].z) / 2
        let c = P2(median(use.map { $0.c.x }), median(use.map { $0.c.y }))
        switch g.kind {
        case .circle:
            let d = median(use.map(\.d))
            let fit = use.count >= 3 ? lineFit(use) : (a: 0.0, b: d, rms: 0.0)
            let dLo = fit.a * lo + fit.b, dHi = fit.a * hi + fit.b
            if abs(dHi - dLo) > max(1, d * 0.05) {
                var p = ScanPart(kind: .cone, z0: lo, z1: hi, d: dLo, dTop: dHi, centre: c)
                p.spread = fit.rms / 2
                parts.append(p)
            } else {
                let inners = use.compactMap(\.inner)
                let inner = Double(inners.count) >= Double(use.count) * 0.6 ? median(inners) : nil
                var p = ScanPart(kind: .cylinder, z0: lo, z1: hi, d: d, inner: inner, centre: c)
                p.spread = rmsOf(use.map { ($0.d - d) / 2 })
                parts.append(p)
            }
            explained += hi - lo
        case .rect:
            let corner = median(use.map(\.corner))
            let w = median(use.map(\.w)), l = median(use.map(\.l))
            var p = ScanPart(kind: .box, z0: lo, z1: hi, w: w, l: l,
                             angle: median(use.map(\.angle)), corner: corner < 0.4 ? 0 : corner, centre: c)
            p.spread = rmsOf(use.flatMap { [($0.w - w) / 2, ($0.l - l) / 2] })
            parts.append(p)
            explained += hi - lo
        case .free:
            let mid = use[use.count / 2]
            // Its outer size (for the drawing); the outline itself is made by CadSHAPE.
            var p = ScanPart(kind: .profile, z0: lo, z1: hi, w: mid.w, l: mid.l, angle: mid.angle, points: mid.corners, centre: mid.centroid)
            p.spread = rmsOf(use.map { ($0.area.squareRoot() - mid.area.squareRoot()) / 2 })
            parts.append(p)
            explained += (hi - lo) * 0.35
        }
    }
    return ScanShapes(parts: sharedRules(parts), height: H, explained: explained / H)
}

/// Smallest ± a measure is given in the shared rules (mm): half the 0,1 mm the phone shows.
private let uncFloor = 0.05
/// Boxes in one stack whose long sides are this close to parallel or square (degrees) share the angle.
private let angleShare = 2.0

/// One measure of one part: part index, value, weight (height) and ± (spread).
private struct Measure {
    var i: Int
    var v: Double
    var w: Double
    var s: Double
}

/// Every pair within their combined ±, and the weighted mean within each one's own ± (no value
/// moves more than its own uncertainty).
private func groupOK(_ g: [Measure], _ together: (Measure, Measure) -> Bool) -> Bool {
    let W = g.reduce(0.0) { $0 + $1.w }
    if !(W > 0) { return false }
    let m = g.reduce(0.0) { $0 + $1.w * $1.v } / W
    for a in g {
        let ua = max(a.s, uncFloor)
        if abs(a.v - m) > ua + 1e-9 { return false }
        for b in g {
            let ub = max(b.s, uncFloor)
            if abs(a.v - b.v) > (ua * ua + ub * ub).squareRoot() + 1e-9 || !together(a, b) { return false }
        }
    }
    return true
}

/// Groups (two or more) of measures that are the same within their noise, smallest value first.
private func equalGroups(_ ms: [Measure], together: (Measure, Measure) -> Bool = { _, _ in true }) -> [[Measure]] {
    let sorted = ms.sorted { $0.v < $1.v || ($0.v == $1.v && $0.i < $1.i) }
    var groups: [[Measure]] = []
    var cur: [Measure] = []
    for m in sorted {
        if !cur.isEmpty && groupOK(cur + [m], together) {
            cur.append(m)
        } else {
            if cur.count > 1 { groups.append(cur) }
            cur = [m]
        }
    }
    if cur.count > 1 { groups.append(cur) }
    return groups
}

/// Weighted mean of a group, and its ± (the members' ± combined: two equal parts give ±/√2).
private func combined(_ g: [Measure]) -> (value: Double, spread: Double) {
    let W = g.reduce(0.0) { $0 + $1.w }
    let value = g.reduce(0.0) { $0 + $1.w * $1.v } / W
    let spread = g.reduce(0.0) { $0 + ($1.w * $1.s) * ($1.w * $1.s) }.squareRoot() / W
    return (value, spread)
}

/// «1», «1 og 3», «1, 3 og 5».
private func partNumbers(_ ns: [Int]) -> String {
    let s = ns.sorted().map { String($0) }
    guard let last = s.last else { return "" }
    return s.count > 1 ? s.dropLast().joined(separator: ", ") + " og " + last : last
}

/// Shared rules (GlobFit): each part's numbers are noisy, but a thing is often made of equal parts.
/// Parts that measure the same within their own ± get one value (weighted by height), and the ±
/// shrinks. Cylinders on one axis: equal diameter. Boxes: equal long/short side, and long sides
/// parallel or square within `angleShare`. The parts are counted from the bottom, 1 first.
/// Nothing is snapped to the scan's own X axis or to round numbers. Same as `sharedRules` in
/// src/core/scanshapes.ts.
public func sharedRules(_ parts: [ScanPart]) -> [ScanPart] {
    var out = parts
    func others(_ g: [Measure], _ i: Int) -> String { partNumbers(g.filter { $0.i != i }.map { $0.i + 1 }) }
    // Equal diameters: cylinders on one axis.
    let diameters = parts.indices.filter { parts[$0].kind == .cylinder }
        .map { Measure(i: $0, v: parts[$0].d, w: parts[$0].height, s: parts[$0].spread) }
    let axis: (Measure, Measure) -> Bool = { a, b in
        dist(parts[a.i].centre, parts[b.i].centre) <= max(1.5, 0.05 * max(a.v, b.v))
    }
    for g in equalGroups(diameters, together: axis) {
        let c = combined(g)
        for a in g {
            out[a.i].d = c.value
            out[a.i].spread = c.spread
            out[a.i].rules.append("lik diameter som del " + others(g, a.i))
        }
    }
    // Equal box sides (long side = «lengde», short side = «bredde», as in PartMeasure).
    let boxes = parts.indices.filter { parts[$0].kind == .box }
    var sw = parts.map(\.spread)
    var sl = parts.map(\.spread)
    var sized = [Bool](repeating: false, count: parts.count)
    let widths = boxes.map { Measure(i: $0, v: parts[$0].w, w: parts[$0].height, s: parts[$0].spread) }
    for g in equalGroups(widths) {
        let c = combined(g)
        for a in g {
            out[a.i].w = c.value
            sw[a.i] = c.spread
            sized[a.i] = true
            out[a.i].rules.append("lik lengde som del " + others(g, a.i))
        }
    }
    let lengths = boxes.map { Measure(i: $0, v: parts[$0].l, w: parts[$0].height, s: parts[$0].spread) }
    for g in equalGroups(lengths) {
        let c = combined(g)
        for a in g {
            out[a.i].l = c.value
            sl[a.i] = c.spread
            sized[a.i] = true
            out[a.i].rules.append("lik bredde som del " + others(g, a.i))
        }
    }
    for i in boxes where sized[i] { out[i].spread = ((sw[i] * sw[i] + sl[i] * sl[i]) / 2).squareRoot() }
    // Parallel or square: boxes whose long sides are within angleShare of 0° or 90° to each other.
    func rel(_ a: Double, _ b: Double) -> Double {
        let d = angleDiff(a, b)
        return min(d, 90 - d)
    }
    func wrap(_ a: Double) -> Double {
        var x = a
        while x > 90 { x -= 180 }
        while x <= -90 { x += 180 }
        return x
    }
    var groups: [[Int]] = []
    for i in boxes {
        if let k = groups.firstIndex(where: { g in g.allSatisfy { rel(parts[i].angle, parts[$0].angle) <= angleShare } }) {
            groups[k].append(i)
        } else {
            groups.append([i])
        }
    }
    for g in groups where g.count > 1 {
        let ref = parts[g[0]].angle
        let off: [Double] = g.map { angleDiff(parts[$0].angle, ref) <= 45 ? 0.0 : 90.0 }
        var sa = 0.0, sh = 0.0
        for (k, i) in g.enumerated() {
            sa += parts[i].height * (ref + wrap(parts[i].angle - off[k] - ref))
            sh += parts[i].height
        }
        let m = sa / sh
        for (k, i) in g.enumerated() {
            out[i].angle = wrap(m + off[k])
            let par = g.indices.filter { $0 != k && off[$0] == off[k] }.map { g[$0] + 1 }
            let sq = g.indices.filter { $0 != k && off[$0] != off[k] }.map { g[$0] + 1 }
            if !par.isEmpty { out[i].rules.append("parallell med del " + partNumbers(par)) }
            if !sq.isEmpty { out[i].rules.append("rett vinkel på del " + partNumbers(sq)) }
        }
    }
    return out
}
