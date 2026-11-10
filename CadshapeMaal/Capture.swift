import Foundation
import HoleKit
import ModelIO
import RealityKit
import SceneKit
import SwiftUI

/// «Skann en ting»: Apple's Object Capture (camera + LiDAR, iOS 17) walks round the thing, the 3D
/// model is made on the phone, and CadSHAPE gets it as a locked reference to build round.
@MainActor
final class CaptureModel: ObservableObject {
    enum Step: Equatable {
        case unsupported
        case starting
        case ready
        case detecting
        case capturing
        case finishing
        case reconstructing(Double)
        case done
        case failed(String)
    }

    @Published var step: Step = .starting { didSet { if step != oldValue { applog("3D-skann", "\(step)") } } }
    @Published var session: ObjectCaptureSession?
    @Published var shots = 0
    @Published var passDone = false
    @Published var passes = 1
    @Published var mesh: TriangleMesh?
    @Published var modelURL: URL?
    @Published var name = ""
    @Published var sending = false
    /// What CadSHAPE makes when the scan arrives: «cad» (parts with measures you can change),
    /// «holder» (a holder shaped after the scan) or «none» (just the scan as a reference).
    @Published var make = "cad"
    /// «Finn målene»: the scan as cylinders, cones, boxes and outlines with measures (HoleKit ScanShapes),
    /// at the current scale (`factor` × what Object Capture made).
    @Published var shapes: ScanShapes?
    /// Where the size comes from: the phone's tracking (1–2 % off), its calibration, or the calipers.
    @Published var scaleSource: ScaleSource = .tracking
    /// The measure the calipers gave, for the line under the drawing («Ø37,4 fra skyvelæren»).
    @Published var caliperNote: String?
    /// What Object Capture made, before any scale correction.
    private var rawMesh: TriangleMesh?
    private var rawShapes: ScanShapes?
    private(set) var factor: Double = 1
    @Published var sent: String?
    @Published var notes: [String] = []
    @Published var error: String? { didSet { if let e = error { applog("3D-skann feil", e) } } }
    @Published var trackingHint: String? { didSet { if let h = trackingHint, h != oldValue { applog("3D-skann", h) } } }
    @Published var stalled = false
    /// How many pictures the phone can use at most (Object Capture's own limit).
    @Published var maxShots = 0
    /// Shots at the start of this round (the round's own progress).
    @Published var roundStart = 0
    @Published var canShoot = false

    private let current: () -> CadshapeClient?
    /// Always the connection the app has now (it can switch while this screen is open).
    var api: CadshapeClient? { current() }
    private var folder: URL?
    private var timer: Timer?
    private var watching: Task<Void, Never>?
    private var observedState: ObjectCaptureSession.CaptureState?
    private var lastProgress = Date()
    private var photogrammetry: PhotogrammetrySession?
    private var reconTask: Task<Void, Never>?

    init(api: @escaping @autoclosure () -> CadshapeClient?) {
        current = api
        let f = DateFormatter()
        f.dateFormat = "d.M HH:mm"
        name = "Skann \(f.string(from: Date()))"
    }

    private var images: URL? { folder?.appendingPathComponent("Bilder", isDirectory: true) }
    private var checkpoints: URL? { folder?.appendingPathComponent("Underveis", isDirectory: true) }

    func start() {
        guard session == nil else { return }
        guard ObjectCaptureSession.isSupported else { step = .unsupported; return }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("skann-\(UUID().uuidString)", isDirectory: true)
        folder = base
        guard let images, let checkpoints else { return }
        do {
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        } catch {
            step = .failed("Fikk ikke laget en mappe til bildene.")
            return
        }
        let s = ObjectCaptureSession()
        var cfg = ObjectCaptureSession.Configuration()
        cfg.checkpointDirectory = checkpoints
        cfg.isOverCaptureEnabled = false
        session = s
        observedState = nil
        lastProgress = Date()
        shots = 0
        passes = 1
        passDone = false
        watching = Task { [weak self] in
            for await st in s.stateUpdates {
                guard !Task.isCancelled, self?.session === s else { break }
                self?.changed(st)
            }
        }
        s.start(imagesDirectory: images, configuration: cfg)
        poll()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        guard let s = session else { return }
        // Read the current state too: an update emitted before the async observer starts
        // must not leave our controls stuck on "Starter kameraet".
        changed(s.state)
        guard session === s else { return }
        if shots != s.numberOfShotsTaken { lastProgress = Date() }
        shots = s.numberOfShotsTaken
        maxShots = s.maximumNumberOfInputImages
        canShoot = s.canRequestImageCapture
        if s.userCompletedScanPass && !passDone { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        passDone = s.userCompletedScanPass
        trackingHint = guidance(s)
        stalled = step == .capturing && !passDone && Date().timeIntervalSince(lastProgress) > 15
    }

    /// When the model began to be made (for «1:20» on screen).
    private var reconstructStart = Date()
    var elapsedText: String {
        let s = Int(Date().timeIntervalSince(reconstructStart))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 0…1: how full the phone's picture budget is.
    var overall: Double { maxShots > 0 ? min(1, Double(shots) / Double(maxShots)) : 0 }
    /// Pictures in this round. A round round the thing is usually 30–60 pictures.
    var roundShots: Int { max(0, shots - roundStart) }
    /// Rounds that give a good model: high, middle, low (or flipped for the bottom).
    static let goodRounds = 3

    /// A picture now (when auto capture holds back, e.g. standing still at a tricky angle).
    func shoot() {
        guard let session, session.canRequestImageCapture else { return }
        session.requestImageCapture()
    }

    private func changed(_ st: ObjectCaptureSession.CaptureState) {
        guard observedState != st else { return }
        observedState = st
        lastProgress = Date()
        stalled = false
        switch st {
        case .initializing: step = .starting
        case .ready: step = .ready
        case .detecting: step = .detecting
        case .capturing: step = .capturing
        case .finishing: step = .finishing
        case .completed:
            // The capture session (camera, ~1 GB) must be completely gone before the model is made,
            // or the photogrammetry runs out of memory and hangs. Our own state listener held on
            // to it, so stop that too, and give SwiftUI a moment to remove the camera view.
            timer?.invalidate()
            watching?.cancel()
            watching = nil
            session = nil
            step = .reconstructing(0)
            reconstructStart = Date()
            reconTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                self?.reconstruct()
            }
        case .failed(let e):
            timer?.invalidate()
            watching?.cancel()
            watching = nil
            session = nil
            step = .failed("Skanningen stoppet: \(e.localizedDescription)")
        @unknown default:
            break
        }
    }

    func detect() {
        guard let session else { return }
        error = nil
        // False means no horizontal support plane (or not ready). It used to be
        // silently discarded, leaving "Finn tingen" apparently doing nothing.
        if !session.startDetecting() {
            error = guidance(session) ?? "Fant ikke bordflaten under tingen. Sikt skrått ned så både tingen og bordet rundt synes, og trykk «Finn tingen» igjen."
        }
    }
    func capture() {
        guard let session, session.state == .detecting else { return }
        error = nil
        session.startCapturing()
    }

    private func guidance(_ s: ObjectCaptureSession) -> String? {
        let feedback = s.feedback
        if feedback.contains(.environmentTooDark) { return "For mørkt til å skanne. Slå på mer jevnt lys." }
        if feedback.contains(.objectTooClose) { return "Tingen er for nær kameraet. Gå litt bakover." }
        if feedback.contains(.objectTooFar) { return "Tingen er for langt unna. Gå nærmere med hele tingen synlig." }
        if feedback.contains(.outOfFieldOfView) { return "Tingen er utenfor bildet. Sikt boksen inn igjen." }
        if feedback.contains(.movingTooFast) { return "Beveg telefonen saktere, og hold avstanden til tingen." }
        switch s.cameraTracking {
        case .notAvailable:
            return "Kameraet finner posisjonen. Sikt skrått ned på et lyst bord med synlige detaljer."
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: return "Beveg telefonen saktere så kameraet finner posisjonen igjen."
            case .insufficientFeatures: return "Kameraet finner for få detaljer. Legg tingen på matt papir med tekst eller mønster, i godt lys."
            case .relocalizing: return "Kameraet prøver å finne igjen stedet. Sikt på samme bord, eller start kameraet på nytt."
            case .initializing: return "Vis både tingen og bordet rundt. Flytt telefonen rolig litt sidelengs; ikke bare vipp den."
            @unknown default: return "Kameraet har mistet posisjonen. Vis mer av bordet rundt tingen."
            }
        case .normal: break
        @unknown default: break
        }
        if #available(iOS 17.4, *), feedback.contains(.objectNotDetected) { return "Fant ikke tingen automatisk. Juster boksen manuelt rundt hele tingen." }
        if feedback.contains(.environmentLowLight) { return "Mer jevnt lys gir skarpere bilder og bedre modell." }
        return nil
    }
    func newPass() {
        session?.beginNewScanPass()
        passes += 1
        roundStart = shots
        lastProgress = Date()
    }
    func flip() {
        session?.beginNewScanPassAfterFlip()
        passes += 1
        roundStart = shots
        lastProgress = Date()
    }
    func finish() { session?.finish() }

    func cancel() {
        let old = session
        session = nil
        timer?.invalidate()
        watching?.cancel()
        watching = nil
        old?.cancel()
        // A model being made (GBs of memory, the GPU) must stop with the screen too.
        photogrammetry?.cancel()
        photogrammetry = nil
        reconTask?.cancel()
        reconTask = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func again() {
        cancel()
        mesh = nil
        shapes = nil
        rawMesh = nil
        rawShapes = nil
        factor = 1
        scaleSource = .tracking
        caliperNote = nil
        modelURL = nil
        sent = nil
        notes = []
        error = nil
        trackingHint = nil
        stalled = false
        roundStart = 0
        step = .starting
        // The old capture session lets go of the camera asynchronously; starting the new one at
        // once could leave it hanging on «Starter kameraet».
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self?.start()
        }
    }

    /// The model is made on the phone (Apple's photogrammetry), as USDZ.
    private func reconstruct() {
        guard let images, let checkpoints, let folder else { return }
        step = .reconstructing(0)
        let out = folder.appendingPathComponent("modell.usdz")
        let count = (try? FileManager.default.contentsOfDirectory(atPath: images.path).count) ?? 0
        guard count >= 10 else {
            step = .failed("Bare \(count) bilder ble tatt – for lite til en modell. Gå sakte en hel runde rundt tingen.")
            return
        }
        reconTask = Task { [weak self] in
            do {
                var cfg = PhotogrammetrySession.Configuration()
                cfg.checkpointDirectory = checkpoints
                // The pictures were taken one after another round the thing: faster and steadier.
                cfg.sampleOrdering = .sequential
                cfg.isObjectMaskingEnabled = true
                let ps = try PhotogrammetrySession(input: images, configuration: cfg)
                self?.photogrammetry = ps
                try ps.process(requests: [.modelFile(url: out)])
                var finished = false
                for try await output in ps.outputs {
                    switch output {
                    case .requestProgress(_, let fraction):
                        self?.step = .reconstructing(fraction)
                    case .requestError(_, let error):
                        throw error
                    case .requestComplete:
                        if !finished, FileManager.default.fileExists(atPath: out.path) {
                            finished = true
                            await self?.loaded(out)
                        }
                    case .processingComplete:
                        if !finished {
                            finished = true
                            await self?.loaded(out)
                        }
                    case .processingCancelled:
                        if Task.isCancelled { return }
                        self?.step = .failed("Modellen ble avbrutt. Prøv igjen og hold appen åpen mens den lages.")
                    default:
                        break
                    }
                }
            } catch {
                // Cancelled with the screen or «Skann på nytt»: not an error to show over the new scan.
                if Task.isCancelled { return }
                self?.step = .failed("Kunne ikke lage modellen: \(error.localizedDescription). Prøv med mer lys, matt underlag og en runde til.")
            }
        }
    }

    private func loaded(_ url: URL) async {
        let cad = await Task.detached(priority: .userInitiated) { () -> TriangleMesh? in
            guard let m = readModel(url), m.triangleCount > 0, let b = m.bounds else { return nil }
            // Y up, metres → CadSHAPE: Z up, mm, standing on 0 and centred.
            let mid = (b.min + b.max) / 2
            let z = m.mapped { worldToCad($0, origin: V3(mid.x, b.min.y, mid.z)) }
            return z
        }.value
        guard let cad else { step = .failed("Modellen var tom. Prøv igjen med tingen midt i bildet."); return }
        rawMesh = cad
        modelURL = url
        rawShapes = await Task.detached(priority: .userInitiated) { fitScanShapes(cad) }.value
        // This phone's own size bias, learnt from earlier caliper corrections.
        if let f = PhoneScaleStore.load().factor {
            applyScale(f, source: .phone)
        } else {
            applyScale(1, source: .tracking)
        }
        if let s = shapes { applog("Finn målene", s.lines.joined(separator: " · ") + " (\(scaleSource.rawValue), ×\(String(format: "%.4f", factor)))") }
        step = .done
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func applyScale(_ f: Double, source: ScaleSource) {
        factor = f
        scaleSource = source
        mesh = rawMesh.map { m in f == 1 ? m : m.mapped { $0 * f } }
        shapes = rawShapes?.scaled(by: f)
    }

    /// «Rett etter skyvelære»: `truth` is what the calipers show for `measure` on part `index`.
    /// Every measure follows. With `learn`, the phone keeps the factor for the next scans.
    /// Returns an error text when the number can't be that measure.
    func correct(part index: Int, measure: PartMeasure, truth: Double, learn: Bool) -> String? {
        guard let raw = rawShapes, raw.parts.indices.contains(index) else { return "Fant ikke delen." }
        let rawValue = raw.parts[index].value(measure)
        guard let f = scaleFactor(measured: rawValue, truth: truth) else {
            return "\(shortMM(truth)) mm passer ikke med skannet (\(shortMM(rawValue * factor)) mm). Sjekk at det er samme mål."
        }
        applyScale(f, source: .measured)
        caliperNote = "\(measure.label) \(shortMM(truth)) mm fra skyvelæren"
        if learn {
            var ph = PhoneScaleStore.load()
            ph.add(f)
            PhoneScaleStore.save(ph)
        }
        applog("Skyvelære", "\(measure.rawValue) \(truth) mot \(rawValue) → ×\(String(format: "%.4f", f))")
        return nil
    }

    /// Back to the size before the calipers (the phone's calibration if it has one).
    func undoCorrection() {
        caliperNote = nil
        if let f = PhoneScaleStore.load().factor { applyScale(f, source: .phone) } else { applyScale(1, source: .tracking) }
    }

    var sizeText: String {
        guard let s = mesh?.size else { return "" }
        return "\(mm(s.x, digits: 1)) × \(mm(s.y, digits: 1)) × \(mm(s.z, digits: 1)) mm"
    }

    func send() {
        guard let api, let mesh else { error = "Koble til CadSHAPE først."; return }
        sending = true
        error = nil
        let s = mesh.size
        let name = self.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Skann" : self.name
        let make = self.make
        let scaleLine = scaleSource.label + (caliperNote.map { " (\($0))." } ?? ".")
        Task { [weak self] in
            let stl = await Task.detached { binarySTL(mesh, header: "CadSHAPE Maal - Object Capture").base64EncodedString() }.value
            let body: [String: Any] = [
                "type": "mesh", "role": "ting", "name": name, "stl": stl, "make": make,
                "size": [s.x, s.y, s.z].map { ($0 * 10).rounded() / 10 },
                "notes": ["3D-skann fra telefonen (Object Capture, \(mesh.triangleCount) trekanter). \(scaleLine)"],
            ]
            api.postJSON("api/live/scan", body: body, timeout: 240) { r in
                guard let self else { return }
                self.sending = false
                switch r {
                case .success(let j):
                    let result = j["result"] as? [String: Any]
                    self.sent = result?["label"] as? String ?? "Sendt til CadSHAPE"
                    let lib = (j["library"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                    self.notes = lib.isEmpty ? [] : ["Ligner \(lib[0]) i biblioteket. Koble delen til den i CadSHAPE hvis det stemmer – da brukes de eksakte målene derfra."]
                    let pc = j["pc"] as? Bool ?? true
                    if make == "holder" && pc { self.notes.append("Holderen regnes ut på PC-en nå – formet etter skannet, og den løftes rett opp.") }
                    if make == "cad" && pc { self.notes.append("Delene med mål lages i CadSHAPE nå – endre målene i panelet til høyre.") }
                    if !pc, let first = (result?["notes"] as? [String])?.first { self.notes.append(first) }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                case .failure(let e):
                    self.error = e.message
                }
            }
        }
    }
}
