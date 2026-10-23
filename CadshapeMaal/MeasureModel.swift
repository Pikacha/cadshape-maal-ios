import ARKit
import Combine
import Foundation
import HoleKit
import UIKit

/// Everything the screen shows. Changed on the main thread only.
final class MeasureModel: ObservableObject {
    // The PC
    @Published var pairing: Pairing?
    @Published var wantsPairing = false
    /// nil = not asked yet / no contact, true = CadSHAPE is open on the PC.
    @Published var pcOpen: Bool?
    @Published var connectionError: String?
    @Published var showSettings = false

    // The camera
    @Published var hasLidar = false
    @Published var fatal: String?
    @Published var hint = "Sikt krysset midt på hullet"

    // Live measuring
    @Published var outlineOnScreen: [CGPoint] = []
    @Published var live: FrameMeasurement?
    /// 0…1: how much the last frames agree.
    @Published var steadiness = 0.0
    @Published var answer: ShapeAnswer?
    @Published var forcedKind: ShapeKind? {
        didSet { if oldValue != forcedKind { kindChanged() } }
    }

    // After locking
    @Published var locked = false
    @Published var shape: MeasuredShape?
    @Published var make: MakeKind = .lokk {
        didSet { if oldValue != make { settingsChanged() } }
    }
    @Published var params: [ParamKey: Double] = Dictionary(uniqueKeysWithValues: ParamKey.allCases.map { ($0, $0.defaultValue) })
    @Published var working = false
    @Published var done: String?
    @Published var error: String?

    private var client: CadshapeClient?
    private var history: [FrameMeasurement] = []
    private var lockedOutline: [P2] = []
    private var sending = false
    private var lastSent = Date.distantPast
    private var statusTimer: Timer?
    private var previewWork: DispatchWorkItem?
    private let haptic = UINotificationFeedbackGenerator()

    /// Demo (simulator screenshots, `-demo live`): a made-up ceiling instead of the camera, no PC.
    let demo: String? = UserDefaults.standard.string(forKey: "demo")
    var isDemo: Bool { demo != nil }

    init() {
        if demo != nil {
            hasLidar = true
            wantsPairing = demo == "pairing"
            return
        }
        if let p = Pairing.load() { connect(p) } else { wantsPairing = true }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.checkPc() }
    }

    // MARK: The PC

    /// A QR code from CadSHAPE was seen (again: a fresh start, the PC may have a new certificate).
    func paired(_ p: Pairing) {
        haptic.notificationOccurred(.success)
        p.save()
        connect(p)
        wantsPairing = false
        showSettings = false
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
                self.connectionError = open ? nil : "CadSHAPE er ikke åpent i nettleseren på PC-en."
            case .failure(let e):
                self.pcOpen = nil
                self.connectionError = e.message
            }
        }
    }

    var connected: Bool { isDemo || pcOpen == true }

    // MARK: Live measuring

    func measured(_ r: Result<FrameMeasurement, MeasureFailure>, toScreen: (P2) -> CGPoint, tracking: ARCamera.TrackingState) {
        if locked { return }
        switch r {
        case .success(let m):
            history.append(m)
            if history.count > 12 { history.removeFirst(history.count - 12) }
            live = m
            outlineOnScreen = m.outline.map(toScreen)
            updateSteadiness()
            hint = advice(m, tracking: tracking)
            sendLive()
        case .failure(let f):
            if !history.isEmpty { history.removeFirst() }
            if history.isEmpty {
                live = nil
                answer = nil
                steadiness = 0
            }
            outlineOnScreen = []
            switch f {
            case .noHole: hint = "Finner ikke noe hull i krysset. Sikt midt på hullet, 30–100 cm unna."
            case .noSurface: hint = hasLidar ? "Ser ikke flaten rundt hullet. Gå litt lenger unna så mer av veggen er med." : "Beveg telefonen litt fra side til side så den finner flaten."
            }
        }
    }

    private func advice(_ m: FrameMeasurement, tracking: ARCamera.TrackingState) -> String {
        if case .limited = tracking { return "Beveg telefonen rolig litt – kameraet finner rommet." }
        if m.plane.distance > 2.0 { return "Gå nærmere – under 1 m gir best mål." }
        if m.plane.distance < 0.15 { return "Litt lenger unna – hele kanten rundt hullet må synes." }
        if m.plane.tilt > 55 { return "Hold telefonen mer rett mot flaten." }
        if m.source == .depth { return "Kanten er funnet med LiDAR (hullet skiller seg lite ut i bildet)." }
        if steadiness < 0.7 { return "Hold stille …" }
        return "Stødig – trykk «Lås målet»."
    }

    private func updateSteadiness() {
        let sizes = history.suffix(8).map(\.sizeMM).sorted()
        guard sizes.count >= 3 else { steadiness = 0; return }
        let med = sizes[sizes.count / 2]
        let dev = sizes.map { abs($0 - med) }.sorted()[sizes.count / 2]
        let rel = dev / max(1e-6, med)
        steadiness = max(0, min(1, 1 - rel / 0.02)) * min(1, Double(sizes.count) / 6)
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
        if m.planePoints > 0 { parts.append("flate fra \(m.planePoints) LiDAR-punkter") } else { parts.append("flate fra ARKit") }
        return parts.joined(separator: " · ")
    }

    private func sendLive() {
        if isDemo, let rep = representative() {
            let s = localShape(rep.outlineMM)
            answer = ShapeAnswer(shape: s, text: s.text, label: s.kind.label)
            return
        }
        guard let client, connected, !sending, Date().timeIntervalSince(lastSent) > 0.35, let rep = representative() else { return }
        sending = true
        lastSent = Date()
        client.outline(rep.outlineMM, kind: forcedKind, make: make, params: params, preview: true) { [weak self] r in
            guard let self else { return }
            self.sending = false
            if self.locked { return }
            if case .success(let a) = r { self.answer = a }
        }
    }

    // MARK: Locking and making

    var canLock: Bool { live != nil && !locked }

    func lock() {
        guard let rep = representative() else { return }
        haptic.notificationOccurred(.success)
        locked = true
        lockedOutline = rep.outlineMM
        outlineOnScreen = []
        done = nil
        error = nil
        fitLocked()
    }

    private func fitLocked() {
        if isDemo {
            let s = localShape(lockedOutline)
            shape = s
            answer = ShapeAnswer(shape: s, text: s.text, label: s.kind.label)
            return
        }
        guard let client else {
            shape = localShape(lockedOutline)
            error = "Ikke koblet til PC-en – formen er grovt anslått. Koble til for å lage delen."
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
        }
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

    private func kindChanged() {
        if locked { fitLocked() } else { lastSent = .distantPast }
    }

    func useStandard(_ d: Double) {
        shape = .circle(d: d)
        settingsChanged()
    }

    func setParam(_ k: ParamKey, _ v: Double) {
        params[k] = min(k.range.upperBound, max(k.range.lowerBound, (v / k.step).rounded() * k.step))
        settingsChanged()
    }

    /// Shows the new size/part on the PC, a moment after the last change.
    private func settingsChanged() {
        done = nil
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
        client.commit(shape, make: make, params: params) { [weak self] r in
            guard let self else { return }
            self.working = false
            switch r {
            case .success(let label):
                self.haptic.notificationOccurred(.success)
                self.done = "\(label) er laget i CadSHAPE."
            case .failure(let e):
                self.haptic.notificationOccurred(.error)
                self.error = e.message
            }
        }
    }

    func measureAgain() {
        locked = false
        shape = nil
        answer = nil
        live = nil
        done = nil
        error = nil
        working = false
        history = []
        steadiness = 0
        client?.clear()
    }
}
