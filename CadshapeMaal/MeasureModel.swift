import ARKit
import Combine
import Foundation
import HoleKit
import UIKit

/// What is measured: one hole, a pattern of holes (screw holes) with their places, the inside of a
/// box or drawer, or something lying on a table (the last two with the LiDAR point cloud).
enum MeasureMode: String, CaseIterable, Identifiable {
    case single, pattern, box, object, pipe, gap
    var id: String { rawValue }
    var label: String {
        switch self {
        case .single: return "Ett hull"
        case .pattern: return "Hullmønster"
        case .box: return "Inni boks"
        case .object: return "Gjenstand"
        case .pipe: return "Rør"
        case .gap: return "Spalte"
        }
    }
    var short: String {
        switch self {
        case .single: return "Hull"
        case .pattern: return "Mønster"
        case .box: return "Boks"
        case .object: return "Ting"
        case .pipe: return "Rør"
        case .gap: return "Spalte"
        }
    }
    var symbol: String {
        switch self {
        case .single: return "circle.dashed"
        case .pattern: return "circle.grid.2x2"
        case .box: return "shippingbox"
        case .object: return "wrench.and.screwdriver"
        case .pipe: return "cylinder"
        case .gap: return "arrow.up.and.down.square"
        }
    }
    /// Measured from the point cloud, not a hole in the picture.
    var isSpace: Bool { self == .box || self == .object || self == .pipe || self == .gap }
}

/// A hole added to the pattern: where it is in the room and its shape.
struct PatternEntry: Identifiable {
    let id = UUID()
    /// Middle of the hole in ARKit's world coordinates (m).
    var world: SIMD3<Float>
    /// The surface's normal there, world coordinates, pointing into the wall.
    var normal: SIMD3<Float>
    var shape: MeasuredShape
}

/// Everything the screen shows. Changed on the main thread only.
final class MeasureModel: ObservableObject {
    // The PC (or CadSHAPE on the web)
    @Published var pairing: Pairing?
    @Published var wantsPairing = false
    /// nil = not asked yet / no contact, true = CadSHAPE is open (on the PC or in a browser).
    @Published var pcOpen: Bool?
    @Published var connectionError: String?
    @Published var showSettings = false
    @Published var showSaved = false

    // The camera
    @Published var hasLidar = false
    @Published var fatal: String?
    @Published var hint = "Sikt krysset midt på hullet"

    // Live measuring
    @Published var mode: MeasureMode = .single {
        didSet { if oldValue != mode { modeChanged() } }
    }
    @Published var outlineOnScreen: [CGPoint] = []
    @Published var live: FrameMeasurement?
    /// 0…1: how much the last frames agree.
    @Published var steadiness = 0.0
    /// ± mm: how sure the size is (spread of the last frames + what the distance allows).
    @Published var uncertainty: Double?
    @Published var controlDiameterMM: Double?
    /// Depth of the hole from LiDAR (mm), median of the last frames.
    @Published var depthMM: Double?
    @Published var answer: ShapeAnswer?
    @Published var forcedKind: ShapeKind? {
        didSet { if oldValue != forcedKind { kindChanged() } }
    }
    /// Lock by itself once the measurement has been steady for a second.
    @Published var autoLock: Bool = UserDefaults.standard.object(forKey: "autoLock") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoLock, forKey: "autoLock") }
    }

    // After locking
    @Published var locked = false
    @Published var lockedByItself = false
    @Published var shape: MeasuredShape?
    @Published var make: MakeKind = .lokk {
        didSet { if oldValue != make { settingsChanged() } }
    }
    @Published var params: [ParamKey: Double] = Dictionary(uniqueKeysWithValues: ParamKey.allCases.map { ($0, $0.defaultValue) })
    @Published var working = false
    @Published var done: String?
    @Published var error: String?

    /// Two clear edges were seen round the locked hole; the other one (nil = one clear edge).
    @Published var lockedAlternative: EdgeAlternative?
    /// The locked hole uses the other edge (the user chose it).
    @Published var usingAlternative = false

    // Calibration with CadSHAPE's printed calibration plate
    @Published var calibration: HoleCalibration? = MeasureModel.loadCalibration() {
        didSet { MeasureModel.saveCalibration(calibration) }
    }
    /// Which plate hole is being measured (index into `calibrationHolesMM`), nil = not calibrating.
    @Published var calibrationStep: Int?
    /// Measured (raw) diameter per plate hole, nil = skipped.
    @Published var calibrationSamples: [Double?] = []
    /// The result after the last hole (shown before it is kept).
    @Published var calibrationResult: Result<HoleCalibration, CalibrationProblem>?
    var isCalibrating: Bool { calibrationStep != nil || calibrationResult != nil }

    // Hole pattern
    @Published var pattern: [PatternEntry] = []
    /// The pattern's holes on screen (numbered markers), updated with the camera.
    @Published var patternOnScreen: [CGPoint?] = []
    @Published var patternLocked = false
    @Published var holesMake: HolesMake = .plate
    @Published var holesParams: [ParamKey: Double] = holesDefaults

    let store = MeasurementStore()
    /// The inside of a box, or something on a table.
    let space = SpaceModel()
    /// The measurement saved on the phone for the locked hole or pattern.
    private(set) var savedId: UUID?

    /// Set by the camera view: a picture of what the camera sees now, and pausing the camera.
    var snapshot: (() -> UIImage?)?
    var pauseCamera: (() -> Void)?
    var resumeCamera: (() -> Void)?

    private var client: CadshapeClient?
    /// The connection to CadSHAPE, for the other screens (AR, scanning, prints). Nil = not paired.
    var api: CadshapeClient? { client }
    private var history: [FrameMeasurement] = []
    private var lockedOutline: [P2] = []
    private var trackingNormal = false
    private var quality = measurementQuality([], trackingNormal: false)
    private var lockedDiagnostics: MeasurementDiagnostics?
    private var lastWorld: (centre: SIMD3<Float>, normal: SIMD3<Float>)?
    private var steadySince: Date?
    private var sending = false
    private var lastSent = Date.distantPast
    private var statusTimer: Timer?
    private var previewWork: DispatchWorkItem?
    private let haptic = UINotificationFeedbackGenerator()
    private let tap = UIImpactFeedbackGenerator(style: .medium)

    /// Demo (simulator screenshots, `-demo live`): a made-up ceiling instead of the camera, no PC.
    let demo: String? = UserDefaults.standard.string(forKey: "demo")
    var isDemo: Bool { demo != nil }

    init() {
        space.owner = self
        if demo != nil {
            hasLidar = true
            wantsPairing = demo == "pairing"
            return
        }
        if let p = Pairing.load() { connect(p) } else { wantsPairing = true }
        startChecking()
    }

    // MARK: The PC

    /// Checks every few seconds whether CadSHAPE is open – only while the app is on screen.
    func startChecking() {
        guard !isDemo, statusTimer == nil else { return }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.checkPc() }
        checkPc()
    }

    func stopChecking() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    /// A QR code from CadSHAPE was seen (again: a fresh start, the PC may have a new certificate).
    func paired(_ p: Pairing) {
        haptic.notificationOccurred(.success)
        p.save()
        connect(p)
        wantsPairing = false
        showSettings = false
    }

    /// Logged in to CadSHAPE on the web.
    func loggedIn(base: URL, session: String) {
        Keychain.save(session, account: base.absoluteString)
        paired(.web(base))
    }

    private func connect(_ p: Pairing) {
        client?.invalidate()
        let c = CadshapeClient(pairing: p)
        c.onPin = { [weak self] pin in
            guard let self, var current = self.pairing else { return }
            current.pin = pin
            current.save()
            self.pairing = current
        }
        client = c
        pairing = p
        pcOpen = nil
        connectionError = nil
        checkPc()
    }

    func forget() {
        client?.invalidate()
        client = nil
        Pairing.forget()
        pairing = nil
        pcOpen = nil
        connectionError = nil
        wantsPairing = true
        showSettings = false
    }

    func checkPc() {
        guard let client else { return }
        client.status { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let open):
                self.pcOpen = open
                let online = self.pairing?.isOnline == true
                self.connectionError = open ? nil : (online ? "CadSHAPE er ikke åpent i noen nettleser. Åpne \(self.pairing?.hostLabel ?? "CadSHAPE") på PC-en." : "CadSHAPE er ikke åpent i nettleseren på PC-en.")
            case .failure(let e):
                self.pcOpen = nil
                self.connectionError = e.message
            }
        }
    }

    var connected: Bool { isDemo || pcOpen == true }

    // MARK: Live measuring

    func measured(_ r: Result<FrameMeasurement, MeasureFailure>, toScreen: (P2) -> CGPoint, tracking: ARCamera.TrackingState, cameraToWorld: simd_float4x4? = nil) {
        if locked || patternLocked || mode.isSpace { return }
        switch r {
        case .success(let raw):
            // The plate itself is measured without the old calibration.
            let m = isCalibrating ? raw : calibrated(raw, calibration)
            if case .normal = tracking { trackingNormal = true } else { trackingNormal = false }
            if !trackingNormal { history = []; steadySince = nil }
            history.append(m)
            if history.count > 12 { history.removeFirst(history.count - 12) }
            live = m
            outlineOnScreen = m.outline.map(toScreen)
            if let t = cameraToWorld { lastWorld = toWorld(m, t) }
            updateSteadiness()
            hint = advice(m, tracking: tracking)
            if isCalibrating { return }
            sendLive()
            checkAuto()
        case .failure(let f):
            // A missing current observation must not leave a previous hole available to lock.
            history = []
            live = nil
            answer = nil
            steadiness = 0
            uncertainty = nil
            depthMM = nil
            lastWorld = nil
            quality = measurementQuality([], trackingNormal: false)
            steadySince = nil
            outlineOnScreen = []
            switch f {
            case .noHole: hint = mode == .pattern && !pattern.isEmpty ? "Sikt på neste hull." : "Finner ikke noe hull i krysset. Sikt midt på hullet, 30–100 cm unna."
            case .noSurface: hint = hasLidar ? "Ser ikke flaten rundt hullet. Gå litt lenger unna så mer av veggen er med." : "Beveg telefonen litt fra side til side så den finner flaten."
            }
        }
    }

    /// Camera coordinates (x right, y down, z forward) → ARKit world (its camera looks along −z, y up).
    private func toWorld(_ m: FrameMeasurement, _ t: simd_float4x4) -> (centre: SIMD3<Float>, normal: SIMD3<Float>) {
        let c = t * SIMD4<Float>(Float(m.centre.x), Float(-m.centre.y), Float(-m.centre.z), 1)
        let n = t * SIMD4<Float>(Float(m.plane.normal.x), Float(-m.plane.normal.y), Float(-m.plane.normal.z), 0)
        return (SIMD3(c.x, c.y, c.z), simd_normalize(SIMD3(n.x, n.y, n.z)))
    }

    private func advice(_ m: FrameMeasurement, tracking: ARCamera.TrackingState) -> String {
        switch tracking {
        case .normal: break
        default: return "Beveg telefonen rolig litt – kameraet finner rommet."
        }
        if m.plane.distance > 1.0 { return "Gå nærmere – under 1 m gir best mål." }
        if m.plane.distance < 0.15 { return "Litt lenger unna – hele kanten rundt hullet må synes." }
        if m.plane.tilt > 35 { return "Hold telefonen mer rett mot flaten." }
        if mode == .pattern, isInPattern() { return "Dette hullet er allerede med. Sikt på neste." }
        if let a = m.edgeAlternative {
            let inner = min(m.widthMM, a.widthMM), outer = max(m.widthMM, a.widthMM)
            return "Ser to kanter (\(mm(inner)) og \(mm(outer)) mm) – skygge, fas eller hullets innside. Lås og velg riktig kant."
        }
        if m.source == .depth { return "Grov LiDAR-kant – lås manuelt og bruk kontrollmål før presspasning." }
        if m.edgePixels < 48 { return "Hullet er lite i bildet. Gå nærmere med hele kanten synlig og skarp." }
        if !quality.canAutoLock && (uncertainty ?? .infinity) > 0.5 { return "For usikkert for presspasning. Gå nærmere eller bruk kontrollmål etter låsing." }
        if steadiness < 0.7 { return "Hold stille …" }
        if autoLock && !quality.canAutoLock { return "Stødig bilde, men ikke godt nok målegrunnlag. Lås manuelt og bruk kontrollmål." }
        if mode == .pattern { return autoLock ? "Stødig – legges til …" : "Stødig – trykk «Legg til hull»." }
        return autoLock ? "Stødig – låser …" : "Stødig – trykk «Lås målet»."
    }

    private func updateSteadiness() {
        let recent = history.suffix(8)
        quality = measurementQuality(Array(recent), trackingNormal: trackingNormal)
        steadiness = quality.steadiness
        uncertainty = quality.uncertaintyMM
        let depths = recent.compactMap(\.depthMM).sorted()
        depthMM = depths.count >= 3 ? depths[depths.count / 2] : nil
    }

    /// The frame that best matches the last frames (median size).
    private func representative() -> FrameMeasurement? {
        let recent = Array(history.suffix(8))
        guard !recent.isEmpty else { return nil }
        let med = recent.map(\.sizeMM).sorted()[recent.count / 2]
        return recent.min { abs($0.sizeMM - med) < abs($1.sizeMM - med) }
    }

    var quick: String? { live.map { quickText($0) } }

    var details: String {
        guard let m = live else { return "" }
        var parts = [String(format: "%.2f m unna", m.plane.distance).replacingOccurrences(of: ".", with: ","), "\(Int(m.plane.tilt.rounded()))° på skrå"]
        if let d = depthMM { parts.append("\(Int(d.rounded())) mm dypt") }
        return parts.joined(separator: " · ")
    }

    /// «± 0,3 mm» (nil before there is a steady measurement).
    var uncertaintyText: String? { controlDiameterMM == nil ? uncertainty.map { "Anslått avvik: ± \(mm($0)) mm" } : nil }
    /// The measurement is too unsure to rely on for a tight fit.
    var unsure: Bool { controlDiameterMM == nil && (uncertainty ?? .infinity) > 0.5 }

    /// User-initiated sharing of numeric measurement evidence; no photo or connection details.
    var diagnosticsText: String? {
        guard let diagnostics = lockedDiagnostics else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(diagnostics) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func sendLive() {
        if isDemo, let rep = representative() {
            let s = localShape(rep.outlineMM)
            answer = ShapeAnswer(shape: s, text: s.text, label: s.kind.label)
            return
        }
        // Three times a second is plenty for the ghost on the PC (and spares the battery).
        guard let client, connected, !sending, Date().timeIntervalSince(lastSent) > 0.5, let rep = representative() else { return }
        sending = true
        lastSent = Date()
        client.outline(rep.outlineMM, kind: forcedKind, make: make, params: params, preview: mode == .single) { [weak self] r in
            guard let self else { return }
            self.sending = false
            if self.locked { return }
            if case .success(let a) = r { self.answer = a }
        }
    }

    /// Locks (one hole) or adds the hole (pattern) by itself once steady for a second.
    private func checkAuto() {
        guard autoLock, quality.canAutoLock, live != nil, !working else {
            steadySince = nil
            return
        }
        if mode == .pattern && isInPattern() {
            steadySince = nil
            return
        }
        let now = Date()
        guard let since = steadySince else {
            steadySince = now
            return
        }
        if now.timeIntervalSince(since) < 1.0 { return }
        steadySince = nil
        if mode == .single {
            lock(byItself: true)
        } else {
            addHole()
        }
    }

    // MARK: Locking and making

    var canLock: Bool { live != nil && trackingNormal && !locked }

    func lock(byItself: Bool = false) {
        guard canLock, !isCalibrating, (!byItself || quality.canAutoLock), let rep = representative() else { return }
        haptic.notificationOccurred(.success)
        locked = true
        lockedByItself = byItself
        lockedOutline = rep.outlineMM
        lockedAlternative = rep.edgeAlternative
        usingAlternative = false
        controlDiameterMM = nil
        lockedDiagnostics = MeasurementDiagnostics(rep, uncertaintyMM: uncertainty, calibration: calibration)
        outlineOnScreen = []
        done = nil
        error = nil
        // LiDAR saw the bottom: a plug or collar goes as deep as the hole (a little less).
        if let d = depthMM, d >= 3 { params[.depth] = max(1, (d - 1).rounded()) }
        let picture = snapshot?()
        pauseCamera?()
        fitLocked(picture: picture)
    }

    private func fitLocked(picture: UIImage? = nil) {
        if isDemo {
            let s = localShape(lockedOutline)
            shape = s
            answer = ShapeAnswer(shape: s, text: s.text, label: s.kind.label)
            saveLocked(picture: picture)
            return
        }
        guard let client, connected else {
            shape = localShape(lockedOutline)
            error = "CadSHAPE er ikke åpent – formen er grovt anslått. Målingen er lagret og kan sendes senere."
            saveLocked(picture: picture)
            return
        }
        working = true
        client.outline(lockedOutline, kind: forcedKind, make: make, params: params, preview: true) { [weak self] r in
            guard let self, self.locked else { return }
            self.working = false
            switch r {
            case .success(let a):
                self.shape = a.shape
                self.answer = a
                self.error = nil
            case .failure(let e):
                self.shape = self.localShape(self.lockedOutline)
                self.error = e.message
            }
            self.saveLocked(picture: picture)
        }
    }

    /// Keeps the locked measurement on the phone (first time: with the picture; later: new choices).
    private func saveLocked(picture: UIImage? = nil) {
        guard let shape else { return }
        let p = Dictionary(uniqueKeysWithValues: params.map { ($0.key.rawValue, $0.value) })
        if let id = savedId {
            store.update(id) {
                $0.shape = shape
                $0.make = make
                $0.params = p
                $0.text = shape.text
                $0.uncertainty = controlDiameterMM == nil ? uncertainty : nil
                $0.diagnostics = lockedDiagnostics
                $0.controlDiameterMM = controlDiameterMM
            }
            return
        }
        savedId = store.add(SavedMeasurement(shape: shape, make: make, params: p, text: shape.text, uncertainty: controlDiameterMM == nil ? uncertainty : nil, depthMM: depthMM, diagnostics: lockedDiagnostics, controlDiameterMM: controlDiameterMM), image: picture)
    }

    /// Without the PC: a circle when the outline is round, else the outer size.
    private func localShape(_ outline: [P2]) -> MeasuredShape {
        if let c = fitCircle(outline), c.rms < c.radius * 0.025, forcedKind != .rect, forcedKind != .free {
            return .circle(d: 2 * c.radius)
        }
        var lo = P2(Double.infinity, Double.infinity), hi = P2(-Double.infinity, -Double.infinity)
        for p in outline {
            lo = P2(min(lo.x, p.x), min(lo.y, p.y))
            hi = P2(max(hi.x, p.x), max(hi.y, p.y))
        }
        return .rect(w: hi.x - lo.x, h: hi.y - lo.y, r: 0)
    }

    /// Two clear edges: switch the locked hole to the other one (and back).
    func useOtherEdge() {
        guard locked, !working, let alt = lockedAlternative else { return }
        let current = EdgeAlternative(outlineMM: lockedOutline, sizeMM: abs(polygonArea(lockedOutline)).squareRoot(),
                                      widthMM: lockedWidth, heightMM: lockedHeight, inward: !alt.inward, share: 1 - alt.share)
        lockedOutline = alt.outlineMM
        lockedAlternative = current
        usingAlternative.toggle()
        controlDiameterMM = nil
        // The uncertainty no longer includes «which edge»: the user decided.
        uncertainty = lockedDiagnostics?.uncertaintyMM.map { max(0.3, $0 - abs(current.widthMM - alt.widthMM) / 2) }
        tap.impactOccurred()
        fitLocked()
    }

    private var lockedWidth: Double {
        let xs = lockedOutline.map(\.x)
        return (xs.max() ?? 0) - (xs.min() ?? 0)
    }

    private var lockedHeight: Double {
        let ys = lockedOutline.map(\.y)
        return (ys.max() ?? 0) - (ys.min() ?? 0)
    }

    /// The locked hole's size at each of the two edges, inner first (for the choice in the panel).
    var edgeChoices: (inner: Double, outer: Double, usingInner: Bool)? {
        guard let alt = lockedAlternative else { return nil }
        let here = fitCircle(lockedOutline).map { 2 * $0.radius } ?? lockedWidth
        let there = fitCircle(alt.outlineMM).map { 2 * $0.radius } ?? alt.widthMM
        return (min(here, there), max(here, there), here <= there)
    }

    // MARK: Calibration

    private static let calibrationKey = "holeCalibration"

    static func loadCalibration() -> HoleCalibration? {
        guard let data = UserDefaults.standard.data(forKey: calibrationKey) else { return nil }
        return try? JSONDecoder().decode(HoleCalibration.self, from: data)
    }

    static func saveCalibration(_ c: HoleCalibration?) {
        if let c, let data = try? JSONEncoder().encode(c) {
            UserDefaults.standard.set(data, forKey: calibrationKey)
        } else {
            UserDefaults.standard.removeObject(forKey: calibrationKey)
        }
    }

    func startCalibration() {
        showSettings = false
        if mode != .single { mode = .single }
        measureAgain()
        calibrationSamples = Array(repeating: nil, count: calibrationHolesMM.count)
        calibrationResult = nil
        calibrationStep = 0
        hint = "Sikt krysset midt på hullet merket \(Int(calibrationHolesMM[0]))."
    }

    /// The diameter of the hole in the cross-hair now: median of the last steady frames (raw, uncalibrated).
    var calibrationReading: Double? {
        let recent = history.suffix(8).filter { $0.source == .picture && $0.edgeAlternative == nil }
        let ds = recent.compactMap { measuredDiameter($0) }.sorted()
        guard ds.count >= 5, steadiness >= 0.7, trackingNormal else { return nil }
        return ds[ds.count / 2]
    }

    /// Why the current reading cannot be used (nil = it can).
    var calibrationBlocker: String? {
        guard calibrationStep != nil else { return nil }
        if live == nil { return "Sikt krysset midt på hullet." }
        if live?.edgeAlternative != nil { return "Ser to kanter – gå nærmere og mer rett mot platen, med jevnt lys." }
        if live?.source != .picture { return "Kanten synes ikke godt nok i bildet. Legg platen på et lyst underlag." }
        if calibrationReading == nil { return "Hold stille …" }
        return nil
    }

    func takeCalibrationSample() {
        guard let step = calibrationStep, let d = calibrationReading else { return }
        let expected = calibrationHolesMM[step]
        // A much smaller/larger hole than expected is the wrong one, not a calibration.
        if abs(d / expected - 1) > 0.35 {
            hint = "Det hullet er \(mm(d)) mm – er det riktig hull (\(Int(expected)))? Sikt på hullet merket \(Int(expected))."
            haptic.notificationOccurred(.warning)
            return
        }
        haptic.notificationOccurred(.success)
        calibrationSamples[step] = d
        nextCalibrationStep()
    }

    func skipCalibrationSample() { nextCalibrationStep() }

    private func nextCalibrationStep() {
        guard let step = calibrationStep else { return }
        history = []
        steadiness = 0
        if step + 1 < calibrationHolesMM.count {
            calibrationStep = step + 1
            hint = "Sikt krysset midt på hullet merket \(Int(calibrationHolesMM[step + 1]))."
            return
        }
        calibrationStep = nil
        let pairs = zip(calibrationSamples, calibrationHolesMM).compactMap { m, a in m.map { (measured: $0, actual: a) } }
        calibrationResult = fitHoleCalibration(pairs)
    }

    func keepCalibration() {
        if case .success(let c)? = calibrationResult { calibration = c }
        cancelCalibration()
    }

    func cancelCalibration() {
        calibrationStep = nil
        calibrationResult = nil
        calibrationSamples = []
        history = []
        steadiness = 0
        hint = "Sikt krysset midt på hullet"
    }

    func removeCalibration() { calibration = nil }

    private func kindChanged() {
        controlDiameterMM = nil
        if locked { fitLocked() } else { lastSent = .distantPast }
    }

    func useStandard(_ d: Double) {
        controlDiameterMM = nil
        shape = .circle(d: d)
        settingsChanged()
    }

    @discardableResult
    func useControlDiameter(_ text: String) -> Bool {
        guard locked, !working, let d = controlDiameter(text) else { return false }
        shape = .circle(d: d)
        controlDiameterMM = d
        error = nil
        settingsChanged()
        return true
    }

    func useDepth() {
        guard let d = depthMM else { return }
        setParam(.depth, max(1, (d - 1).rounded()))
    }

    func setParam(_ k: ParamKey, _ v: Double) {
        params[k] = min(k.range.upperBound, max(k.range.lowerBound, (v / k.step).rounded() * k.step))
        settingsChanged()
    }

    /// Shows the new size/part on the PC, a moment after the last change.
    private func settingsChanged() {
        done = nil
        if locked { saveLocked() }
        previewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let client = self.client, let shape = self.shape, self.locked, self.connected else { return }
            client.preview(shape, make: self.make, params: self.params, locked: true)
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func commit() {
        if isDemo {
            done = "\(make.label) er laget i CadSHAPE (demo)."
            return
        }
        guard let client, let shape else { return }
        working = true
        error = nil
        let saved = savedId.flatMap { id in store.items.first { $0.id == id } }
        client.commit(shape, make: make, params: params, photo: saved.flatMap { store.photoData($0) }) { [weak self] r in
            guard let self else { return }
            self.working = false
            switch r {
            case .success(let label):
                self.haptic.notificationOccurred(.success)
                self.done = "\(label) er laget i CadSHAPE."
                if let id = self.savedId { self.store.update(id) { $0.sentAt = Date() } }
            case .failure(let e):
                self.haptic.notificationOccurred(.error)
                self.error = e.message + " Målingen er lagret på telefonen."
            }
        }
    }

    func measureAgain() {
        locked = false
        lockedByItself = false
        shape = nil
        answer = nil
        live = nil
        done = nil
        error = nil
        working = false
        history = []
        steadiness = 0
        uncertainty = nil
        depthMM = nil
        steadySince = nil
        savedId = nil
        controlDiameterMM = nil
        lockedDiagnostics = nil
        lockedAlternative = nil
        usingAlternative = false
        trackingNormal = false
        quality = measurementQuality([], trackingNormal: false)
        resumeCamera?()
        client?.clear()
    }

    // MARK: Hole pattern

    private func modeChanged() {
        measureAgain()
        pattern = []
        patternOnScreen = []
        patternLocked = false
        space.reset()
        if mode.isSpace && !hasLidar { space.noLidar() }
    }

    /// The box or object parts to CadSHAPE (SpaceModel).
    func sendSpace(_ body: [String: Any], photo: String?, done: @escaping (Result<(label: String, notes: [String]), ClientError>) -> Void) {
        guard let client, connected else { return done(.failure(.offline("CadSHAPE er ikke åpent."))) }
        client.space(body, photo: photo, done: done)
    }

    /// The hole in the cross-hair is already in the pattern (its middle is within half its size).
    func isInPattern() -> Bool {
        guard let w = lastWorld, let m = live else { return false }
        let near = Float(max(0.003, m.sizeMM / 1000 * 0.6))
        return pattern.contains { simd_distance($0.world, w.centre) < near }
    }

    var canAddHole: Bool { trackingNormal && live != nil && lastWorld != nil && !isInPattern() && !patternLocked }

    /// Adds the hole in the cross-hair to the pattern.
    func addHole() {
        guard canAddHole, let w = lastWorld, let rep = representative(), !isInPattern() else { return }
        tap.impactOccurred()
        let s = answer?.shape ?? localShape(rep.outlineMM)
        pattern.append(PatternEntry(world: w.centre, normal: w.normal, shape: s))
        history = []
        steadiness = 0
        steadySince = nil
        hint = "Hull \(pattern.count) er med. Sikt på neste."
    }

    func undoHole() {
        if !pattern.isEmpty { pattern.removeLast() }
    }

    /// The pattern laid flat: mm on the surface, x right and y up as seen from the room. On a wall
    /// «up» is up; on a ceiling or floor the first two holes give the direction.
    func patternLayout() -> [PatternHoleOut] {
        guard pattern.count >= 2 else { return [] }
        var n = SIMD3<Float>(0, 0, 0)
        for e in pattern { n += e.normal }
        n = simd_normalize(n)
        let toViewer = -n
        let worldUp = SIMD3<Float>(0, 1, 0)
        var y: SIMD3<Float>
        if abs(simd_dot(n, worldUp)) < 0.85 {
            y = worldUp - n * simd_dot(worldUp, n)
        } else {
            let d = pattern[1].world - pattern[0].world
            y = d - n * simd_dot(d, n)
        }
        y = simd_normalize(y)
        let x = simd_normalize(simd_cross(y, toViewer))
        let o = pattern[0].world
        return pattern.map { e in
            let d = e.world - o
            return PatternHoleOut(x: Double(simd_dot(d, x)) * 1000, y: Double(simd_dot(d, y)) * 1000, shape: e.shape)
        }
    }

    /// Distances between neighbouring holes in the pattern, for the panel (mm).
    var patternSpacings: [Double] {
        let l = patternLayout()
        guard l.count >= 2 else { return [] }
        return zip(l, l.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
    }

    func finishPattern() {
        guard pattern.count >= 2 else { return }
        haptic.notificationOccurred(.success)
        patternLocked = true
        outlineOnScreen = []
        done = nil
        error = nil
        let picture = snapshot?()
        let holes = patternLayout()
        let p = Dictionary(uniqueKeysWithValues: holesParams.map { ($0.key.rawValue, $0.value) })
        savedId = store.add(SavedMeasurement(holes: holes, holesMake: holesMake, holesParams: p, text: patternText(holes)), image: picture)
        pauseCamera?()
    }

    func patternText(_ holes: [PatternHoleOut]) -> String {
        let xs = holes.map(\.x), ys = holes.map(\.y)
        let span = "\(mm((xs.max() ?? 0) - (xs.min() ?? 0))) × \(mm((ys.max() ?? 0) - (ys.min() ?? 0))) mm"
        let kinds = Set(holes.map { $0.shape.text })
        return "\(holes.count) hull, \(kinds.count == 1 ? kinds.first! : "ulike størrelser"), \(span)"
    }

    func setHolesParam(_ k: ParamKey, _ v: Double) {
        holesParams[k] = min(k.range.upperBound, max(k.range.lowerBound, (v / k.step).rounded() * k.step))
        if let id = savedId {
            let p = Dictionary(uniqueKeysWithValues: holesParams.map { ($0.key.rawValue, $0.value) })
            store.update(id) { $0.holesParams = p }
        }
        done = nil
    }

    func setHolesMake(_ m: HolesMake) {
        holesMake = m
        if let id = savedId { store.update(id) { $0.holesMake = m } }
        done = nil
    }

    func commitPattern() {
        if isDemo {
            done = "\(holesMake.label) er laget i CadSHAPE (demo)."
            return
        }
        guard let client else { return }
        working = true
        error = nil
        let saved = savedId.flatMap { id in store.items.first { $0.id == id } }
        client.holes(patternLayout(), make: holesMake, params: holesParams, photo: saved.flatMap { store.photoData($0) }) { [weak self] r in
            guard let self else { return }
            self.working = false
            switch r {
            case .success(let label):
                self.haptic.notificationOccurred(.success)
                self.done = "\(label) er laget i CadSHAPE."
                if let id = self.savedId { self.store.update(id) { $0.sentAt = Date() } }
            case .failure(let e):
                self.haptic.notificationOccurred(.error)
                self.error = e.message + " Mønsteret er lagret på telefonen."
            }
        }
    }

    func newPattern() {
        pattern = []
        patternOnScreen = []
        patternLocked = false
        savedId = nil
        done = nil
        error = nil
        history = []
        steadiness = 0
        resumeCamera?()
    }

    // MARK: Saved measurements

    /// Sends a measurement kept on the phone to CadSHAPE.
    func send(_ m: SavedMeasurement, done: @escaping (String?) -> Void) {
        guard let client, connected else { return done("CadSHAPE er ikke åpent.") }
        let photo = store.photoData(m)
        let finish: (Result<String, ClientError>) -> Void = { [weak self] r in
            switch r {
            case .success:
                self?.store.update(m.id) { $0.sentAt = Date() }
                done(nil)
            case .failure(let e):
                done(e.message)
            }
        }
        if let body = SpaceModel.body(m) {
            client.space(body, photo: photo) { r in finish(r.map { $0.label }) }
        } else if let holes = m.holes {
            let p = paramDict(m.holesParams, defaults: holesDefaults)
            client.holes(holes, make: m.holesMake ?? .plate, params: p, photo: photo, done: finish)
        } else if let shape = m.shape {
            let defaults = Dictionary(uniqueKeysWithValues: ParamKey.allCases.map { ($0, $0.defaultValue) })
            client.commit(shape, make: m.make ?? .lokk, params: paramDict(m.params, defaults: defaults), photo: photo, done: finish)
        } else {
            done("Målingen er tom.")
        }
    }

    private func paramDict(_ raw: [String: Double]?, defaults: [ParamKey: Double]) -> [ParamKey: Double] {
        var out = defaults
        for (k, v) in raw ?? [:] { if let key = ParamKey(rawValue: k) { out[key] = v } }
        return out
    }
}
