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
    @Published var sending = false
    /// Said under the part when it was thinned out to draw smoothly.
    @Published var note: String?

    private let current: () -> CadshapeClient?
    /// Always the connection the app has now (it can switch while this screen is open).
    var api: CadshapeClient? { current() }
    weak var arView: ARView?
    /// The part in RealityKit's local space (m, Y up), bottom at 0.
    private(set) var local: TriangleMesh?
    private var entity: ModelEntity?
    /// The part's RealityKit mesh, made once per part (placing it again reuses it).
    private var resource: MeshResource?
    /// The drag/twist gestures on the part now – removed before new ones go on.
    private var gestures: [EntityGestureRecognizer] = []
    private var anchor: AnchorEntity?
    private var marks: AnchorEntity?
    private var samples: [SIMD3<Float>] = []
    private let queue = DispatchQueue(label: "cadshape.maal.clearance", qos: .userInitiated)
    private var checking = false
    private var lastCheck: TimeInterval = 0
    /// Whether each of the last three checks saw enough points go in (one noisy check is not a hit).
    private var hitHistory: [Bool] = []
    /// Bumped for every part asked for: an answer for an older one is dropped.
    private var request = 0
    /// Bumped every time the part is put down again: a check of the old place is dropped.
    private var placement = 0
    private var sentToken = 0
    /// More triangles than this are thinned out for drawing (the clearance check uses the whole part).
    static let maxDrawnTriangles = 150_000

    init(api: @escaping @autoclosure () -> CadshapeClient?) {
        current = api
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
                self.error = nil
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
        guard let api else { error = "Koble til CadSHAPE først."; return }
        chosen = id
        loading = true
        error = nil
        request += 1
        let asked = request
        api.getData("api/live/phone/part", query: ["id": id]) { [weak self] r in
            // Answers can come in another order than asked: only the part asked for last counts.
            guard let self, self.request == asked, self.chosen == id else { return }
            switch r {
            case .success(let data):
                // Reading and preparing a big part takes a while: not on the main thread (the picture would freeze).
                DispatchQueue.global(qos: .userInitiated).async {
                    let prepared = PartARModel.prepare(data)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.request == asked, self.chosen == id else { return }
                        self.loading = false
                        switch prepared {
                        case .success(let p): self.show(p)
                        case .failure(let e): self.error = e.message
                        }
                    }
                }
            case .failure(let e):
                self.loading = false
                self.error = e.message
            }
        }
    }

    /// Off the main thread: CadSHAPE (mm, Z up) → local (m, Y up), centred, bottom on 0, and the
    /// triangles to draw – every n-th one when there are very many.
    static func prepare(_ data: Data) -> Result<PreparedPart, PartFailure> {
        guard let cad = parseBinarySTL(data), cad.triangleCount > 0, let box = cad.bounds else {
            return .failure(PartFailure(message: "Kunne ikke lese delen."))
        }
        let total = cad.triangleCount
        if total > 1_000_000 { return .failure(PartFailure(message: "Delen er for detaljert til AR (\(total) trekanter).")) }
        let shift = V3((box.min.x + box.max.x) / 2, (box.min.y + box.max.y) / 2, box.min.z)
        let local = cad.mapped { cadToWorld($0 - shift) }
        func f(_ v: V3) -> SIMD3<Float> { SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z)) }
        let samples = sampleVertices(local, count: 1500).map(f)
        let step = max(1, (total + maxDrawnTriangles - 1) / maxDrawnTriangles)
        let vs = local.vertices
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        positions.reserveCapacity(3 * (total / step + 1))
        normals.reserveCapacity(3 * (total / step + 1))
        var t = 0
        while t < total {
            let a = Int(local.faces[3 * t]), b = Int(local.faces[3 * t + 1]), c = Int(local.faces[3 * t + 2])
            t += step
            guard a < vs.count, b < vs.count, c < vs.count else { continue }
            let pa = f(vs[a]), pb = f(vs[b]), pc = f(vs[c])
            let n = simd_normalize(simd_cross(pb - pa, pc - pa))
            let nn = (n.x.isFinite && n.y.isFinite && n.z.isFinite) ? n : SIMD3<Float>(0, 1, 0)
            positions.append(pa); positions.append(pb); positions.append(pc)
            normals.append(nn); normals.append(nn); normals.append(nn)
        }
        if positions.isEmpty { return .failure(PartFailure(message: "Kunne ikke lese delen.")) }
        return .success(PreparedPart(local: local, samples: samples, positions: positions, normals: normals, total: total, drawn: positions.count / 3))
    }

    /// On the main thread: the prepared arrays become RealityKit's mesh (only this has to be here).
    private func show(_ p: PreparedPart) {
        var desc = MeshDescriptor(name: "del")
        desc.positions = MeshBuffers.Positions(p.positions)
        desc.normals = MeshBuffers.Normals(p.normals)
        desc.primitives = .triangles(Array(0..<UInt32(p.positions.count)))
        guard let made = try? MeshResource.generate(from: [desc]) else { error = "Kunne ikke tegne delen."; return }
        resource = made
        local = p.local
        samples = p.samples
        note = p.drawn < p.total ? "Forenklet for AR: viser \(p.drawn) av \(p.total) trekanter. Klaringen sjekkes mot hele delen." : nil
        if let anchor { rebuild(on: anchor) }
    }

    private func makeEntity() -> ModelEntity? {
        guard let resource else { return nil }
        let material = SimpleMaterial(color: UIColor(red: 0.95, green: 0.66, blue: 0.23, alpha: 0.82), roughness: 0.55, isMetallic: false)
        let e = ModelEntity(mesh: resource, materials: [material])
        e.generateCollisionShapes(recursive: false)
        return e
    }

    private func rebuild(on anchor: AnchorEntity) {
        entity?.removeFromParent()
        entity = nil
        guard let e = makeEntity() else { error = "Kunne ikke tegne delen."; return }
        anchor.addChild(e)
        entity = e
        if let arView {
            // Each new part or place would otherwise stack another set of drag/twist gestures.
            for g in gestures { arView.removeGestureRecognizer(g) }
            gestures = arView.installGestures([.translation, .rotation], for: e)
        }
        placed = true
        placement += 1
        hitHistory = []
        clearance = nil
        showMarks([])
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
              let data = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
        checking = true
        lastCheck = frame.timestamp
        let at = placement
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
            let r = steadyClearance(world, depth: dm, intrinsics: K, imageWidth: iw, imageHeight: ih, pose: pose)
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                // Placed again or another part meanwhile: this answer is about the old one.
                guard at == self.placement else { return }
                self.take(r.clearance, hitCount: r.hitCount)
            }
        }
    }

    /// «Goes in» only when enough points go in (≥ 10, and ≥ 3 % of those checked) in two of the
    /// last three checks – a few noisy LiDAR pixels for a quarter of a second are not a hit.
    private func take(_ r: Clearance, hitCount: Int) {
        guard r.checked > 20 else {
            clearance = nil
            showMarks([])
            return
        }
        let enough = hitCount >= max(10, Int((Double(r.checked) * 0.03).rounded(.up)))
        hitHistory.append(enough)
        if hitHistory.count > 3 { hitHistory.removeFirst(hitHistory.count - 3) }
        var c = r
        if hitHistory.filter({ $0 }).count < 2 {
            // Points just behind the surface without a steady hit: it rests against it.
            if hitCount > 0, c.gapMM == nil { c.gapMM = 0 }
            c.hitMM = 0
            c.hits = []
        }
        clearance = c
        showMarks(c.hits)
    }

    private func showMarks(_ hits: [V3]) {
        guard let marks else { return }
        for c in marks.children.map({ $0 }) { c.removeFromParent() }
        let red = SimpleMaterial(color: UIColor(red: 0.94, green: 0.39, blue: 0.36, alpha: 1), isMetallic: false)
        let dot = MeshResource.generateSphere(radius: 0.0025)
        // Every fourth of a second: a few dozen dots say where, more only cost frames.
        let step = max(1, hits.count / 60)
        for h in stride(from: 0, to: hits.count, by: step).map({ hits[$0] }) {
            let e = ModelEntity(mesh: dot, materials: [red])
            e.position = SIMD3<Float>(Float(h.x), Float(h.y), Float(h.z))
            marks.addChild(e)
        }
    }

    var clearanceText: String {
        guard placed else {
            if local == nil { return api == nil ? "Ikke koblet til CadSHAPE." : "Henter delen …" }
            return "Trykk på flaten der delen skal sitte."
        }
        guard let c = clearance else { return "Hold telefonen 20–80 cm unna, så LiDAR ser bak delen." }
        if c.hitMM >= 1 { return "Går ca. \(mm(c.hitMM, digits: 0)) mm inn i det som er bak" }
        if let g = c.gapMM { return g < 1 ? "Ligger an – ingen luft å se" : "Ca. \(mm(g, digits: 0)) mm luft til det som er bak" }
        return "Fri – ingenting nærmere enn 5 cm bak delen"
    }

    var clearanceIsBad: Bool { (clearance?.hitMM ?? 0) >= 1 }

    /// What the phone saw, as a note in CadSHAPE.
    func report() {
        guard let api else { error = "Koble til CadSHAPE først."; return }
        guard !sending else { return }
        let text = "«\(chosenName)»: \(clearanceText.lowercased())."
        sending = true
        error = nil
        api.postJSON("api/live/scan", body: ["type": "ar", "text": text, "part": chosenName]) { [weak self] r in
            guard let self else { return }
            self.sending = false
            switch r {
            case .success:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self.sent = "Sendt til CadSHAPE"
                self.sentToken += 1
                let token = self.sentToken
                // A moment later it can be sent again (after moving the part, say).
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    guard let self, self.sentToken == token else { return }
                    self.sent = nil
                }
            case .failure(let e):
                self.error = e.message
            }
        }
    }
}

/// A part ready to draw, worked out off the main thread.
struct PreparedPart {
    /// The whole part in RealityKit's local space (m, Y up), bottom at 0.
    var local: TriangleMesh
    /// Corners for the clearance check (from the whole part, not only the drawn triangles).
    var samples: [SIMD3<Float>]
    /// Three corners per drawn triangle, with that triangle's normal.
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var total: Int
    var drawn: Int
}

struct PartFailure: Error {
    var message: String
}

/// Like HoleKit's `depthClearance`, but steadier for this screen: only depth ARKit is sure of
/// (confidence 2), a tolerance that grows with distance (LiDAR noise is about 1 % of the distance),
/// and percentiles instead of the single deepest / closest point – one noisy pixel decides nothing.
/// The hit depth is the 90th percentile of the points that go in, the air the 10th percentile of
/// the points in front. `hitCount` is how many points went in (the marks are capped at `maxHits`).
func steadyClearance(_ points: [V3], depth dm: DepthMap, intrinsics K: Intrinsics, imageWidth: Double, imageHeight: Double, pose: CameraPose,
                     near: Double = 0.03, maxHits: Int = 24) -> (clearance: Clearance, hitCount: Int) {
    let sx = imageWidth / Double(dm.width)
    let sy = imageHeight / Double(dm.height)
    var airs: [Double] = []
    var hits: [(V3, Double)] = []
    var checked = 0
    for p in points {
        let c = pose.camera(p)
        if c.z < 0.08 { continue }
        let u = (K.fx * c.x / c.z + K.cx) / sx
        let v = (K.fy * c.y / c.z + K.cy) / sy
        guard u.isFinite, v.isFinite, u >= 0, v >= 0, u < Double(dm.width), v < Double(dm.height) else { continue }
        let k = Int(v) * dm.width + Int(u)
        let z = dm.depth[k]
        guard z.isFinite, z > 0.05, z < 10 else { continue }
        if let conf = dm.confidence, conf[k] < 2 { continue }
        checked += 1
        let real = Double(z)
        let behind = c.z - real
        let tolerance = 0.004 + 0.01 * real
        if behind > tolerance && behind < near + tolerance {
            hits.append((p, behind))
        } else if behind <= tolerance {
            let air = max(0, -behind)
            if air < 0.05 { airs.append(air) }
        }
    }
    func percentile(_ values: [Double], _ q: Double) -> Double {
        let s = values.sorted()
        return s[min(s.count - 1, max(0, Int((Double(s.count - 1) * q).rounded())))]
    }
    let hitDepth = hits.isEmpty ? 0 : percentile(hits.map { $0.1 }, 0.9)
    let gap: Double? = airs.isEmpty ? nil : percentile(airs, 0.1)
    let marks = hits.sorted { $0.1 > $1.1 }.prefix(maxHits).map { $0.0 }
    return (Clearance(gapMM: gap.map { $0 * 1000 }, hitMM: hitDepth * 1000, hits: Array(marks), checked: checked), hits.count)
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
        // Smoothed depth (averaged over a few frames) for the clearance: steadier than the raw one.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
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
    /// The app's connection: «Koble til» opens its settings from here. Not observed – it changes
    /// many times a second while measuring, and this screen redraws often enough by itself.
    let measure: MeasureModel
    @StateObject private var ar: PartARModel
    let close: () -> Void
    @State private var showCard = false
    @State private var connecting = false

    init(model: MeasureModel, watch: PrintWatch, close: @escaping () -> Void) {
        self.watch = watch
        self.measure = model
        self.close = close
        _ar = StateObject(wrappedValue: PartARModel(api: model.api))
    }

    /// Back from «Koble til»: now connected, so fetch the parts.
    private func connected() {
        guard ar.api != nil else { return }
        ar.error = nil
        if ar.parts.isEmpty { ar.loadParts() }
    }

    var body: some View {
        ZStack {
            PartARView(model: ar).ignoresSafeArea()
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    CloseButton(action: close)
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
                    Label(e, systemImage: "exclamationmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(bad)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                bottom
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
        .foregroundStyle(.white)
        .onAppear {
            ar.loadParts()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .sheet(isPresented: $showCard) { ApprovalSheet(watch: watch) }
        // Its own sheet: the home screen's «Koble til» sheet sits under this screen.
        .background(EmptyView().sheet(isPresented: $connecting, onDismiss: connected) {
            SettingsSheet(model: measure, allowQR: false) { connecting = false }
        })
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
                .foregroundStyle(ar.clearanceIsBad ? bad : Color.white)
            if ar.api == nil {
                Button { connecting = true } label: { Label("Koble til", systemImage: "link") }.buttonStyle(PrimaryStyle())
            }
            if let n = ar.note { Text(n).font(.footnote).opacity(0.75) }
            if ar.placed {
                HStack(spacing: 8) {
                    Button { ar.turn(across: false) } label: { Label("Vri 90°", systemImage: "rotate.right") }.buttonStyle(SecondaryStyle())
                    Button { ar.turn(across: true) } label: { Label("Snu", systemImage: "arrow.triangle.2.circlepath") }.buttonStyle(SecondaryStyle())
                }
                Text("Dra for å flytte, vri med to fingre. Trykk et annet sted for å sette den der.").font(.footnote).opacity(0.75)
                HStack(spacing: 8) {
                    Button { ar.report() } label: {
                        Label(ar.sending ? "Sender …" : (ar.sent ?? "Send til CadSHAPE"), systemImage: ar.sent == nil ? "paperplane" : "checkmark.circle.fill")
                            .foregroundStyle(ar.sent == nil ? Color.white : good)
                    }
                    .buttonStyle(SecondaryStyle())
                    .disabled(ar.sending || ar.sent != nil)
                    if watch.card?.state == "venter" {
                        Button { showCard = true } label: { Label("Godkjenn print", systemImage: "play.fill") }.buttonStyle(PrimaryStyle())
                    }
                }
            }
        }
        .modifier(GlassPanel())
    }
}
