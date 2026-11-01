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
    /// «Skann → holder»: CadSHAPE makes a holder shaped after the scan as soon as it arrives.
    @Published var makeHolder = true
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
        mesh = cad
        modelURL = url
        step = .done
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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
        let holder = makeHolder
        Task { [weak self] in
            let stl = await Task.detached { binarySTL(mesh, header: "CadSHAPE Maal - Object Capture").base64EncodedString() }.value
            let body: [String: Any] = [
                "type": "mesh", "role": "ting", "name": name, "stl": stl, "make": holder ? "holder" : "none",
                "size": [s.x, s.y, s.z].map { ($0 * 10).rounded() / 10 },
                "notes": ["3D-skann fra telefonen (Object Capture, \(mesh.triangleCount) trekanter). Mål kritiske hull med Hull-modus."],
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
                    if holder { self.notes.append("Holderen regnes ut på PC-en nå – formet etter skannet, og den løftes rett opp.") }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                case .failure(let e):
                    self.error = e.message
                }
            }
        }
    }
}

/// Every triangle of a USDZ/OBJ as one mesh in the file's own space (metres for Object Capture).
func readModel(_ url: URL) -> TriangleMesh? {
    let asset = MDLAsset(url: url)
    var vertices: [V3] = []
    var faces: [UInt32] = []
    for case let mesh as MDLMesh in asset.childObjects(of: MDLMesh.self) {
        let m = MDLTransform.globalTransform(with: mesh, atTime: 0)
        guard let attr = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else { continue }
        let base = UInt32(vertices.count)
        for i in 0..<mesh.vertexCount {
            let p = attr.dataStart.advanced(by: i * attr.stride).assumingMemoryBound(to: Float.self)
            let w = m * SIMD4<Float>(p[0], p[1], p[2], 1)
            vertices.append(V3(Double(w.x), Double(w.y), Double(w.z)))
        }
        for sub in (mesh.submeshes as? [MDLSubmesh]) ?? [] where sub.geometryType == .triangles {
            let map = sub.indexBuffer.map()
            let n = sub.indexCount
            switch sub.indexType {
            case .uInt32:
                let p = map.bytes.assumingMemoryBound(to: UInt32.self)
                for k in 0..<n { faces.append(base + p[k]) }
            case .uInt16:
                let p = map.bytes.assumingMemoryBound(to: UInt16.self)
                for k in 0..<n { faces.append(base + UInt32(p[k])) }
            case .uInt8:
                let p = map.bytes.assumingMemoryBound(to: UInt8.self)
                for k in 0..<n { faces.append(base + UInt32(p[k])) }
            default:
                continue
            }
        }
    }
    return vertices.isEmpty || faces.isEmpty ? nil : TriangleMesh(vertices: vertices, faces: faces)
}

/// The finished model, turnable with a finger (SceneKit shows the USDZ with its colours).
struct ModelPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = try? SCNScene(url: url, options: nil)
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = true
        v.backgroundColor = UIColor(red: 0.11, green: 0.13, blue: 0.17, alpha: 1)
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}

struct CaptureScreen: View {
    @StateObject private var cap: CaptureModel
    @ObservedObject private var model: MeasureModel
    @State private var confirmClose = false
    @State private var connect = false
    let close: () -> Void

    init(model: MeasureModel, close: @escaping () -> Void) {
        self.close = close
        self.model = model
        _cap = StateObject(wrappedValue: CaptureModel(api: model.api))
    }

    var body: some View {
        ZStack {
            if let session = cap.session {
                if cap.passDone && cap.step == .capturing {
                    // Between rounds: what has been covered so far (Apple's point cloud, turnable).
                    ObjectCapturePointCloudView(session: session).ignoresSafeArea()
                } else {
                    ObjectCaptureView(session: session).ignoresSafeArea()
                }
            } else {
                ground.ignoresSafeArea()
            }
            VStack(spacing: 10) {
                HStack(alignment: .top) {
                    CloseButton(label: "Avbryt skanningen") {
                        // Pictures or a model that has not been sent would be lost: ask first.
                        if cap.shots > 0 && cap.sent == nil { confirmClose = true } else { leave() }
                    }
                    Spacer()
                    if cap.step == .capturing {
                        Text("Runde \(cap.passes)/\(CaptureModel.goodRounds) · \(cap.roundShots) bilder")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                Spacer()
                panel
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
        .foregroundStyle(.white)
        .confirmationDialog("Avbryte skanningen?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Avbryt og slett bildene", role: .destructive) { leave() }
            Button("Fortsett", role: .cancel) {}
        } message: {
            Text("Bildene og modellen er ikke sendt, og blir slettet.")
        }
        // Its own sheet: the home screen's «Koble til» sheet sits under this full-screen cover.
        .sheet(isPresented: $connect) {
            SettingsSheet(model: model, allowQR: false) { connect = false }
        }
        .onAppear {
            cap.start()
            // Walking round the thing and building the model take minutes: the screen must not lock.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        // The photos (often several hundred MB) and the model go with the screen.
        .onDisappear {
            cap.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func leave() {
        cap.cancel()
        close()
    }

    @ViewBuilder private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if cap.step != .unsupported {
                ScanSteps(current: stepIndex)
            }
            switch cap.step {
            case .unsupported:
                Text("Denne telefonen kan ikke 3D-skanne").font(.headline)
                Text("3D-skanning krever en iPhone med LiDAR (Pro-modell) og iOS 17.").font(.subheadline).foregroundStyle(.secondary)
            case .starting:
                HStack { ProgressView(); Text("Starter kameraet …") }
            case .ready:
                Text("Legg tingen på et bord med plass rundt").font(.headline)
                Text("Matt underlag og jevnt lys gir best modell. Sikt på tingen. Skannet gir formen med noen millimeters nøyaktighet.").font(.subheadline).foregroundStyle(.secondary)
                Button("Finn tingen") { cap.detect() }.buttonStyle(PrimaryStyle())
            case .detecting:
                Text("Juster boksen rundt tingen").font(.headline)
                Text("Dra i hjørnene til boksen så vidt rommer den.").font(.subheadline).foregroundStyle(.secondary)
                Button("Start skanningen") { cap.capture() }.buttonStyle(PrimaryStyle())
            case .capturing:
                rounds
                if cap.passDone {
                    Text("Runde \(cap.passes) av \(CaptureModel.goodRounds) er ferdig").font(.headline)
                    Text(nextRoundText).font(.subheadline).foregroundStyle(.secondary)
                    if cap.passes < CaptureModel.goodRounds {
                        Button("Neste runde") { cap.newPass() }.buttonStyle(PrimaryStyle())
                        HStack(spacing: 8) {
                            Button("Lag modellen nå") { cap.finish() }.buttonStyle(SecondaryStyle())
                            Button("Snu tingen") { cap.flip() }.buttonStyle(SecondaryStyle())
                        }
                    } else {
                        Button("Lag modellen") { cap.finish() }.buttonStyle(PrimaryStyle())
                        Button("En runde til") { cap.newPass() }.buttonStyle(SecondaryStyle())
                    }
                } else {
                    Text(roundTitle).font(.headline)
                    message
                    HStack(spacing: 8) {
                        if cap.canShoot {
                            Button("Ta bilde") { cap.shoot() }.buttonStyle(SecondaryStyle())
                        }
                        if cap.shots >= 20 {
                            Button("Lag modellen nå") { cap.finish() }.buttonStyle(SecondaryStyle())
                        }
                    }
                    if cap.stalled && cap.shots < 20 {
                        Button("Start kameraet på nytt") { cap.again() }.buttonStyle(SecondaryStyle())
                    }
                }
            case .finishing:
                HStack { ProgressView(); Text("Lagrer bildene …") }
            case .reconstructing(let f):
                Text("Lager 3D-modellen på telefonen").font(.headline)
                if f < 0.01 {
                    ProgressView().tint(accent).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView(value: f).tint(accent)
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("\(Int(f * 100)) % · \(cap.elapsedText) · vanligvis 1–3 min. Ikke lukk appen.")
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
            case .done:
                done
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(bad)
                Button("Prøv igjen") { cap.again() }.buttonStyle(PrimaryStyle())
            }
            if cap.session != nil, cap.step != .capturing, let line = cap.error ?? cap.trackingHint {
                Label(line, systemImage: cap.error != nil ? "exclamationmark.circle" : "camera.metering.unknown")
                    .font(.subheadline)
                    .foregroundStyle(cap.error != nil ? bad : .white)
                    .lineLimit(3)
            }
        }
        .modifier(GlassPanel())
    }

    /// One message while walking round: error > no progress > camera advice > the instruction.
    @ViewBuilder private var message: some View {
        if let e = cap.error {
            Label(e, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(bad).lineLimit(3)
        } else if cap.stalled {
            Label("Ingen nye bilder. Gå videre rundt tingen og hold den midt i bildet\(cap.canShoot ? ", eller trykk «Ta bilde»" : "").",
                  systemImage: "pause.circle").font(.subheadline).foregroundStyle(warn).lineLimit(3)
        } else if let hint = cap.trackingHint {
            Label(hint, systemImage: "camera.metering.unknown").font(.subheadline).lineLimit(3)
        } else {
            Text("Gå sakte rundt tingen. Runden er ferdig når ringen på bakken er full.").font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
        }
    }

    private var stepIndex: Int {
        switch cap.step {
        case .unsupported, .starting, .ready, .detecting: return 0
        case .capturing: return 1
        case .finishing, .reconstructing: return 2
        case .done: return cap.sent == nil ? 3 : 4
        case .failed: return cap.mesh == nil ? 1 : 3
        }
    }

    /// The three rounds: the current one fills as pictures come in (a round is ~30–50 pictures).
    private var rounds: some View {
        HStack(spacing: 6) {
            ForEach(1...max(CaptureModel.goodRounds, cap.passes), id: \.self) { r in
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(accent).frame(width: g.size.width * fill(r))
                    }
                }
                .frame(height: 6)
            }
        }
        .animation(.easeOut(duration: 0.3), value: cap.shots)
        .accessibilityElement()
        .accessibilityLabel("Runde \(cap.passes) av \(CaptureModel.goodRounds), \(cap.roundShots) bilder")
    }

    private func fill(_ round: Int) -> Double {
        if round < cap.passes { return 1 }
        if round > cap.passes { return 0 }
        return cap.passDone ? 1 : min(0.9, Double(cap.roundShots) / 40)
    }

    private var roundTitle: String {
        switch cap.passes {
        case 1: return "Runde 1: rundt tingen, litt ovenfra"
        case 2: return "Runde 2: rundt tingen, i høyde med den"
        default: return "Runde \(cap.passes): lavt rundt tingen"
        }
    }

    private var nextRoundText: String {
        switch cap.passes {
        case 1: return "Neste: en runde i høyde med tingen. «Snu tingen» bare hvis bunnen må med. Bildet bak viser hva som er skannet."
        case 2: return "Neste: en lav runde. Tre runder gir klart best modell."
        default: return "Tingen er sett fra alle kanter. Modellen lages på telefonen (1–3 min)."
        }
    }

    @ViewBuilder private var done: some View {
        if let url = cap.modelURL {
            ModelPreview(url: url)
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        Text(cap.sizeText).font(.title3.bold()).monospacedDigit()
        // On the phone Apple builds models at reduced detail: right for holders and pockets, not for tight fits.
        Label("Formen er nøyaktig til noen millimeter – bra for holdere og lommer. Hull og kanter som skal sitte stramt: mål dem med «Hull».",
              systemImage: "ruler")
            .font(.footnote).foregroundStyle(warn)
        if let sent = cap.sent {
            Label(sent, systemImage: "checkmark.circle.fill").foregroundStyle(good).font(.headline)
            ForEach(cap.notes, id: \.self) { n in
                Label(n, systemImage: "books.vertical").font(.subheadline)
            }
            Button("Ferdig") { leave() }.buttonStyle(PrimaryStyle())
            Button("Skann en til") { cap.again() }.buttonStyle(SecondaryStyle())
        } else {
            TextField("Navn", text: $cap.name)
                .padding(12)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Picker("Hva lager vi?", selection: $cap.makeHolder) {
                Text("Holder rundt den").tag(true)
                Text("Bare modellen").tag(false)
            }
            .pickerStyle(.segmented)
            if let e = cap.error {
                Label(e, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(bad)
            }
            if !model.connected {
                HStack {
                    Label("Ikke koblet til CadSHAPE", systemImage: "wifi.slash").font(.subheadline)
                    Spacer()
                    Button("Koble til") { connect = true }.buttonStyle(ChipStyle())
                }
            }
            Button {
                cap.send()
            } label: {
                Label(cap.sending ? "Sender …" : "Send til CadSHAPE", systemImage: "paperplane.fill")
            }
            .buttonStyle(PrimaryStyle())
            .disabled(cap.sending || cap.api == nil)
            Button("Skann på nytt") { cap.again() }.buttonStyle(SecondaryStyle())
        }
    }
}

/// Finn · Skann · Lag modell · Send: where in the whole 3D scan we are.
struct ScanSteps: View {
    let current: Int
    private let names = ["Finn", "Skann", "Lag modell", "Send"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(names.indices, id: \.self) { i in
                HStack(spacing: 4) {
                    Image(systemName: i < current ? "checkmark.circle.fill" : (i == current ? "circle.inset.filled" : "circle"))
                        .foregroundStyle(i <= current ? accent : Color.white.opacity(0.35))
                    Text(names[i])
                        .foregroundStyle(i == current ? .white : .secondary)
                }
                if i < names.count - 1 {
                    Rectangle().fill(Color.white.opacity(0.2)).frame(height: 1)
                }
            }
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Steg \(min(current + 1, names.count)) av \(names.count): \(names[min(current, names.count - 1)])")
    }
}
