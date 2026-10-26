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
}

/// What to make for things lying on a table.
enum ObjectMake: String, CaseIterable, Identifiable, Codable {
    case tray, gridfinity
    var id: String { rawValue }
    var label: String { self == .tray ? "Brett med lomme" : "Gridfinity-boks med lomme" }
    var short: String { self == .tray ? "Brett" : "Gridfinity" }
    var symbol: String { self == .tray ? "rectangle.inset.filled" : "square.grid.3x3.square" }
    var hint: String {
        self == .tray
            ? "Lommer med tingenes form, og et grep så du får tak i dem – til skuffen eller verktøyveggen"
            : "Gridfinity-boks med lommene skåret ut og stablekant – står i bunnplaten"
    }
    var uses: [SpaceParam] { self == .tray ? [.clearanceObject, .depth, .rim, .notch] : [.clearanceObject, .depth, .notch] }
}

/// What to make for a pipe or rod.
enum PipeMake: String, CaseIterable, Identifiable, Codable {
    case clamp, adapter, cap
    var id: String { rawValue }
    var label: String {
        switch self {
        case .clamp: return "Rørklemme"
        case .adapter: return "Overgang"
        case .cap: return "Endelokk"
        }
    }
    var symbol: String {
        switch self {
        case .clamp: return "rectangle.and.hand.point.up.left"
        case .adapter: return "arrow.left.and.right.circle"
        case .cap: return "capsule.portrait"
        }
    }
    var hint: String {
        switch self {
        case .clamp: return "Omega-klemme med to skruer, klemmer røret litt"
        case .adapter: return "Muffe mellom to rørstørrelser – mål den andre diameteren også"
        case .cap: return "Kopp som tres over enden av røret"
        }
    }
    var uses: [SpaceParam] { self == .clamp ? [] : [.pipeClearance, .pipeWall, .pipeLength] }
}

/// What to fill a gap with.
enum GapMake: String, CaseIterable, Identifiable, Codable {
    case shim, wedge, set
    var id: String { rawValue }
    var label: String {
        switch self {
        case .shim: return "Mellomlegg"
        case .wedge: return "Kile"
        case .set: return "Prøvesett"
        }
    }
    var symbol: String {
        switch self {
        case .shim: return "rectangle.compress.vertical"
        case .wedge: return "triangle"
        case .set: return "square.stack.3d.up"
        }
    }
    var hint: String {
        switch self {
        case .shim: return "Flat plate like tykk som spalten"
        case .wedge: return "Kile med den målte vinkelen – spalten er tykkelsen på midten"
        case .set: return "Fem mellomlegg med 0,5 mm mellom, så du kan prøve deg fram"
        }
    }
    var uses: [SpaceParam] { [.gapLength, .gapWidth] }
}

/// A number to set for the parts (key as on the server).
enum SpaceParam: String, CaseIterable, Identifiable {
    case cols, rows, height, thickness, clearance, clearanceObject, depth, rim, notch
    case pipeClearance, pipeWall, pipeLength, gapLength, gapWidth
    var id: String { rawValue }
    /// The key the server knows.
    var key: String {
        switch self {
        case .clearanceObject, .pipeClearance: return "clearance"
        case .pipeWall: return "wall"
        case .pipeLength, .gapLength: return "length"
        case .gapWidth: return "width"
        default: return rawValue
        }
    }
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
        case .pipeClearance: return "Klaring rundt røret"
        case .pipeWall: return "Veggtykkelse"
        case .pipeLength: return "Lengde over røret"
        case .gapLength: return "Lengde"
        case .gapWidth: return "Bredde"
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
        case .pipeClearance: return 0...3
        case .pipeWall: return 1.2...10
        case .pipeLength: return 5...150
        case .gapLength, .gapWidth: return 5...200
        }
    }
    var step: Double {
        switch self {
        case .cols, .rows, .height, .depth, .rim, .notch, .pipeLength, .gapLength, .gapWidth: return 1
        case .thickness: return 0.2
        case .clearance, .clearanceObject, .pipeClearance: return 0.1
        case .pipeWall: return 0.4
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
        case .pipeClearance: return 0.3
        case .pipeWall: return 2.4
        case .pipeLength: return 25
        case .gapLength: return 60
        case .gapWidth: return 30
        }
    }
    /// Whole numbers without a unit (rooms), a switch (notch), or mm.
    var isCount: Bool { self == .cols || self == .rows }
    var isSwitch: Bool { self == .notch }
    /// What 0 means.
    var zeroText: String? { self == .height || self == .depth ? "auto" : nil }
}

/// Gridfinity bins to fill a drawer with (grid units; 0 × 0 = none).
let binSizes: [(x: Int, y: Int)] = [(0, 0), (1, 1), (2, 1), (2, 2), (3, 1), (3, 2)]

/// Common outside diameters (as STANDARD_PIPES on the server).
let standardPipes: [Double] = [6, 8, 10, 12, 15, 16, 18, 20, 22, 25, 28, 32, 35, 40, 42, 50, 54, 63, 75, 90, 110, 125, 160]

func nearPipes(_ d: Double) -> [Double] {
    standardPipes.filter { abs($0 - d) <= $0 * 0.04 }.sorted { abs($0 - d) < abs($1 - d) }
}

/// One measuring step's result, for the steady check and the lock.
private struct BoxSample {
    var width: Double
    var length: Double
    var height: Double?
    var wall: Double?
}

/// A surface found round the cross-hair (gap mode).
struct SurfaceHit {
    var plane: Plane
    var point: V3
}

/// Measuring with the LiDAR point cloud (many frames together): the inside of a box, things on a
/// table, a pipe, or the gap between two surfaces – and what to make from it. The camera view feeds
/// `update`; the PC gets the parts on «Lag».
final class SpaceModel: ObservableObject {
    // Live
    @Published var box: BoxFit?
    @Published var object: ObjectFit?
    @Published var pipe: CylinderFit?
    @Published var surface: SurfaceHit?
    /// The box's floor, the object's footprint, the pipe's outline or the surface, on screen.
    @Published var polygonOnScreen: [CGPoint] = []
    @Published var steadiness = 0.0
    @Published var hint = ""

    // Locked (or typed in)
    @Published var locked = false
    @Published var manual = false
    @Published var boxOut = BoxOut(width: 150, length: 100, height: 50, wall: nil)
    @Published var objectOut: ObjectOut?
    /// Things already in the tray, before the current one.
    @Published var objectsBefore: [ObjectOut] = []
    @Published var pipeOut = PipeOut(diameter: 32, second: nil)
    /// Measuring the pipe's second diameter (for an adapter).
    @Published var measuringSecond = false
    /// Gap mode: the first surface, once chosen.
    @Published var firstSurface: SurfaceHit?
    @Published var gapOut = GapOut(gap: 5, angle: 0)
    @Published var boxMake: BoxMake = .dividers
    @Published var objectMake: ObjectMake = .tray
    @Published var pipeMake: PipeMake = .clamp
    @Published var gapMake: GapMake = .shim
    @Published var bins = 2
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
    private var diameters: [Double] = []
    private var surfaces: [SurfaceHit] = []
    private var steadySince: Date?
    private var savedId: UUID?
    private let haptic = UINotificationFeedbackGenerator()
    private let tap = UIImpactFeedbackGenerator(style: .medium)

    var mode: MeasureMode { owner?.mode ?? .box }
    var isBox: Bool { mode == .box }

    // MARK: Live

    /// Back to measuring, keeping the things already in the tray and the pipe's first diameter.
    private func resetLive() {
        generation += 1
        box = nil
        object = nil
        pipe = nil
        surface = nil
        polygonOnScreen = []
        steadiness = 0
        boxes = []
        objects = []
        diameters = []
        surfaces = []
        steadySince = nil
        locked = false
        manual = false
        done = nil
        notes = []
        error = nil
        working = false
        hint = startHint
    }

    func reset() {
        resetLive()
        objectOut = nil
        objectsBefore = []
        measuringSecond = false
        firstSurface = nil
        spread = nil
        savedId = nil
        hint = startHint
    }

    private var startHint: String {
        switch mode {
        case .box: return "Hold telefonen over boksen og sikt krysset på bunnen"
        case .object: return objectsBefore.isEmpty ? "Legg tingen på et bord og sikt krysset på den" : "Sikt på neste ting"
        case .pipe: return measuringSecond ? "Sikt på det andre røret, fra siden" : "Sikt på røret fra siden, 25–50 cm unna"
        case .gap: return firstSurface == nil ? "Sikt på den første flaten og trykk «Flate 1»" : "Sikt på den andre flaten og trykk «Flate 2»"
        default: return ""
        }
    }

    /// A new fit from the camera (main thread).
    func update(box fit: BoxFit?, screen: [CGPoint]) {
        guard !locked else { return }
        box = fit
        polygonOnScreen = screen
        guard let fit else {
            lost("Finner ikke bunnen og veggene. Sikt krysset på bunnen av boksen, 25–60 cm over den.")
            return
        }
        boxes.append(BoxSample(width: fit.width, length: fit.length, height: fit.height, wall: fit.wall))
        if boxes.count > 8 { boxes.removeFirst(boxes.count - 8) }
        steadiness = agreement([boxes.map(\.width), boxes.map(\.length)]) * (fit.allWallsSeen ? 1 : 0.6)
        if !fit.allWallsSeen {
            hint = "Ser ikke alle fire veggene. Hold telefonen mer midt over boksen."
        } else if fit.height == nil {
            hint = "Ser ikke kanten øverst. Løft telefonen litt så hele kanten er med."
        } else {
            hint = steadyHint
        }
        checkAuto(ready: fit.allWallsSeen && fit.height != nil)
    }

    func update(object fit: ObjectFit?, screen: [CGPoint]) {
        guard !locked else { return }
        object = fit
        polygonOnScreen = screen
        guard let fit else {
            lost("Finner ikke tingen. Legg den på et ryddig bord og sikt krysset midt på den, 25–50 cm over.")
            return
        }
        objects.append(fit)
        if objects.count > 8 { objects.removeFirst(objects.count - 8) }
        steadiness = agreement([objects.map(\.width), objects.map(\.length)])
        hint = steadyHint
        checkAuto(ready: true)
    }

    func update(pipe fit: CylinderFit?, screen: [CGPoint]) {
        guard !locked else { return }
        pipe = fit
        polygonOnScreen = screen
        guard let fit else {
            lost("Finner ikke noe rundt i krysset. Sikt midt på røret fra siden, med litt luft bak det.")
            return
        }
        diameters.append(fit.diameter)
        if diameters.count > 8 { diameters.removeFirst(diameters.count - 8) }
        steadiness = agreement([diameters])
        hint = fit.residual > 2 ? "Ujevn flate – er det et rør? Gå litt nærmere." : steadyHint
        checkAuto(ready: fit.residual <= 2)
    }

    func update(surface hit: SurfaceHit?, screen: [CGPoint]) {
        guard !locked else { return }
        surface = hit
        polygonOnScreen = screen
        guard let hit else {
            lost("Finner ingen flate i krysset. Gå litt nærmere.")
            return
        }
        surfaces.append(hit)
        if surfaces.count > 6 { surfaces.removeFirst(surfaces.count - 6) }
        steadiness = min(1, Double(surfaces.count) / 4)
        hint = startHint
    }

    private func lost(_ text: String) {
        boxes.removeAll()
        objects.removeAll()
        diameters.removeAll()
        surfaces.removeAll()
        steadiness = 0
        steadySince = nil
        hint = text
    }

    private var steadyHint: String {
        steadiness < 0.7 ? "Hold stille …" : ((owner?.autoLock ?? false) ? "Stødig – låser …" : "Stødig – trykk «Lås målet».")
    }

    func noLidar() {
        hint = "Dette trenger LiDAR (iPhone Pro). Skriv inn målene i stedet."
    }

    /// 0…1: how much the last sizes agree (within 1 % is steady).
    private func agreement(_ series: [[Double]]) -> Double {
        guard let first = series.first, first.count >= 3 else { return 0 }
        func rel(_ v: [Double]) -> Double {
            let m = median(v)
            return median(v.map { abs($0 - m) }) / max(1, m)
        }
        let worst = series.map(rel).max() ?? 1
        return max(0, min(1, 1 - worst / 0.01)) * min(1, Double(first.count) / 5)
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

    var canLock: Bool {
        switch mode {
        case .box: return !boxes.isEmpty
        case .object: return !objects.isEmpty
        case .pipe: return !diameters.isEmpty
        default: return false
        }
    }

    // MARK: Locking

    func lock() {
        switch mode {
        case .box:
            guard !boxes.isEmpty else { return }
            boxOut = BoxOut(
                width: median(boxes.map(\.width)),
                length: median(boxes.map(\.length)),
                height: boxes.compactMap(\.height).isEmpty ? 0 : median(boxes.compactMap(\.height)),
                wall: boxes.compactMap(\.wall).isEmpty ? nil : median(boxes.compactMap(\.wall))
            )
            spread = box?.spread
        case .object:
            // The frame whose size is nearest the middle of the last ones.
            guard !objects.isEmpty else { return }
            let mw = median(objects.map(\.width)), ml = median(objects.map(\.length))
            guard let best = objects.min(by: { abs($0.width - mw) + abs($0.length - ml) < abs($1.width - mw) + abs($1.length - ml) }) else { return }
            objectOut = ObjectOut(outline: best.outline.map { [$0.x, $0.y] }, width: best.width, length: best.length, height: median(objects.map(\.height)))
            spread = best.sharpened ? 0.7 : 2
        case .pipe:
            guard !diameters.isEmpty else { return }
            let d = (median(diameters) * 10).rounded() / 10
            if measuringSecond {
                pipeOut.second = d
                pipeMake = .adapter
            } else {
                pipeOut = PipeOut(diameter: d, second: nil)
            }
            measuringSecond = false
            spread = max(0.5, (pipe?.residual ?? 1) * 1.5)
        default:
            return
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

    /// Gap mode: the surface in the cross-hair is the first (then the second, which locks).
    func takeSurface() {
        guard let hit = surfaces.last else { return }
        tap.impactOccurred()
        guard let first = firstSurface else {
            firstSurface = hit
            surfaces = []
            steadiness = 0
            hint = startHint
            return
        }
        let g = gapBetween((first.plane, first.point), (hit.plane, hit.point))
        gapOut = GapOut(gap: g.gapMM, angle: g.angle)
        if g.angle >= 2 { gapMake = .wedge }
        spread = 1.5
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

    var canTakeSurface: Bool { surface != nil && !surfaces.isEmpty }

    /// No LiDAR, or measured with a ruler: type the sizes.
    func typeIn() {
        switch mode {
        case .box:
            if let b = box { boxOut = BoxOut(width: b.width, length: b.length, height: b.height ?? 50, wall: b.wall) }
        case .pipe:
            if let p = pipe { pipeOut = PipeOut(diameter: p.diameter, second: nil) }
        case .gap:
            break
        default:
            return
        }
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

    /// Another thing for the same tray: the one just measured stays, measure the next.
    func addAnotherObject() {
        guard let o = objectOut else { return }
        objectsBefore.append(o)
        objectOut = nil
        resetLive()
        owner?.resumeCamera?()
    }

    func removeObject(at i: Int) {
        var all = allObjects
        guard all.indices.contains(i) else { return }
        all.remove(at: i)
        objectOut = all.last
        objectsBefore = Array(all.dropLast())
        changed()
    }

    var allObjects: [ObjectOut] { objectsBefore + (objectOut.map { [$0] } ?? []) }

    /// Pipe: measure the second diameter (for an adapter).
    func measureSecond() {
        measuringSecond = true
        resetLive()
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

    func setPipe(diameter: Double? = nil, second: Double? = nil) {
        if let diameter { pipeOut.diameter = max(2, min(300, diameter)) }
        if let second { pipeOut.second = max(2, min(300, second)) }
        changed()
    }

    func setGap(_ gap: Double? = nil, angle: Double? = nil) {
        if let gap { gapOut.gap = max(0.2, min(200, gap)) }
        if let angle { gapOut.angle = max(0, min(45, angle)) }
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

    func setPipeMake(_ m: PipeMake) {
        pipeMake = m
        changed()
    }

    func setGapMake(_ m: GapMake) {
        gapMake = m
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
        let mode = self.mode
        let box = boxOut, boxMake = self.boxMake, objectMake = self.objectMake
        let objects = allObjects
        let pipe = pipeOut, pipeMake = self.pipeMake, gap = gapOut, gapMake = self.gapMake
        owner?.store.update(id) {
            switch mode {
            case .box:
                $0.box = box
                $0.boxMake = boxMake
                $0.text = Self.text(box)
            case .object:
                $0.object = objects.first
                $0.objects = objects.count > 1 ? objects : nil
                $0.objectMake = objectMake
                $0.text = Self.text(objects)
            case .pipe:
                $0.pipe = pipe
                $0.pipeMake = pipeMake
                $0.text = Self.text(pipe)
            case .gap:
                $0.gap = gap
                $0.gapMake = gapMake
                $0.text = Self.text(gap)
            default:
                break
            }
            $0.spaceParams = params
        }
    }

    func paramsJSON() -> [String: Double] {
        var out: [String: Double] = [:]
        let uses: [SpaceParam]
        switch mode {
        case .box: uses = boxMake.uses
        case .object: uses = objectMake.uses
        case .pipe: uses = pipeMake.uses
        case .gap: uses = gapMake.uses
        default: uses = []
        }
        for p in uses { out[p.key] = values[p] ?? p.defaultValue }
        if mode == .box {
            out["cols"] = values[.cols] ?? 3
            out["rows"] = values[.rows] ?? 2
            let b = binSizes[min(max(0, bins), binSizes.count - 1)]
            out["binx"] = Double(b.x)
            out["biny"] = Double(b.y)
        }
        return out
    }

    static func text(_ b: BoxOut) -> String {
        "Boks \(mm(b.width)) × \(mm(b.length))" + (b.height > 0 ? " × \(mm(b.height))" : "") + " mm"
    }

    static func text(_ list: [ObjectOut]) -> String {
        guard let o = list.first else { return "Gjenstand" }
        if list.count > 1 { return "\(list.count) ting: " + list.map { "\(mm($0.width, digits: 0)) × \(mm($0.length, digits: 0))" }.joined(separator: ", ") + " mm" }
        return "Gjenstand \(mm(o.width)) × \(mm(o.length)) mm, \(mm(o.height)) mm høy"
    }

    static func text(_ p: PipeOut) -> String {
        "Rør Ø \(mm(p.diameter))" + (p.second.map { " og Ø \(mm($0))" } ?? "") + " mm"
    }

    static func text(_ g: GapOut) -> String {
        "Spalte \(mm(g.gap)) mm" + (g.angle >= 0.5 ? ", \(mm(g.angle))° skjev" : "")
    }

    /// The height the dividers or insert get when «auto» (as the server: 80 % / 1 mm under the rim).
    var autoHeight: Double {
        if boxMake == .insert { return boxOut.height > 0 ? max(5, boxOut.height - 1) : 30 }
        return boxOut.height > 0 ? max(5, (boxOut.height * 0.8 * 10).rounded() / 10) : 30
    }

    // MARK: Saving and making

    private func save(picture: UIImage?) {
        guard let store = owner?.store else { return }
        let params = paramsJSON()
        // More things for the same tray: the saved measurement grows.
        if mode == .object, let id = savedId, !objectsBefore.isEmpty {
            let objects = allObjects
            store.update(id) {
                $0.object = objects.first
                $0.objects = objects
                $0.text = Self.text(objects)
            }
            return
        }
        switch mode {
        case .box:
            savedId = store.add(SavedMeasurement(box: boxOut, boxMake: boxMake, spaceParams: params, text: Self.text(boxOut), uncertainty: spread), image: picture)
        case .object:
            if let o = objectOut {
                savedId = store.add(SavedMeasurement(object: o, objectMake: objectMake, spaceParams: params, text: Self.text([o]), uncertainty: spread), image: picture)
            }
        case .pipe:
            if let id = savedId, pipeOut.second != nil {
                let pipe = pipeOut
                store.update(id) {
                    $0.pipe = pipe
                    $0.pipeMake = .adapter
                    $0.text = Self.text(pipe)
                }
            } else {
                savedId = store.add(SavedMeasurement(pipe: pipeOut, pipeMake: pipeMake, spaceParams: params, text: Self.text(pipeOut), uncertainty: spread), image: picture)
            }
        case .gap:
            savedId = store.add(SavedMeasurement(gap: gapOut, gapMake: gapMake, spaceParams: params, text: Self.text(gapOut), uncertainty: spread), image: picture)
        default:
            break
        }
    }

    /// What goes to the server for a measurement (also for one kept on the phone).
    static func body(_ m: SavedMeasurement) -> [String: Any]? {
        let params = m.spaceParams ?? [:]
        if let box = m.box { return ["type": "box", "box": box.json, "make": (m.boxMake ?? .dividers).rawValue, "params": params] }
        if let object = m.object {
            let list = m.objects ?? [object]
            return ["type": "object", "objects": list.map(\.json), "make": (m.objectMake ?? .tray).rawValue, "params": params]
        }
        if let pipe = m.pipe { return ["type": "pipe", "pipe": pipe.json, "make": (m.pipeMake ?? .clamp).rawValue, "params": params] }
        if let gap = m.gap { return ["type": "gap", "gap": gap.json, "make": (m.gapMake ?? .shim).rawValue, "params": params] }
        return nil
    }

    private var currentBody: [String: Any]? {
        let params = paramsJSON()
        switch mode {
        case .box: return ["type": "box", "box": boxOut.json, "make": boxMake.rawValue, "params": params]
        case .object:
            let list = allObjects
            return list.isEmpty ? nil : ["type": "object", "objects": list.map(\.json), "make": objectMake.rawValue, "params": params]
        case .pipe: return ["type": "pipe", "pipe": pipeOut.json, "make": pipeMake.rawValue, "params": params]
        case .gap: return ["type": "gap", "gap": gapOut.json, "make": gapMake.rawValue, "params": params]
        default: return nil
        }
    }

    var currentLabel: String {
        switch mode {
        case .box: return boxMake.label
        case .object: return objectMake.label
        case .pipe: return pipeMake.label
        case .gap: return gapMake.label
        default: return "Delen"
        }
    }

    func commit() {
        guard let owner else { return }
        if owner.isDemo {
            done = "\(currentLabel) er laget i CadSHAPE (demo)."
            return
        }
        if mode == .pipe && pipeMake == .adapter && pipeOut.second == nil {
            error = "Mål den andre diameteren først (eller skriv den inn)."
            return
        }
        guard let body = currentBody else { return }
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
