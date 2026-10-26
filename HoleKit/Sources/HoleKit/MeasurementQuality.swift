import Foundation

/// Screening estimates, not a calibrated confidence interval or a guarantee of printed fit.
public struct MeasurementQuality {
    public var steadiness: Double
    public var uncertaintyMM: Double?
    public var canAutoLock: Bool
}

/// Repeatability and resolution are different: a coarse depth edge can be perfectly repeatable.
public func measurementQuality(_ measurements: [FrameMeasurement], trackingNormal: Bool) -> MeasurementQuality {
    let recent = Array(measurements.suffix(8))
    guard recent.count >= 3, recent.allSatisfy({ $0.widthMM.isFinite && $0.heightMM.isFinite && $0.widthMM > 0 && $0.heightMM > 0 }) else {
        return MeasurementQuality(steadiness: 0, uncertaintyMM: nil, canAutoLock: false)
    }
    func spread(_ values: [Double]) -> (median: Double, deviation: Double, range: Double) {
        let sorted = values.sorted(), median = sorted[sorted.count / 2]
        return (median, values.map { abs($0 - median) }.sorted()[sorted.count / 2], sorted.last! - sorted.first!)
    }
    let width = spread(recent.map(\.widthMM)), height = spread(recent.map(\.heightMM))
    let relative = max(width.deviation / width.median, height.deviation / height.median)
    var steady = max(0, min(1, 1 - relative / 0.02)) * min(1, Double(recent.count) / 6)
    if max(width.range / width.median, height.range / height.median) > 0.04 { steady = 0 }
    let resolution = recent.map { $0.edgeResolutionMM * ($0.source == .depth ? 2 : 1) }.max() ?? .infinity
    let surface = recent.map { m -> Double in
        let size = max(m.widthMM, m.heightMM)
        let systematicFloor = size * (m.planePoints > 0 ? 0.01 : 0.03)
        let residualEffect = size * m.planeResidualMM / max(1, m.plane.distance * 1000)
        return max(systematicFloor, residualEffect)
    }.max() ?? .infinity
    let uncertainty = max(0.3, max(resolution, surface)) + 1.5 * max(width.deviation, height.deviation)
    let supported = recent.allSatisfy {
        $0.source == .picture && !$0.usedSmoothedDepth && $0.planePoints >= 60 &&
        $0.planeInlierRatio >= 0.6 && $0.edgePixels >= 48 && $0.edgeResolutionMM > 0 &&
        $0.plane.distance >= 0.2 && $0.plane.distance <= 1 && $0.plane.tilt <= 35
    }
    return MeasurementQuality(steadiness: steady, uncertaintyMM: uncertainty,
        canAutoLock: trackingNormal && recent.count >= 6 && steady >= 0.85 && supported && uncertainty <= 0.5)
}

/// An explicit control dimension changes only this hole; never a global device calibration.
public func controlDiameter(_ text: String) -> Double? {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
    guard let value = Double(normalized), value.isFinite, value >= 0.5, value <= 1000 else { return nil }
    return value
}

/// Keep enough numeric evidence to investigate a later failed fit; no photos or connection keys.
public struct MeasurementDiagnostics: Codable, Equatable {
    public var source: String
    public var widthMM: Double
    public var heightMM: Double
    public var distanceMM: Double
    public var tiltDegrees: Double
    public var edgePixels: Double
    public var edgeResolutionMM: Double
    public var planePoints: Int
    public var planeInlierRatio: Double
    public var planeResidualMM: Double
    public var usedSmoothedDepth: Bool
    public var uncertaintyMM: Double?

    public init(_ m: FrameMeasurement, uncertaintyMM: Double?) {
        source = m.source.rawValue
        widthMM = m.widthMM
        heightMM = m.heightMM
        distanceMM = m.plane.distance * 1000
        tiltDegrees = m.plane.tilt
        edgePixels = m.edgePixels
        edgeResolutionMM = m.edgeResolutionMM
        planePoints = m.planePoints
        planeInlierRatio = m.planeInlierRatio
        planeResidualMM = m.planeResidualMM
        usedSmoothedDepth = m.usedSmoothedDepth
        self.uncertaintyMM = uncertaintyMM
    }
}
