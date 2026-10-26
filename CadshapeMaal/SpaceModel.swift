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
        case .gridfinity: return "Gridfinity-bunnplate"
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
        case .gridfinity: return "42 mm-ruter som fyller bunnen – Gridfinity-bokser klikker på plass"
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
}

/// What to make for something lying on a table.
enum ObjectMake: String, CaseIterable, Identifiable, Codable {
    case tray, gridfinity
    var id: String { rawValue }
    var label: String { self == .tray ? "Brett med lomme" : "Gridfinity-boks med lomme" }
    var short: String { self == .tray ? "Brett" : "Gridfinity" }
    var symbol: String { self == .tray ? "rectangle.inset.filled" : "square.grid.3x3.square" }
    var hint: String {
        self == .tray
            ? "En lomme med gjenstandens form, og et grep så du får tak i den – til skuffen eller verktøyveggen"
            : "Gridfinity-boks med lommen skåret ut – står i bunnplaten"
    }
    var uses: [SpaceParam] { self == .tray ? [.clearanceObject, .depth, .rim, .notch] : [.clearanceObject, .depth, .notch] }
}

/// A number to set for the box or object parts (key as on the server).
enum SpaceParam: String, CaseIterable, Identifiable {
    case cols, rows, height, thickness, clearance, clearanceObject, depth, rim, notch
    var id: String { rawValue }
    /// The key the server knows.
    var key: String { self == .clearanceObject ? "clearance" : rawValue }
    var label: String {
        switch self {
        case .cols: return "Rom i bredden"
        case .rows: return "Rom i lengden"
        case .height: return "Høyde"
        case .thickness: return "Veggtykkelse"
        case .clearance: return "Klaring mot veggene"
        case .clearanceObject: return "Klaring rundt"
        case .depth: return "Dybde på lommen"
        case .rim: return "Kant rundt"
        case .notch: return "Grep for fingeren"
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .cols, .rows: return 1...12
        case .height: return 0...400
        case .thickness: return 0.8...5
        case .clearance, .clearanceObject: return 0...5
        case .depth: return 0...200
        case .rim: return 1.2...40
        case .notch: return 0...1
        }
    }
    var step: Double {
        switch self {
        case .cols, .rows, .height, .depth, .rim, .notch: return 1
        case .thickness: return 0.2
        case .clearance, .clearanceObject: return 0.1
        }
    }
    var defaultValue: Double {
        switch self {
        case .cols: return 3
        case .rows: return 2
        case .height, .depth: return 0
        case .thickness: return 1.6
        case .clearance: return 0.5
        case .clearanceObject: return 1
        case .rim: return 6
        case .notch: return 1
        }
    }
    /// Whole numbers without a unit (rooms), a switch (notch), or mm.
    var isCount: Bool { self == .cols || self == .rows }
    var isSwitch: Bool { self == .notch }
    /// What 0 means.
    var zeroText: String? { self == .height || self == .depth ? "auto" : nil }
}

/// One measuring step's result, for the steady check and the lock.
private struct BoxSample {
    var width: Double
    var length: Double
    var height: Double?
    var wall: Double?
}

/// Measuring the inside of a box, or something on a table, with the LiDAR point cloud (many frames
/// together), and what to make from it. The camera view feeds `update`; the PC gets the parts on «Lag».
final class SpaceModel: ObservableObject {
    // Live
    @Published var box: BoxFit?
    @Published var object: ObjectFit?
    /// The floor of the box, or the object's footprint, on screen.
    @Published var polygonOnScreen: [CGPoint] = []
    @Published var steadiness = 0.0
    @Published var hint = ""

    // Locked (or typed in)
    @Published var locked = false
    @Published var manual = false
    @Published var boxOut = BoxOut(width: 150, length: 100, height: 50, wall: nil)
    @Published var objectOut: ObjectOut?
    @Published var boxMake: BoxMake = .dividers
    @Published var objectMake: ObjectMake = .tray
    @Published var values: [SpaceParam: Double] = Dictionary(uniqueKeysWithValues: SpaceParam.allCases.map { ($0, $0.defaultValue) })
    @Published var spread: Double?
    @Published var working = false
    @Published var done: String?
    @Published var notes: [String] = []
    @Published var error: String?

    /// Bumped to tell the camera to start the point cloud afresh.
    private(set) var generation = 0

    weak var owner: MeasureModel?
    private var boxes: [BoxSample] = []
    private var objects: [ObjectFit] = []
    private var steadySince: Date?
    private var savedId: UUID?
    private let haptic = UINotificationFeedbackGenerator()

    var isBox: Bool { owner?.mode == .box }

    // MARK: Live

    func reset() {
        generation += 1
        box = nil
        object = nil
        polygonOnScreen = []
        steadiness = 0
        boxes = []
        objects = []
        steadySince = nil
        locked = false
        manual = false
        objectOut = nil
        spread = nil
        done = nil
        notes = []
        error = nil
        working = false
        savedId = nil
        hint = isBox ? "Hold telefonen over boksen og sikt krysset på bunnen" : "Legg tingen på et bord og sikt krysset på den"
    }

    /// A new fit from the camera (main thread).
    func update(box fit: BoxFit?, screen: [CGPoint]) {
        guard !locked else { return }
        box = fit
        polygonOnScreen = screen
        guard let fit else {
            boxes.removeAll()
            steadiness = 0
            steadySince = nil
            hint = "Finner ikke bunnen og veggene. Sikt krysset på bunnen av boksen, 25–60 cm over den."
            return
        }
        boxes.append(BoxSample(width: fit.width, length: fit.length, height: fit.height, wall: fit.wall))
        if boxes.count > 8 { boxes.removeFirst(boxes.count - 8) }
        steadiness = agreement(boxes.map(\.width), boxes.map(\.length)) * (fit.allWallsSeen ? 1 : 0.6)
        if !fit.allWallsSeen {
            hint = "Ser ikke alle fire veggene. Hold telefonen mer midt over boksen."
        } else if fit.height == nil {
            hint = "Ser ikke kanten øverst. Løft telefonen litt så hele kanten er med."
        } else {
            hint = steadiness < 0.7 ? "Hold stille …" : ((owner?.autoLock ?? false) ? "Stødig – låser …" : "Stødig – trykk «Lås målet».")
        }
        checkAuto(ready: fit.allWallsSeen && fit.height != nil)
    }

    func update(object fit: ObjectFit?, screen: [CGPoint]) {
        guard !locked else { return }
        object = fit
        polygonOnScreen = screen
        guard let fit else {
            objects.removeAll()
            steadiness = 0
            steadySince = nil
            hint = "Finner ikke tingen. Legg den på et ryddig bord og sikt krysset midt på den, 25–50 cm over."
            return
        }
        objects.append(fit)
        if objects.count > 8 { objects.removeFirst(objects.count - 8) }
        steadiness = agreement(objects.map(\.width), objects.map(\.length))
        hint = steadiness < 0.7 ? "Hold stille …" : ((owner?.autoLock ?? false) ? "Stødig – låser …" : "Stødig – trykk «Lås målet».")
        checkAuto(ready: true)
    }

    func noLidar() {
        hint = "Måling av bokser og ting trenger LiDAR (iPhone Pro). Skriv inn målene i stedet."
    }

    /// 0…1: how much the last sizes agree (within 1 % is steady).
    private func agreement(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count >= 3 else { return 0 }
        func rel(_ v: [Double]) -> Double {
            let m = median(v)
            return median(v.map { abs($0 - m) }) / max(1, m)
        }
        return max(0, min(1, 1 - max(rel(a), rel(b)) / 0.01)) * min(1, Double(a.count) / 5)
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

    var canLock: Bool { isBox ? !boxes.isEmpty : !objects.isEmpty }

    // MARK: Locking

    func lock() {
        if isBox {
            guard !boxes.isEmpty else { return }
            let m = BoxOut(
                width: median(boxes.map(\.width)),
                length: median(boxes.map(\.length)),
                height: boxes.compactMap(\.height).isEmpty ? 0 : median(boxes.compactMap(\.height)),
                wall: boxes.compactMap(\.wall).isEmpty ? nil : median(boxes.compactMap(\.wall))
            )
            boxOut = m
            spread = box?.spread
            // Dividers a little lower than the box by default (the server's «auto» does the same).
        } else {
            // The frame whose size is nearest the middle of the last ones.
            guard !objects.isEmpty else { return }
            let mw = median(objects.map(\.width)), ml = median(objects.map(\.length))
            guard let best = objects.min(by: { abs($0.width - mw) + abs($0.length - ml) < abs($1.width - mw) + abs($1.length - ml) }) else { return }
            objectOut = ObjectOut(outline: best.outline.map { [$0.x, $0.y] }, width: best.width, length: best.length, height: median(objects.map(\.height)))
            spread = 2
        }
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

    /// No LiDAR, or measured with a ruler: type the inside of the box.
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

    func setObjectMake(_ m: ObjectMake) {
        objectMake = m
        changed()
    }

    private func changed() {
        done = nil
        notes = []
        guard let id = savedId else { return }
        let params = paramsJSON()
        let isBox = self.isBox
        let box = boxOut, boxMake = self.boxMake, objectMake = self.objectMake
        owner?.store.update(id) {
            if isBox {
                $0.box = box
                $0.boxMake = boxMake
                $0.text = Self.text(box)
            } else {
                $0.objectMake = objectMake
            }
            $0.spaceParams = params
        }
    }

    func paramsJSON() -> [String: Double] {
        var out: [String: Double] = [:]
        let uses = isBox ? boxMake.uses : objectMake.uses
        for p in uses { out[p.key] = values[p] ?? p.defaultValue }
        if isBox { out["cols"] = values[.cols] ?? 3; out["rows"] = values[.rows] ?? 2 }
        return out
    }

    static func text(_ b: BoxOut) -> String {
        "Boks \(mm(b.width)) × \(mm(b.length))" + (b.height > 0 ? " × \(mm(b.height))" : "") + " mm"
    }

    static func text(_ o: ObjectOut) -> String {
        "Gjenstand \(mm(o.width)) × \(mm(o.length)) mm, \(mm(o.height)) mm høy"
    }

    /// The height the dividers or insert get when «auto» (as the server: 80 % / 1 mm under the rim).
    var autoHeight: Double {
        if boxMake == .insert { return boxOut.height > 0 ? max(5, boxOut.height - 1) : 30 }
        return boxOut.height > 0 ? max(5, (boxOut.height * 0.8 * 10).rounded() / 10) : 30
    }

    // MARK: Saving and making

    private func save(picture: UIImage?) {
        guard let store = owner?.store else { return }
        if isBox {
            savedId = store.add(SavedMeasurement(box: boxOut, boxMake: boxMake, spaceParams: paramsJSON(), text: Self.text(boxOut), uncertainty: spread), image: picture)
        } else if let o = objectOut {
            savedId = store.add(SavedMeasurement(object: o, objectMake: objectMake, spaceParams: paramsJSON(), text: Self.text(o), uncertainty: spread), image: picture)
        }
    }

    /// What goes to the server for a measurement (also for one kept on the phone).
    static func body(box: BoxOut?, boxMake: BoxMake?, object: ObjectOut?, objectMake: ObjectMake?, params: [String: Double]) -> [String: Any]? {
        if let box { return ["type": "box", "box": box.json, "make": (boxMake ?? .dividers).rawValue, "params": params] }
        if let object { return ["type": "object", "object": object.json, "make": (objectMake ?? .tray).rawValue, "params": params] }
        return nil
    }

    func commit() {
        guard let owner else { return }
        if owner.isDemo {
            done = "\(isBox ? boxMake.label : objectMake.label) er laget i CadSHAPE (demo)."
            return
        }
        guard let body = Self.body(box: isBox ? boxOut : nil, boxMake: boxMake, object: isBox ? nil : objectOut, objectMake: objectMake, params: paramsJSON()) else { return }
        let saved = savedId.flatMap { id in owner.store.items.first { $0.id == id } }
        working = true
        error = nil
        owner.sendSpace(body, photo: saved.flatMap { owner.store.photoData($0) }) { [weak self] r in
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
