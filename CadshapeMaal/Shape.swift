import Foundation

/// The hole's shape in mm, as CadSHAPE knows it (src/core/measured.ts on the PC).
enum MeasuredShape: Equatable {
    case circle(d: Double)
    case rect(w: Double, h: Double, r: Double)
    case free(points: [[Double]])

    var kind: ShapeKind {
        switch self {
        case .circle: return .circle
        case .rect: return .rect
        case .free: return .free
        }
    }

    var diameter: Double? {
        if case .circle(let d) = self { return d }
        return nil
    }

    /// Outer width and height (mm).
    var size: (Double, Double) {
        switch self {
        case .circle(let d): return (d, d)
        case .rect(let w, let h, _): return (w, h)
        case .free(let pts):
            let xs = pts.map { $0[0] }, ys = pts.map { $0[1] }
            return ((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
        }
    }

    /// «Ø 68,4 mm», «71,2 × 52,0 mm (hjørner r 4,0)», «fri form 120,3 × 80,1 mm».
    var text: String {
        switch self {
        case .circle(let d): return "Ø \(mm(d)) mm"
        case .rect(let w, let h, let r): return "\(mm(w)) × \(mm(h)) mm" + (r >= 0.5 ? " (hjørner r \(mm(r)))" : "")
        case .free:
            let (w, h) = size
            return "fri form \(mm(w)) × \(mm(h)) mm"
        }
    }
}

enum ShapeKind: String, CaseIterable, Identifiable {
    case circle, rect, free
    var id: String { rawValue }
    var label: String {
        switch self {
        case .circle: return "Rundt hull"
        case .rect: return "Firkantet hull"
        case .free: return "Fri form"
        }
    }
    var short: String {
        switch self {
        case .circle: return "Rund"
        case .rect: return "Firkant"
        case .free: return "Fri"
        }
    }
}

/// One decimal, Norwegian comma.
func mm(_ v: Double, digits: Int = 1) -> String {
    String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",")
}

extension MeasuredShape: Codable {
    private enum Keys: String, CodingKey { case kind, d, w, h, r, points }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "circle":
            self = .circle(d: try c.decode(Double.self, forKey: .d))
        case "rect":
            self = .rect(w: try c.decode(Double.self, forKey: .w), h: try c.decode(Double.self, forKey: .h), r: try c.decodeIfPresent(Double.self, forKey: .r) ?? 0)
        case "free":
            self = .free(points: try c.decode([[Double]].self, forKey: .points))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Ukjent form")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .circle(let d):
            try c.encode("circle", forKey: .kind)
            try c.encode(d, forKey: .d)
        case .rect(let w, let h, let r):
            try c.encode("rect", forKey: .kind)
            try c.encode(w, forKey: .w)
            try c.encode(h, forKey: .h)
            try c.encode(r, forKey: .r)
        case .free(let pts):
            try c.encode("free", forKey: .kind)
            try c.encode(pts, forKey: .points)
        }
    }
}

/// What to make from the hole (MAKES in src/core/measured.ts).
enum MakeKind: String, CaseIterable, Identifiable, Codable {
    case lokk, plugg, plate, form
    var id: String { rawValue }
    var label: String {
        switch self {
        case .lokk: return "Lokk med krage"
        case .plugg: return "Plugg"
        case .plate: return "Dekkplate"
        case .form: return "Bare formen"
        }
    }
    var short: String {
        switch self {
        case .lokk: return "Lokk"
        case .plugg: return "Plugg"
        case .plate: return "Plate"
        case .form: return "Form"
        }
    }
    var hint: String {
        switch self {
        case .lokk: return "Dekker hullet, kragen går inn i hullet og holder det på plass"
        case .plugg: return "Fyller hullet"
        case .plate: return "Flat plate som dekker hullet"
        case .form: return "Akkurat hullets form, til å bygge videre på"
        }
    }
    var uses: [ParamKey] {
        switch self {
        case .lokk: return [.margin, .thickness, .depth, .clearance, .wall]
        case .plugg: return [.depth, .clearance]
        case .plate: return [.margin, .thickness]
        case .form: return [.depth]
        }
    }
}

enum ParamKey: String, CaseIterable, Identifiable, Codable {
    case clearance, margin, thickness, depth, wall
    var id: String { rawValue }
    var label: String {
        switch self {
        case .margin: return "Kant utenfor hullet"
        case .thickness: return "Tykkelse"
        case .depth: return "Dybde inn i hullet"
        case .clearance: return "Klaring"
        case .wall: return "Veggtykkelse"
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .margin: return 1...100
        case .thickness: return 0.6...30
        case .depth: return 1...300
        case .clearance: return 0...5
        case .wall: return 0.8...20
        }
    }
    var step: Double {
        switch self {
        case .margin, .depth: return 1
        case .thickness: return 0.5
        case .clearance: return 0.1
        case .wall: return 0.2
        }
    }
    var defaultValue: Double {
        switch self {
        case .clearance: return 0.4
        case .margin: return 10
        case .thickness: return 3
        case .depth: return 15
        case .wall: return 2
        }
    }
}

/// Common round holes: hole saws and cut-outs for downlights and pipes (mm).
let standardHoles: [Double] = [
    14, 16, 19, 20, 22, 25, 29, 32, 35, 38, 40, 44, 50, 51, 54, 55, 57, 60, 64, 65, 68, 70, 73, 75, 76, 79, 80, 83, 85, 86, 89, 90, 92, 95, 100, 102, 105, 108, 110,
    111, 114, 120, 121, 125, 127, 133, 140, 150, 152, 160, 165, 168, 175, 177, 200,
]

/// Standard sizes within 5 % of a measured diameter, closest first (at most three).
func nearStandard(_ d: Double) -> [Double] {
    Array(standardHoles.filter { abs($0 - d) <= d * 0.05 }.sorted { abs($0 - d) < abs($1 - d) }.prefix(3))
}

/// What to make from a pattern of holes (src/core/measured-holes.ts on the PC).
enum HolesMake: String, CaseIterable, Identifiable, Codable {
    case plate, holes
    var id: String { rawValue }
    var label: String {
        switch self {
        case .plate: return "Plate med hull"
        case .holes: return "Bare hullene"
        }
    }
    var hint: String {
        switch self {
        case .plate: return "Monteringsplate med hullene på riktig sted – skruene går rett gjennom"
        case .holes: return "Hullene som en hullgruppe du kan legge på en egen del"
        }
    }
    var symbol: String {
        switch self {
        case .plate: return "rectangle.dashed.and.paperclip"
        case .holes: return "circle.grid.2x2"
        }
    }
    var uses: [ParamKey] {
        switch self {
        case .plate: return [.thickness, .margin, .clearance]
        case .holes: return [.clearance]
        }
    }
}

/// Starting values for a pattern (screws need a little play; the plate a smaller border).
let holesDefaults: [ParamKey: Double] = [.thickness: 3, .margin: 8, .clearance: 0.3]

extension MakeKind {
    /// Picture for the choice cards.
    var symbol: String {
        switch self {
        case .lokk: return "circle.circle"
        case .plugg: return "smallcircle.filled.circle"
        case .plate: return "square"
        case .form: return "square.dashed"
        }
    }
}
