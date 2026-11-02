import Combine
import Foundation
import HoleKit
import UIKit

/// What to make for the inside of a box (server: src/core/measured-box.ts).
enum BoxMake: String, CaseIterable, Identifiable, Codable {
    case dividers, grid, insert, gridfinity, lid
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dividers: return "Skillevegger med spor"
        case .grid: return "Skillevegger i ett"
        case .insert: return "Innsats med rom"
        case .gridfinity: return "Gridfinity"
        case .lid: return "Lokk"
        }
    }
    var short: String {
        switch self {
        case .dividers: return "Spor"
        case .grid: return "Rutenett"
        case .insert: return "Innsats"
        case .gridfinity: return "Gridfinity"
        case .lid: return "Lokk"
        }
    }
    var symbol: String {
        switch self {
        case .dividers: return "square.split.2x2"
        case .grid: return "grid"
        case .insert: return "tray.2"
        case .gridfinity: return "square.grid.3x3.square"
        case .lid: return "rectangle.portrait.on.rectangle.portrait"
        }
    }
    var hint: String {
        switch self {
        case .dividers: return "Vegger som skyves i kryss – printes flatt på minutter, store bokser er ikke noe problem"
        case .grid: return "Ett rutenett med ramme som settes ned i boksen"
        case .insert: return "Brett med bunn og rom, deles opp hvis boksen er større enn platen"
        case .gridfinity: return "42 mm-ruter som fyller bunnen, og bokser med stablekant som fyller skuffen"
        case .lid: return "Plate oppå boksen med en krage som går ned innenfor veggene"
        }
    }
    var uses: [SpaceParam] {
        switch self {
        case .dividers, .grid: return [.cols, .rows, .height, .thickness, .clearance]
        case .insert: return [.cols, .rows, .height, .clearance]
        case .gridfinity, .lid: return [.clearance]
        }
    }
    /// The choices the panel offers. `grid` and `lid` stay in the enum so older saved
    /// measurements still decode (and can be sent as they were).
    static let offered: [BoxMake] = [.dividers, .insert, .gridfinity]
    /// The word in the segmented choice.
    var choice: String {
        switch self {
        case .dividers, .grid: return "Skillevegger"
        case .insert: return "Innsats"
        case .gridfinity: return "Gridfinity"
        case .lid: return "Lokk"
        }
    }
    /// Whether the room count matters for this make.
    var hasRooms: Bool { uses.contains(.cols) }
}

/// A number to set for the parts (key as on the server).
enum SpaceParam: String, CaseIterable, Identifiable {
    case cols, rows, height, thickness, clearance
    var id: String { rawValue }
    /// The key the server knows (src/core/measured-box.ts sanitizeBoxParams).
    var key: String { rawValue }
    var label: String {
        switch self {
        case .cols: return "På tvers"
        case .rows: return "På langs"
        case .height: return "Høyde"
        case .thickness: return "Veggtykkelse"
        case .clearance: return "Klaring mot veggene"
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .cols, .rows: return 1...12
        case .height: return 0...400
        case .thickness: return 0.8...5
        case .clearance: return 0...5
        }
    }
    var step: Double {
        switch self {
        case .cols, .rows, .height: return 1
        case .thickness: return 0.2
        case .clearance: return 0.1
        }
    }
    var defaultValue: Double {
        switch self {
        case .cols: return 3
        case .rows: return 2
        case .height: return 0
        case .thickness: return 1.6
        case .clearance: return 0.5
        }
    }
    /// Whole numbers without a unit (rooms), or mm.
    var isCount: Bool { self == .cols || self == .rows }
    /// What 0 means.
    var zeroText: String? { self == .height ? "auto" : nil }
}

/// Gridfinity bins to fill a drawer with (grid units; 0 × 0 = none).
let binSizes: [(x: Int, y: Int)] = [(0, 0), (1, 1), (2, 1), (2, 2), (3, 1), (3, 2)]

/// One measuring step's result, for the steady check and the lock.
private struct BoxSample {
    var width: Double
    var length: Double
    var height: Double?
    var wall: Double?
}


/// Measuring the inside of a box or drawer with the LiDAR point cloud (many frames together), and
/// what to make for it. The camera view feeds `update`; the PC gets the parts on «Lag».
final class SpaceModel: ObservableObject {
    // Live
    @Published var box: BoxFit?
    /// The box's floor on screen.
    @Published var polygonOnScreen: [CGPoint] = []
    @Published var steadiness = 0.0
    /// Why this measurement may be poor right now (dark or glossy surface).
    @Published var advice: String? { didSet { if let a = advice, a != oldValue { applog("LiDAR", a) } } }
    @Published var hint = "" { didSet { if hint != oldValue { applog("LiDAR", hint) } } }

    // Locked (or typed in)
    @Published var locked = false
    @Published var manual = false
    @Published var boxOut = BoxOut(width: 150, length: 100, height: 50, wall: nil)
    @Published var boxMake: BoxMake = .dividers
    @Published var bins = 2
    @Published var values: [SpaceParam: Double] = Dictionary(uniqueKeysWithValues: SpaceParam.allCases.map { ($0, $0.defaultValue) })
    @Published var spread: Double?
    @Published var working = false
    @Published var done: String?
    @Published var notes: [String] = []
    @Published var error: String? { didSet { if let e = error { applog("LiDAR feil", e) } } }

    /// Bumped to tell the camera to start the point cloud afresh.
    private(set) var generation = 0

    weak var owner: MeasureModel?
    private var boxes: [BoxSample] = []
    private var steadySince: Date?
    private var savedId: UUID?
    /// Frames in a row without a fit.
    private var misses = 0
    private let haptic = UINotificationFeedbackGenerator()

    // MARK: Live

    /// Back to measuring.
    private func resetLive() {
        generation += 1
        box = nil
        polygonOnScreen = []
        steadiness = 0
        boxes = []
        misses = 0
        advice = nil
        steadySince = nil
        locked = false
        manual = false
        done = nil
        notes = []
        error = nil
        working = false
        hint = startHint
    }

    /// The app switched connection: an answer from the old one never comes.
    func connectionChanged() {
        working = false
    }

    func reset() {
        resetLive()
        spread = nil
        savedId = nil
    }

    private var startHint: String { "Hold telefonen over boksen og sikt krysset på bunnen" }

    /// A new fit from the camera (main thread).
    func update(box fit: BoxFit?, screen: [CGPoint]) {
        guard !locked else { return }
        box = fit
        polygonOnScreen = screen
        guard let fit else {
            lost("Finner ikke bunnen og veggene. Sikt krysset på bunnen av boksen, 25–60 cm over den.")
            return
        }
        misses = 0
        var sample = BoxSample(width: fit.width, length: fit.length, height: fit.height, wall: fit.wall)
        // A box at ~45° to the phone: width and length can swap from frame to frame. Keep them apart.
        if let prev = boxes.last,
           abs(sample.width - prev.length) + abs(sample.length - prev.width) < abs(sample.width - prev.width) + abs(sample.length - prev.length) {
            let w = sample.width
            sample.width = sample.length
            sample.length = w
        }
        boxes.append(sample)
        if boxes.count > 8 { boxes.removeFirst(boxes.count - 8) }
        steadiness = agreement([boxes.map(\.width), boxes.map(\.length)], absMM: 1.5, relative: 0.005) * (fit.allWallsSeen ? 1 : 0.6)
        if !fit.allWallsSeen {
            hint = "Ser ikke alle fire veggene. Hold telefonen mer midt over boksen."
        } else if fit.height == nil {
            hint = "Ser ikke kanten øverst. Løft telefonen litt så hele kanten er med."
        } else {
            hint = steadyHint
        }
        checkAuto(ready: fit.allWallsSeen && fit.height != nil)
    }

    private func lost(_ text: String) {
        // One frame without a fit (an edge at the picture border, a blurry frame) must not throw
        // away what has been measured: only a few in a row do.
        misses += 1
        if misses < 3 {
            steadiness *= 0.7
            steadySince = nil
            return
        }
        boxes.removeAll()
        steadiness = 0
        steadySince = nil
        hint = text
    }

    private var steadyHint: String {
        steadiness < 0.7 ? "Hold stille …" : ((owner?.autoLock ?? false) ? "Stødig – låser …" : "Stødig – trykk «Lås målet».")
    }

    /// No depth in this frame. On a phone without LiDAR that is final; with LiDAR it is just a
    /// frame without depth (start-up, after a pause) – then it counts as one miss.
    func noLidar() {
        if owner?.hasLidar == false {
            hint = "Dette trenger LiDAR (iPhone Pro). Skriv inn målene i stedet."
        } else {
            lost(hint)
        }
    }

    /// 0…1: how much the last sizes agree. Steady = the typical deviation is within
    /// `absMM` or `relative` of the size, whichever is larger (LiDAR is never steadier than ~1 mm).
    private func agreement(_ series: [[Double]], absMM: Double, relative: Double) -> Double {
        guard let first = series.first, first.count >= 3 else { return 0 }
        func score(_ v: [Double]) -> Double {
            let m = median(v)
            let mad = median(v.map { abs($0 - m) })
            return mad / max(absMM, relative * m)
        }
        let worst = series.map(score).max() ?? 1
        return max(0, min(1, 1 - worst)) * min(1, Double(first.count) / 5)
    }

    private func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }

    private func checkAuto(ready: Bool) {
        guard owner?.autoLock == true, ready, steadiness >= 0.85, !working else {
            steadySince = nil
            return
        }
        let now = Date()
        guard let since = steadySince else {
            steadySince = now
            return
        }
        if now.timeIntervalSince(since) >= 1.2 {
            steadySince = nil
            lock()
        }
    }

    var canLock: Bool { !boxes.isEmpty }

    // MARK: Locking

    func lock() {
        guard !boxes.isEmpty else { return }
        boxOut = BoxOut(
            width: median(boxes.map(\.width)),
            length: median(boxes.map(\.length)),
            height: boxes.compactMap(\.height).isEmpty ? 0 : median(boxes.compactMap(\.height)),
            wall: boxes.compactMap(\.wall).isEmpty ? nil : median(boxes.compactMap(\.wall))
        )
        spread = box?.spread
        haptic.notificationOccurred(.success)
        locked = true
        manual = false
        done = nil
        error = nil
        notes = []
        let picture = owner?.snapshot?()
        owner?.pauseCamera?()
        save(picture: picture)
    }

    /// No LiDAR, or measured with a ruler: type the sizes.
    func typeIn() {
        if let b = box { boxOut = BoxOut(width: b.width, length: b.length, height: b.height ?? 50, wall: b.wall) }
        locked = true
        manual = true
        spread = nil
        done = nil
        error = nil
        notes = []
        owner?.pauseCamera?()
        save(picture: nil)
    }

    func measureAgain() {
        reset()
        owner?.resumeCamera?()
    }

    // MARK: Choices

    func setValue(_ p: SpaceParam, _ v: Double) {
        let s = p.step
        values[p] = min(p.range.upperBound, max(p.range.lowerBound, (v / s).rounded() * s))
        changed()
    }

    func setBox(width: Double? = nil, length: Double? = nil, height: Double? = nil) {
        if let width { boxOut.width = max(10, min(1000, width)) }
        if let length { boxOut.length = max(10, min(1000, length)) }
        if let height { boxOut.height = max(0, min(500, height)) }
        changed()
    }

    func setBoxMake(_ m: BoxMake) {
        boxMake = m
        changed()
    }

    func setBins(_ i: Int) {
        bins = i
        changed()
    }

    private func changed() {
        done = nil
        notes = []
        guard let id = savedId else { return }
        let params = paramsJSON()
        let box = boxOut, boxMake = self.boxMake
        owner?.store.update(id) {
            $0.box = box
            $0.boxMake = boxMake
            $0.text = Self.text(box)
            $0.spaceParams = params
        }
    }

    func paramsJSON() -> [String: Double] {
        var out: [String: Double] = [:]
        for p in boxMake.uses { out[p.key] = values[p] ?? p.defaultValue }
        out["cols"] = values[.cols] ?? 3
        out["rows"] = values[.rows] ?? 2
        let b = binSizes[min(max(0, bins), binSizes.count - 1)]
        out["binx"] = Double(b.x)
        out["biny"] = Double(b.y)
        return out
    }

    static func text(_ b: BoxOut) -> String {
        "Boks \(mm(b.width)) × \(mm(b.length))" + (b.height > 0 ? " × \(mm(b.height))" : "") + " mm"
    }

    /// The height the dividers or insert get when «auto» (as the server: 80 % / 1 mm under the rim).
    var autoHeight: Double {
        if boxMake == .insert { return boxOut.height > 0 ? max(5, boxOut.height - 1) : 30 }
        return boxOut.height > 0 ? max(5, (boxOut.height * 0.8 * 10).rounded() / 10) : 30
    }

    // MARK: Saving and making

    private func save(picture: UIImage?) {
        guard let store = owner?.store else { return }
        savedId = store.add(SavedMeasurement(box: boxOut, boxMake: boxMake, spaceParams: paramsJSON(), text: Self.text(boxOut), uncertainty: spread), image: picture)
    }

    /// What goes to the server for a measurement (also for one kept on the phone).
    static func body(_ m: SavedMeasurement) -> [String: Any]? {
        guard let box = m.box else { return nil }
        return ["type": "box", "box": box.json, "make": (m.boxMake ?? .dividers).rawValue, "params": m.spaceParams ?? [:]]
    }

    private var currentBody: [String: Any] {
        ["type": "box", "box": boxOut.json, "make": boxMake.rawValue, "params": paramsJSON()]
    }

    func commit() {
        guard let owner else { return }
        let saved = savedId.flatMap { id in owner.store.items.first { $0.id == id } }
        working = true
        error = nil
        owner.sendSpace(currentBody, photo: saved.flatMap { owner.store.photoData($0) }) { [weak self] r in
            guard let self else { return }
            self.working = false
            switch r {
            case .success(let answer):
                self.haptic.notificationOccurred(.success)
                self.done = "\(answer.label) er laget i CadSHAPE."
                self.notes = answer.notes
                if let id = self.savedId { owner.store.update(id) { $0.sentAt = Date() } }
            case .failure(let e):
                self.haptic.notificationOccurred(.error)
                self.error = e.message + " Målingen er lagret på telefonen."
            }
        }
    }
}
