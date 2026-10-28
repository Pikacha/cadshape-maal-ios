import Foundation

/// Hole diameters on CadSHAPE's calibration plate (mm), in the order they are measured.
/// Same list as `CALIBRATION_HOLES` in src/core/calibration.ts.
public let calibrationHolesMM: [Double] = [10, 15, 23, 30, 40]

/// How this phone's hole measurements differ from real holes: real ≈ scale × measured + offsetMM.
/// `scale` takes up a size error (depth, focal length); `offsetMM` takes up an edge that is found too far
/// out or in (a blurred or shadowed edge moves every diameter by the same amount).
/// Learned by measuring the holes of the printed calibration plate.
public struct HoleCalibration: Codable, Equatable {
    public var scale: Double
    public var offsetMM: Double
    public var samples: Int
    /// How well the line fits the plate's holes (mm, root mean square).
    public var rmsMM: Double
    public var date: Date

    public init(scale: Double, offsetMM: Double, samples: Int, rmsMM: Double, date: Date = Date()) {
        self.scale = scale
        self.offsetMM = offsetMM
        self.samples = samples
        self.rmsMM = rmsMM
        self.date = date
    }

    /// A measured diameter (or width) corrected.
    public func corrected(_ measured: Double) -> Double { scale * measured + offsetMM }

    /// A centred outline corrected: every point moved out from the middle so a circle of diameter d
    /// becomes `corrected(d)` (scale, then half the offset outwards).
    public func corrected(outline: [P2]) -> [P2] {
        guard !outline.isEmpty else { return outline }
        var c = P2(0, 0)
        for p in outline { c += p }
        c /= Double(outline.count)
        return outline.map { p in
            let v = p - c
            let r = (v.x * v.x + v.y * v.y).squareRoot()
            if r < 1e-9 { return p }
            return c + v * max(0, scale + offsetMM / (2 * r))
        }
    }
}

public enum CalibrationProblem: Error, Equatable {
    case tooFew
    case sameSize
    case implausible(scale: Double, offsetMM: Double)
    case scattered(rmsMM: Double)

    /// Norwegian, for the app.
    public var message: String {
        switch self {
        case .tooFew: return "Mål minst tre av hullene på platen."
        case .sameSize: return "Hullene må ha ulik størrelse."
        case let .implausible(s, o):
            return "Rettelsen ble urimelig (skala \(mmText(s * 100)) %, kant \(mmText(o)) mm). Mål på nytt – sikt på riktig hull."
        case let .scattered(r):
            return "Målene sprikte for mye (± \(mmText(r)) mm). Mål på nytt nærmere og mer rett mot platen."
        }
    }
}

/// Least-squares line real = scale × measured + offset through the plate's holes.
/// Refuses a result that would hide a wrong hole or a bad measurement.
public func fitHoleCalibration(_ pairs: [(measured: Double, actual: Double)], date: Date = Date()) -> Result<HoleCalibration, CalibrationProblem> {
    let ok = pairs.filter { $0.measured.isFinite && $0.actual.isFinite && $0.measured > 0 && $0.actual > 0 }
    if ok.count < 3 { return .failure(.tooFew) }
    let n = Double(ok.count)
    let mx = ok.reduce(0) { $0 + $1.measured } / n
    let my = ok.reduce(0) { $0 + $1.actual } / n
    var sxx = 0.0, sxy = 0.0
    for p in ok {
        sxx += (p.measured - mx) * (p.measured - mx)
        sxy += (p.measured - mx) * (p.actual - my)
    }
    if sxx < 1 { return .failure(.sameSize) }
    let scale = sxy / sxx
    let offset = my - scale * mx
    var e = 0.0, worst = 0.0
    for p in ok {
        let d = scale * p.measured + offset - p.actual
        e += d * d
        worst = max(worst, abs(d))
    }
    let rms = (e / n).squareRoot()
    if !(0.8...1.25).contains(scale) || abs(offset) > 4 { return .failure(.implausible(scale: scale, offsetMM: offset)) }
    if rms > 0.6 || worst > 1.0 { return .failure(.scattered(rmsMM: rms)) }
    return .success(HoleCalibration(scale: scale, offsetMM: offset, samples: ok.count, rmsMM: rms, date: date))
}

/// The diameter of a measured hole for calibration: the circle through its outline (mm).
public func measuredDiameter(_ m: FrameMeasurement) -> Double? {
    guard let c = fitCircle(m.outlineMM), c.rms < c.radius * 0.05 else { return nil }
    return 2 * c.radius
}

/// A frame's sizes and outlines with the calibration applied (also the other edge, if any).
public func calibrated(_ m: FrameMeasurement, _ c: HoleCalibration?) -> FrameMeasurement {
    guard let c, !m.calibrated else { return m }
    var r = m
    r.outlineMM = c.corrected(outline: m.outlineMM)
    r.sizeMM = abs(polygonArea(r.outlineMM)).squareRoot()
    r.widthMM = c.corrected(m.widthMM)
    r.heightMM = c.corrected(m.heightMM)
    if var a = m.edgeAlternative {
        a.outlineMM = c.corrected(outline: a.outlineMM)
        a.sizeMM = abs(polygonArea(a.outlineMM)).squareRoot()
        a.widthMM = c.corrected(a.widthMM)
        a.heightMM = c.corrected(a.heightMM)
        r.edgeAlternative = a
    }
    r.calibrated = true
    return r
}
