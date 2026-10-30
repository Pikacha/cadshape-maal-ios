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

    @Published var step: Step = .starting
    @Published var session: ObjectCaptureSession?
    @Published var shots = 0
    @Published var passDone = false
    @Published var passes = 1
    @Published var mesh: TriangleMesh?
    @Published var modelURL: URL?
    @Published var name = ""
    @Published var sending = false
    @Published var sent: String?
    @Published var notes: [String] = []
    @Published var error: String?

    let api: CadshapeClient?
    private var folder: URL?
    private var timer: Timer?
    private var watching: Task<Void, Never>?

    init(api: CadshapeClient?) {
        self.api = api
        let f = DateFormatter()
        f.dateFormat = "d.M HH:mm"
        name = "Skann \(f.string(from: Date()))"
    }

    private var images: URL? { folder?.appendingPathComponent("Bilder", isDirectory: true) }
    private var checkpoints: URL? { folder?.appendingPathComponent("Underveis", isDirectory: true) }

    func start() {
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
        s.start(imagesDirectory: images, configuration: cfg)
        session = s
        shots = 0
        passes = 1
        passDone = false
        watching = Task { [weak self] in
            for await st in s.stateUpdates {
                self?.changed(st)
            }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        guard let s = session else { return }
        shots = s.numberOfShotsTaken
        passDone = s.userCompletedScanPass
    }

    private func changed(_ st: ObjectCaptureSession.CaptureState) {
        switch st {
        case .initializing: step = .starting
        case .ready: step = .ready
        case .detecting: step = .detecting
        case .capturing: step = .capturing
        case .finishing: step = .finishing
        case .completed:
            // The capture's camera must be gone before the model is made (memory).
            timer?.invalidate()
            session = nil
            reconstruct()
        case .failed(let e):
            timer?.invalidate()
            session = nil
            step = .failed("Skanningen stoppet: \(e.localizedDescription)")
        @unknown default:
            break
        }
    }

    func detect() { _ = session?.startDetecting() }
    func capture() { session?.startCapturing() }
    func newPass() {
        session?.beginNewScanPass()
        passes += 1
    }
    func flip() {
        session?.beginNewScanPassAfterFlip()
        passes += 1
    }
    func finish() { session?.finish() }

    func cancel() {
        session?.cancel()
        session = nil
        timer?.invalidate()
        watching?.cancel()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func again() {
        cancel()
        mesh = nil
        modelURL = nil
        sent = nil
        notes = []
        error = nil
        step = .starting
        start()
    }

    /// The model is made on the phone (Apple's photogrammetry), as USDZ.
    private func reconstruct() {
        guard let images, let checkpoints, let folder else { return }
        step = .reconstructing(0)
        let out = folder.appendingPathComponent("modell.usdz")
        Task { [weak self] in
            do {
                var cfg = PhotogrammetrySession.Configuration()
                cfg.checkpointDirectory = checkpoints
                let ps = try PhotogrammetrySession(input: images, configuration: cfg)
                try ps.process(requests: [.modelFile(url: out)])
                for try await output in ps.outputs {
                    switch output {
                    case .requestProgress(_, let fraction):
                        self?.step = .reconstructing(fraction)
                    case .requestError(_, let error):
                        throw error
                    case .processingComplete:
                        await self?.loaded(out)
                    default:
                        break
                    }
                }
            } catch {
                self?.step = .failed("Kunne ikke lage modellen: \(error.localizedDescription). Prøv med mer lys og flere bilder.")
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
        Task { [weak self] in
            let stl = await Task.detached { binarySTL(mesh, header: "CadSHAPE Maal - Object Capture").base64EncodedString() }.value
            let body: [String: Any] = [
                "type": "mesh", "role": "ting", "name": name, "stl": stl,
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
    let close: () -> Void

    init(model: MeasureModel, close: @escaping () -> Void) {
        self.close = close
        _cap = StateObject(wrappedValue: CaptureModel(api: model.api))
    }

    var body: some View {
        ZStack {
            if let session = cap.session {
                ObjectCaptureView(session: session).ignoresSafeArea()
            } else {
                ground.ignoresSafeArea()
            }
            VStack(spacing: 10) {
                HStack {
                    Button {
                        cap.cancel()
                        close()
                    } label: {
                        Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Avbryt skanningen")
                    Spacer()
                    if cap.step == .capturing || cap.step == .detecting {
                        Text("\(cap.shots) bilder, runde \(cap.passes)")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
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
        .onAppear { cap.start() }
        .onDisappear { if cap.step != .done { cap.cancel() } }
    }

    @ViewBuilder private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch cap.step {
            case .unsupported:
                Text("Denne telefonen kan ikke 3D-skanne").font(.headline)
                Text("Object Capture krever en iPhone med LiDAR og iOS 17.").font(.subheadline).opacity(0.8)
            case .starting:
                HStack { ProgressView(); Text("Starter kameraet …") }
            case .ready:
                Text("Legg tingen på et bord med plass rundt").font(.headline)
                Text("Matt underlag og jevnt lys gir best modell. Sikt på tingen.").font(.subheadline).opacity(0.8)
                Button("Finn tingen") { cap.detect() }.buttonStyle(PrimaryStyle())
            case .detecting:
                Text("Juster boksen rundt tingen").font(.headline)
                Text("Dra i hjørnene til boksen så vidt rommer den.").font(.subheadline).opacity(0.8)
                Button("Start skanningen") { cap.capture() }.buttonStyle(PrimaryStyle())
            case .capturing:
                if cap.passDone {
                    Text("Runde \(cap.passes) er ferdig").font(.headline)
                    Text(cap.passes == 1 ? "En runde til, lavere ned, gir sidene og undersiden. Eller snu tingen for bunnen." : "Har du sett tingen fra alle kanter, kan du lage modellen nå.").font(.subheadline).opacity(0.8)
                    HStack(spacing: 8) {
                        Button("Ny runde") { cap.newPass() }.buttonStyle(SecondaryStyle())
                        Button("Snu den") { cap.flip() }.buttonStyle(SecondaryStyle())
                    }
                    Button("Ferdig, lag modellen") { cap.finish() }.buttonStyle(PrimaryStyle())
                } else {
                    Text("Gå sakte rundt tingen").font(.headline)
                    Text("Hold avstanden og la ringen fylle seg. Telefonen tar bildene selv.").font(.subheadline).opacity(0.8)
                    if cap.shots > 20 {
                        Button("Ferdig nå") { cap.finish() }.buttonStyle(SecondaryStyle())
                    }
                }
            case .finishing:
                HStack { ProgressView(); Text("Lagrer bildene …") }
            case .reconstructing(let f):
                Text("Lager 3D-modellen på telefonen").font(.headline)
                ProgressView(value: f).tint(accent)
                Text("\(Int(f * 100)) %. Det tar gjerne 1–3 minutter. Hold appen åpen.").font(.subheadline).opacity(0.8)
            case .done:
                done
            case .failed(let message):
                Text(message).font(.subheadline.weight(.semibold))
                Button("Prøv igjen") { cap.again() }.buttonStyle(PrimaryStyle())
            }
        }
        .modifier(GlassPanel())
    }

    @ViewBuilder private var done: some View {
        if let url = cap.modelURL {
            ModelPreview(url: url)
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        Text(cap.sizeText).font(.title3.bold()).monospacedDigit()
        Text("Skannet er en referanse for formen. Mål hull og kanter som må passe nøyaktig med Hull-modus.").font(.footnote).opacity(0.75)
        if let sent = cap.sent {
            Label(sent, systemImage: "checkmark.circle.fill").foregroundStyle(good).font(.headline)
            ForEach(cap.notes, id: \.self) { n in
                Label(n, systemImage: "books.vertical").font(.subheadline)
            }
            Text("Lag holder, lokk eller lomme rundt den i CadSHAPE – den er låst og printes ikke.").font(.footnote).opacity(0.75)
            Button("Skann en til") { cap.again() }.buttonStyle(SecondaryStyle())
        } else {
            TextField("Navn", text: $cap.name)
                .textFieldStyle(.roundedBorder)
                .foregroundStyle(.black)
            if let e = cap.error { Text(e).font(.subheadline).foregroundStyle(.red) }
            Button {
                cap.send()
            } label: {
                Label(cap.sending ? "Sender …" : "Send til CadSHAPE", systemImage: "paperplane.fill")
            }
            .buttonStyle(PrimaryStyle())
            .disabled(cap.sending)
            Button("Skann på nytt") { cap.again() }.buttonStyle(SecondaryStyle())
        }
    }
}
