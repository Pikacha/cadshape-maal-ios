import ARKit
import HoleKit
import RealityKit
import SwiftUI

/// A part (or the whole model) from CadSHAPE.
struct PhonePart: Identifiable, Hashable {
    var id: String
    var name: String
    var size: [Double]
    var reference: Bool
    var selected: Bool

    var sizeText: String { size.map { mm($0, digits: 0) }.joined(separator: " × ") + " mm" }
}

/// «Se delen i AR»: the part from CadSHAPE in real size where it is meant to go, hidden behind real
/// things (LiDAR mesh), and how much air there is to what is behind it – red where it goes in.
final class PartARModel: ObservableObject {
    @Published var project = ""
    @Published var parts: [PhonePart] = []
    @Published var chosen: String?
    @Published var loading = false
    @Published var error: String?
    @Published var placed = false
    @Published var clearance: Clearance?
    @Published var sent: String?

    let api: CadshapeClient?
    weak var arView: ARView?
    /// The part in RealityKit's local space (m, Y up), bottom at 0.
    private(set) var local: TriangleMesh?
    private var entity: ModelEntity?
    private var anchor: AnchorEntity?
    private var marks: AnchorEntity?
    private var samples: [SIMD3<Float>] = []
    private let queue = DispatchQueue(label: "cadshape.maal.clearance", qos: .userInitiated)
    private var checking = false
    private var lastCheck: TimeInterval = 0

    init(api: CadshapeClient?) {
        self.api = api
    }

    var chosenName: String {
        if chosen == "alle" { return project.isEmpty ? "Hele modellen" : project }
        return parts.first { $0.id == chosen }?.name ?? "Delen"
    }

    func loadParts() {
        guard let api else { error = "Koble til CadSHAPE først."; return }
        loading = true
        api.getJSON("api/live/phone/parts") { [weak self] r in
            guard let self else { return }
            self.loading = false
            switch r {
            case .success(let j):
                let result = j["result"] as? [String: Any] ?? [:]
                self.project = result["project"] as? String ?? ""
                self.parts = (result["parts"] as? [[String: Any]] ?? []).compactMap { p in
                    guard let id = p["id"] as? String, let name = p["name"] as? String else { return nil }
                    return PhonePart(id: id, name: name, size: (p["size"] as? [Double]) ?? [], reference: p["reference"] as? Bool ?? false, selected: p["selected"] as? Bool ?? false)
                }
                if self.parts.isEmpty { self.error = "Ingen deler i prosjektet på PC-en." }
                // The part selected on the PC first, else the first part that is not a reference.
                if self.chosen == nil, let first = self.parts.first(where: { $0.selected }) ?? self.parts.first(where: { !$0.reference }) ?? self.parts.first {
                    self.choose(first.id)
                }
            case .failure(let e):
                self.error = e.message
            }
        }
    }

    func choose(_ id: String) {
        guard let api else { return }
        chosen = id
        loading = true
        error = nil
        api.getData("api/live/phone/part", query: ["id": id]) { [weak self] r in
            guard let self else { return }
            self.loading = false
            switch r {
            case .success(let data):
                guard let mesh = parseBinarySTL(data), mesh.triangleCount > 0 else { self.error = "Kunne ikke lese delen."; return }
                if mesh.triangleCount > 400_000 { self.error = "Delen er for detaljert til AR (\(mesh.triangleCount) trekanter)."; return }
                self.setMesh(mesh)
            case .failure(let e):
                self.error = e.message
            }
        }
    }

    /// CadSHAPE (mm, Z up) → local (m, Y up), centred, bottom on 0.
    private func setMesh(_ cad: TriangleMesh) {
        guard let b = cad.bounds else { return }
        let shift = V3((b.min.x + b.max.x) / 2, (b.min.y + b.max.y) / 2, b.min.z)
        local = cad.mapped { cadToWorld($0 - shift) }
        samples = sampleVertices(local!, count: 1500).map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
        if let anchor { rebuild(on: anchor) }
    }

    private func makeEntity() -> ModelEntity? {
        guard let local else { return nil }
        let positions = local.vertices.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
        var normals = [SIMD3<Float>](repeating: SIMD3<Float>(0, 1, 0), count: positions.count)
        var i = 0
        while i + 2 < local.faces.count {
            let a = Int(local.faces[i]), b = Int(local.faces[i + 1]), c = Int(local.faces[i + 2])
            let n = simd_normalize(simd_cross(positions[b] - positions[a], positions[c] - positions[a]))
            if n.x.isFinite { normals[a] = n; normals[b] = n; normals[c] = n }
            i += 3
        }
        var desc = MeshDescriptor(name: "del")
        desc.positions = MeshBuffers.Positions(positions)
        desc.normals = MeshBuffers.Normals(normals)
        desc.primitives = .triangles(local.faces)
        guard let resource = try? MeshResource.generate(from: [desc]) else { return nil }
        let material = SimpleMaterial(color: UIColor(red: 0.95, green: 0.66, blue: 0.23, alpha: 0.82), roughness: 0.55, isMetallic: false)
        let e = ModelEntity(mesh: resource, materials: [material])
        e.generateCollisionShapes(recursive: false)
        return e
    }

    private func rebuild(on anchor: AnchorEntity) {
        entity?.removeFromParent()
        guard let e = makeEntity() else { error = "Kunne ikke tegne delen."; return }
        anchor.addChild(e)
        entity = e
        if let arView { arView.installGestures([.translation, .rotation], for: e) }
        placed = true
        clearance = nil
    }

    /// A tap on the picture: the part stands on that surface (wall, table, beam), bottom against it.
    func place(at point: CGPoint) {
        guard let arView, local != nil else { return }
        guard let hit = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first else {
            error = "Fant ingen flate der. Pek på en vegg, et bord eller en bjelke."
            return
        }
        error = nil
        anchor?.removeFromParent()
        let a = AnchorEntity(world: hit.worldTransform)
        arView.scene.addAnchor(a)
        anchor = a
        if marks == nil {
            let m = AnchorEntity(world: matrix_identity_float4x4)
            arView.scene.addAnchor(m)
            marks = m
        }
        rebuild(on: a)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// 90° round the surface's normal («Vri») or across it («Snu»), still standing on the surface.
    func turn(across: Bool) {
        guard let entity, let anchor else { return }
        let q = simd_quatf(angle: .pi / 2, axis: across ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0))
        entity.orientation = q * entity.orientation
        let b = entity.visualBounds(relativeTo: anchor)
        entity.position.y -= b.min.y
    }

    /// About four times a second: the part's points against the LiDAR depth (off the main thread).
    func check(_ frame: ARFrame) {
        guard placed, let entity, !checking, frame.timestamp - lastCheck > 0.25,
              let data = frame.sceneDepth ?? frame.smoothedSceneDepth else { return }
        checking = true
        lastCheck = frame.timestamp
        let m = entity.transformMatrix(relativeTo: nil)
        let world = samples.map { p -> V3 in
            let w = m * SIMD4<Float>(p.x, p.y, p.z, 1)
            return V3(Double(w.x), Double(w.y), Double(w.z))
        }
        let K = FrameReader.intrinsics(frame.camera)
        let pose = FrameReader.pose(frame.camera)
        let iw = Double(frame.camera.imageResolution.width), ih = Double(frame.camera.imageResolution.height)
        guard let dm = FrameReader.depth(data) else { checking = false; return }
        queue.async { [weak self] in
            let r = depthClearance(world, depth: dm, intrinsics: K, imageWidth: iw, imageHeight: ih, pose: pose)
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                self.clearance = r.checked > 20 ? r : nil
                self.showMarks(r.hits)
            }
        }
    }

    private func showMarks(_ hits: [V3]) {
        guard let marks else { return }
        for c in marks.children.map({ $0 }) { c.removeFromParent() }
        let red = SimpleMaterial(color: UIColor(red: 0.94, green: 0.39, blue: 0.36, alpha: 1), isMetallic: false)
        let dot = MeshResource.generateSphere(radius: 0.0025)
        for h in hits {
            let e = ModelEntity(mesh: dot, materials: [red])
            e.position = SIMD3<Float>(Float(h.x), Float(h.y), Float(h.z))
            marks.addChild(e)
        }
    }

    var clearanceText: String {
        guard placed else { return local == nil ? "Henter delen …" : "Trykk på flaten der delen skal sitte." }
        guard let c = clearance else { return "Hold telefonen 20–80 cm unna, så LiDAR ser bak delen." }
        if c.hitMM >= 1 { return "Går ca. \(mm(c.hitMM, digits: 0)) mm inn i det som er bak" }
        if let g = c.gapMM { return g < 1 ? "Ligger an – ingen luft å se" : "Ca. \(mm(g, digits: 0)) mm luft til det som er bak" }
        return "Fri – ingenting nærmere enn 5 cm bak delen"
    }

    var clearanceIsBad: Bool { (clearance?.hitMM ?? 0) >= 1 }

    /// What the phone saw, as a note in CadSHAPE.
    func report() {
        guard let api else { return }
        let text = "«\(chosenName)»: \(clearanceText.lowercased())."
        api.postJSON("api/live/scan", body: ["type": "ar", "text": text, "part": chosenName]) { [weak self] r in
            if case .failure(let e) = r { self?.error = e.message } else { self?.sent = "Sendt til CadSHAPE" }
        }
    }
}

struct PartARView: UIViewRepresentable {
    let model: PartARModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            view.environment.sceneUnderstanding.options.insert(.occlusion)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { config.frameSemantics.insert(.sceneDepth) }
        view.session.delegate = context.coordinator
        view.session.run(config)
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:))))
        model.arView = view
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        let model: PartARModel
        init(model: PartARModel) { self.model = model }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let view = g.view else { return }
            model.place(at: g.location(in: view))
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            model.check(frame)
        }
    }
}

struct PartARScreen: View {
    @ObservedObject var watch: PrintWatch
    @StateObject private var ar: PartARModel
    let close: () -> Void
    @State private var showCard = false

    init(model: MeasureModel, watch: PrintWatch, close: @escaping () -> Void) {
        self.watch = watch
        self.close = close
        _ar = StateObject(wrappedValue: PartARModel(api: model.api))
    }

    var body: some View {
        ZStack {
            PartARView(model: ar).ignoresSafeArea()
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Button(action: close) {
                        Image(systemName: "chevron.left").font(.headline).frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Tilbake")
                    Text(ar.chosen == nil ? "Se delen i AR" : "\(ar.chosenName), ekte størrelse")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    if ar.loading { ProgressView().padding(10).background(.ultraThinMaterial, in: Circle()) }
                }
                partChips
                Spacer()
                if let e = ar.error {
                    Text(e).font(.subheadline.weight(.semibold)).padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                bottom
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
        .foregroundStyle(.white)
        .onAppear { ar.loadParts() }
        .sheet(isPresented: $showCard) { ApprovalSheet(watch: watch) }
        .onChange(of: ar.chosen) { watch.lastPartLabel = ar.chosenName }
    }

    private var partChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ar.parts) { p in
                    chip(p.name, sub: p.sizeText, on: ar.chosen == p.id) { ar.choose(p.id) }
                }
                if ar.parts.count > 1 {
                    chip("Hele modellen", sub: "med det den sitter på", on: ar.chosen == "alle") { ar.choose("alle") }
                }
            }
        }
    }

    private func chip(_ title: String, sub: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(sub).font(.caption).opacity(0.75)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(on ? AnyShapeStyle(accent.opacity(0.9)) : AnyShapeStyle(.ultraThinMaterial), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(on ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }

    private var bottom: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(ar.clearanceText, systemImage: ar.clearanceIsBad ? "exclamationmark.triangle.fill" : "ruler")
                .font(.headline)
                .foregroundStyle(ar.clearanceIsBad ? Color(red: 1, green: 0.56, blue: 0.53) : Color.white)
            if ar.placed {
                HStack(spacing: 8) {
                    Button { ar.turn(across: false) } label: { Label("Vri 90°", systemImage: "rotate.right") }.buttonStyle(SecondaryStyle())
                    Button { ar.turn(across: true) } label: { Label("Snu", systemImage: "arrow.triangle.2.circlepath") }.buttonStyle(SecondaryStyle())
                }
                Text("Dra for å flytte, vri med to fingre. Trykk et annet sted for å sette den der.").font(.footnote).opacity(0.75)
                HStack(spacing: 8) {
                    Button { ar.report() } label: { Label(ar.sent ?? "Send til CadSHAPE", systemImage: "paperplane") }.buttonStyle(SecondaryStyle())
                    if watch.card?.state == "venter" {
                        Button { showCard = true } label: { Label("Godkjenn print", systemImage: "play.fill") }.buttonStyle(PrimaryStyle())
                    }
                }
            }
        }
        .modifier(GlassPanel())
    }
}
