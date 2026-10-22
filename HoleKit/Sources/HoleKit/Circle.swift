import Foundation

/// Least-squares circle through points (Kåsa): quick, for the phone's own readout while measuring.
/// (The exact shape – circle, rounded rectangle or free form – is fitted by CadSHAPE on the PC.)
public func fitCircle(_ pts: [P2]) -> (centre: P2, radius: Double, rms: Double)? {
    if pts.count < 3 { return nil }
    // x² + y² + a·x + b·y + c = 0, solved in least squares (normal equations, 3 × 3).
    var m = [[Double]](repeating: [0, 0, 0], count: 3)
    var v = [0.0, 0.0, 0.0]
    var mean = P2(0, 0)
    for p in pts { mean += p }
    mean /= Double(pts.count)
    for q in pts {
        let p = q - mean
        let row = [p.x, p.y, 1]
        let rhs = -(p.x * p.x + p.y * p.y)
        for i in 0..<3 {
            v[i] += row[i] * rhs
            for j in 0..<3 { m[i][j] += row[i] * row[j] }
        }
    }
    guard let s = solve3(m, v) else { return nil }
    let cx = -s[0] / 2, cy = -s[1] / 2
    let r2 = cx * cx + cy * cy - s[2]
    if !(r2 > 0) { return nil }
    let r = r2.squareRoot()
    var e = 0.0
    for q in pts {
        let p = q - mean
        let d = ((p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy)).squareRoot() - r
        e += d * d
    }
    return (P2(cx, cy) + mean, r, (e / Double(pts.count)).squareRoot())
}

/// 3 × 3 linear system by Cramer's rule.
func solve3(_ m: [[Double]], _ v: [Double]) -> [Double]? {
    func det(_ a: [[Double]]) -> Double {
        a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1])
            - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
            + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
    }
    let d = det(m)
    if abs(d) < 1e-18 { return nil }
    var out = [0.0, 0.0, 0.0]
    for k in 0..<3 {
        var a = m
        for i in 0..<3 { a[i][k] = v[i] }
        out[k] = det(a) / d
    }
    return out
}

/// What the phone shows while measuring: «Ø 68 mm» when the hole is round, else «71 × 52 mm».
public func quickText(_ m: FrameMeasurement) -> String {
    if let c = fitCircle(m.outlineMM), c.rms < c.radius * 0.025 {
        return "Ø " + mmText(2 * c.radius) + " mm"
    }
    return mmText(m.widthMM) + " × " + mmText(m.heightMM) + " mm"
}

/// One decimal, Norwegian comma.
public func mmText(_ v: Double) -> String {
    String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
}
