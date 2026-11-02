import Foundation

/// The size of a scan without a reference: Object Capture gets its scale from the phone's own
/// tracking (LiDAR + motion), which is 1–2 % off (ARKit against Vicon, FPV Labs 2025). The shape is
/// right; every measure is off by the same percentage. Two fixes, both pure maths here:
///   • one measure from the calipers → the whole scan is scaled to match it,
///   • the phone's own bias, learnt from earlier corrections and used on the next scans.

/// Where the scale of a scan comes from, and how far (relative) it can be off.
public enum ScaleSource: String, Codable, Equatable {
    /// Only the phone's tracking.
    case tracking
    /// Corrected with this phone's calibration (earlier scans of a measured thing).
    case phone
    /// Corrected with a measure from the calipers on this very thing.
    case measured

    /// One standard deviation of the scale (relative). Tracking: 1–2 % in the literature;
    /// calibrated: what is left when the fixed part of the bias is gone (to be checked with real scans);
    /// measured: calipers (±0,05 mm) over a measure of tens of mm plus the fit.
    public var sigma: Double {
        switch self {
        case .tracking: return 0.015
        case .phone: return 0.005
        case .measured: return 0.002
        }
    }

    public var label: String {
        switch self {
        case .tracking: return "Størrelse fra telefonens sporing"
        case .phone: return "Størrelse rettet med kalibreringen"
        case .measured: return "Størrelse rettet etter skyvelæren"
        }
    }
}

/// Which measure of a part the calipers gave.
public enum PartMeasure: String, CaseIterable, Identifiable {
    case diameter, diameterTop, width, length, height
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .diameter: return "Diameter"
        case .diameterTop: return "Diameter oppe"
        case .width: return "Lengde (lange side)"
        case .length: return "Bredde (korte side)"
        case .height: return "Høyde"
        }
    }
}

extension ScanPart {
    /// The measures one can take on this part with calipers.
    public var measures: [PartMeasure] {
        switch kind {
        case .cylinder: return [.diameter, .height]
        case .cone: return [.diameter, .diameterTop, .height]
        case .box, .profile: return [.width, .length, .height]
        }
    }

    public func value(_ m: PartMeasure) -> Double {
        switch m {
        case .diameter: return d
        case .diameterTop: return dTop
        case .width: return w
        case .length: return l
        case .height: return height
        }
    }

    /// Every length times `f` (about the origin: the scan stands on Z = 0, centred).
    public func scaled(by f: Double) -> ScanPart {
        var p = self
        p.z0 *= f
        p.z1 *= f
        p.d *= f
        p.dTop *= f
        p.inner = inner.map { $0 * f }
        p.w *= f
        p.l *= f
        p.corner *= f
        p.centre = centre * f
        p.spread *= f
        return p
    }

    /// ± (mm, one standard deviation) for a measure: how well the slices agree with it, and how far
    /// the scale can be off.
    public func plusMinus(_ m: PartMeasure, scale: ScaleSource) -> Double {
        let v = value(m)
        let fit = m == .height ? spread * 0.5 : spread
        return (fit * fit + (scale.sigma * v) * (scale.sigma * v)).squareRoot()
    }
}

extension ScanShapes {
    public func scaled(by f: Double) -> ScanShapes {
        ScanShapes(parts: parts.map { $0.scaled(by: f) }, height: height * f, explained: explained)
    }
}

/// The factor that makes `measured` (the scan) equal `truth` (the calipers), or nil when the two are
/// too far apart to be the same measure (a typo, or the wrong side measured).
public func scaleFactor(measured: Double, truth: Double, maxOff: Double = 0.15) -> Double? {
    guard measured > 0.5, truth > 0.5 else { return nil }
    let f = truth / measured
    return abs(f - 1) <= maxOff ? f : nil
}

/// The phone's own scale bias, learnt from the factors of earlier caliper corrections.
public struct PhoneScale: Codable, Equatable {
    /// Factors from corrections, newest last (at most 12 kept).
    public var samples: [Double] = []

    public init(samples: [Double] = []) { self.samples = samples }

    public mutating func add(_ f: Double) {
        samples.append(f)
        if samples.count > 12 { samples.removeFirst(samples.count - 12) }
    }

    /// Median of the samples (one bad correction can't pull it), nil until there are two.
    public var factor: Double? {
        guard samples.count >= 2 else { return nil }
        let s = samples.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// How much the samples disagree (relative): small = the bias is fixed and calibration works.
    public var spread: Double? {
        guard let m = factor, samples.count >= 2 else { return nil }
        let d = samples.map { abs($0 - m) }.sorted()
        return d[d.count / 2] * 1.4826
    }
}

/// "±0,4" with the Norwegian comma.
public func plusMinusText(_ v: Double) -> String { "±" + shortMM(max(0.1, v)) }
