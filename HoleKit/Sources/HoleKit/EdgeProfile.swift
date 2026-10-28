import Foundation

/// Two edges around a hole? A shadow, a chamfer, a crushed plaster edge or the inside of the hole seen
/// at an angle can make a ring between the hole and the wall, and the brightness threshold then picks
/// one of the two edges without saying so. This averages the brightness across the found edge round
/// the hole and finds the steps in it. Two clear steps far enough apart: both are given, so the user
/// can choose, and the measurement is not locked by itself.
///
/// Same code as src/scan/vision/edgeprofile.ts – change both (same scenes in the tests).
public struct EdgeProfile {
    /// Brightness step across the whole profile (grey levels).
    public var contrast: Double
    /// The other edge, pixels along the outward normal from the found edge (negative = inside).
    public var altOffset: Double?
    /// Share of the brightness step at the other edge (0…1).
    public var altShare: Double
    /// Outward unit normals at each outline point.
    public var normals: [P2]
}

/// Bilinear brightness at a continuous point (pixel centres at i + 0.5), or nil outside.
func sampleGray(_ g: GrayImage, _ x: Double, _ y: Double) -> Double? {
    let fx = x - 0.5, fy = y - 0.5
    let i = Int(floor(fx)), j = Int(floor(fy))
    if i < 0 || j < 0 || i + 1 >= g.width || j + 1 >= g.height { return nil }
    let tx = fx - Double(i), ty = fy - Double(j)
    let w = g.width
    let a = Double(g.pixels[j * w + i]), b = Double(g.pixels[j * w + i + 1])
    let c = Double(g.pixels[(j + 1) * w + i]), e = Double(g.pixels[(j + 1) * w + i + 1])
    return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + e * tx) * ty
}

/// Outward unit normals of a closed outline (from neighbours a few points away, pointing away from the middle).
public func outlineNormals(_ outline: [P2]) -> [P2] {
    let n = outline.count
    guard n > 0 else { return [] }
    var c = P2(0, 0)
    for p in outline { c += p }
    c /= Double(n)
    let k = max(1, Int((Double(n) / 60).rounded()))
    return outline.indices.map { i in
        let p = outline[i]
        let a = outline[(i - k + n) % n], b = outline[(i + k) % n]
        var v = P2(b.y - a.y, -(b.x - a.x))
        let len = (v.x * v.x + v.y * v.y).squareRoot()
        v = len < 1e-9 ? p - c : v / len
        if v.x * (p.x - c.x) + v.y * (p.y - c.y) < 0 { v = -v }
        let l2 = (v.x * v.x + v.y * v.y).squareRoot()
        return l2 > 0 ? v / l2 : v
    }
}

private let minStep = 8.0
private let minShare = 0.25
private let minApart = 2.5

/// - Parameters:
///   - g: the blurred grey picture the hole was found in
///   - outline: the found edge (sub-pixel, closed)
public func edgeProfile(_ g: GrayImage, outline: [P2]) -> EdgeProfile? {
    if outline.count < 12 { return nil }
    var c = P2(0, 0)
    for p in outline { c += p }
    c /= Double(outline.count)
    var r = 0.0
    for p in outline { r += ((p.x - c.x) * (p.x - c.x) + (p.y - c.y) * (p.y - c.y)).squareRoot() }
    r /= Double(outline.count)
    if r < 6 { return nil }
    let normals = outlineNormals(outline)
    let reach = min(30, max(4, 0.35 * r))
    let step = 0.5
    let bins = Int((2 * reach / step).rounded()) + 1
    var sum = [Double](repeating: 0, count: bins)
    var count = [Double](repeating: 0, count: bins)
    let every = max(1, outline.count / 96)
    var used = 0, tried = 0
    for i in stride(from: 0, to: outline.count, by: every) {
        tried += 1
        let p = outline[i], u = normals[i]
        var row: [Double] = []
        row.reserveCapacity(bins)
        for b in 0..<bins {
            let d = -reach + Double(b) * step
            guard let v = sampleGray(g, p.x + u.x * d, p.y + u.y * d) else { break }
            row.append(v)
        }
        if row.count < bins { continue }
        used += 1
        for b in 0..<bins {
            sum[b] += row[b]
            count[b] += 1
        }
    }
    if Double(used) < max(8, Double(tried) * 0.6) { return nil }
    let prof = (0..<bins).map { sum[$0] / count[$0] }
    let rawContrast = prof[bins - 1] - prof[0]
    let sign: Double = rawContrast >= 0 ? 1 : -1
    let total = abs(rawContrast)
    let none = EdgeProfile(contrast: total, altOffset: nil, altShare: 0, normals: normals)
    if total < minStep * 1.5 { return none }
    let slope = (1..<bins).map { sign * (prof[$0] - prof[$0 - 1]) }
    let floor = (slope.max() ?? 0) * 0.15
    var steps: [(height: Double, centre: Double)] = []
    var runHeight = 0.0, runMoment = 0.0, inRun = false
    for (b, s) in slope.enumerated() {
        let at = -reach + (Double(b) + 0.5) * step
        if s > floor {
            inRun = true
            runHeight += s
            runMoment += s * at
        } else if inRun {
            steps.append((runHeight, runMoment / runHeight))
            runHeight = 0; runMoment = 0; inRun = false
        }
    }
    if inRun { steps.append((runHeight, runMoment / runHeight)) }
    let clear = steps.filter { $0.height >= minStep && $0.height >= minShare * total }
    if clear.count < 2 { return none }
    let here = clear.min { abs($0.centre) < abs($1.centre) }!
    let others = clear.filter { abs($0.centre - here.centre) >= minApart }
    guard let other = others.max(by: { $0.height < $1.height }) else { return none }
    return EdgeProfile(contrast: total, altOffset: ((other.centre - here.centre) * 100).rounded() / 100,
                       altShare: min(1, other.height / total), normals: normals)
}

/// The outline moved `offset` pixels along its normals (to the other edge).
public func shiftOutline(_ outline: [P2], normals: [P2], offset: Double) -> [P2] {
    outline.indices.map { outline[$0] + normals[$0] * offset }
}
