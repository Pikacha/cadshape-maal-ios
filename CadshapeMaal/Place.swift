import ARKit
import HoleKit
import Metal
import RealityKit
import SwiftUI

/// A surface picked with the cross-hair: where, and which way it faces (world).
struct PickedSurface {
    var point: SIMD3<Float>
    var normal: SIMD3<Float>
}

/// «Skann stedet»: the room as a LiDAR mesh, one or two surfaces picked (angle, distance), and a
/// piece of the room sent to CadSHAPE as a locked surrounding to make the part against.
final class PlaceModel: ObservableObject {
    @Published var picks: [PickedSurface] = []
    @Published var want = ""
    @Published var sending = false
    @Published var sent: String?
    @Published var error: String?
    @Published var meshReady = false

    let api: CadshapeClient?
    weak var arView: ARView?
    private var markers: [AnchorEntity] = []

    init(api: CadshapeClient?) {
        self.api = api
        meshReady = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    /// The surface in the cross-hair.
    func pick() {
        guard let arView else { return }
        let c = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard let hit = arView.raycast(from: c, allowing: .estimatedPlane, alignment: .any).first else {
            error = "Fant ingen flate i krysset. Gå litt nærmere, eller sikt på en flatere del."
            return
        }
        error = nil
        let t = hit.worldTransform
        let p = PickedSurface(point: SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z), normal: simd_normalize(SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z)))
        // A third pick replaces the second.
        if picks.count >= 2 { undo() }
        picks.append(p)
        let a = AnchorEntity(world: t)
        let disk = ModelEntity(mesh: .generateBox(width: 0.05, height: 0.002, depth: 0.05, cornerRadius: 0.012), materials: [SimpleMaterial(color: picks.count == 1 ? UIColor(red: 0.35, green: 0.64, blue: 0.90, alpha: 0.7) : UIColor(red: 0.95, green: 0.66, blue: 0.23, alpha: 0.75), isMetallic: false)])
        a.addChild(disk)
        arView.scene.addAnchor(a)
        markers.append(a)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func undo() {
        guard !picks.isEmpty else { return }
        picks.removeLast()
        markers.popLast()?.removeFromParent()
    }

    var angle: Double? {
        guard picks.count == 2 else { return nil }
        let a = picks[0].normal, b = picks[1].normal
        return cornerAngle(V3(Double(a.x), Double(a.y), Double(a.z)), V3(Double(b.x), Double(b.y), Double(b.z)))
    }

    var distanceMM: Double? {
        guard picks.count == 2 else { return nil }
        return Double(simd_distance(picks[0].point, picks[1].point)) * 1000
    }

    /// What CadSHAPE gets as notes (and «Beskriv det» can use).
    var facts: [String] {
        var out: [String] = []
        if let a = angle { out.append("Vinkel mellom flatene: \(mm(a, digits: 1))°") }
        if let d = distanceMM { out.append("Avstand mellom punktene: \(mm(d, digits: 0)) mm") }
        if let p = picks.first {
            let up = abs(p.normal.y)
            out.append(up > 0.9 ? "Første flate er vannrett (bord, hylle, gulv)" : (up < 0.2 ? "Første flate er loddrett (vegg, side)" : "Første flate heller \(mm(Double(acos(min(1, up))) * 180 / .pi, digits: 0))°"))
        }
        return out
    }

    var suggestions: [String] {
        if let a = angle, a > 70, a < 110 { return ["Vinkelbrakett i hjørnet", "Hjørnehylle", "Kabelklips langs kanten"] }
        if let p = picks.first, abs(p.normal.y) < 0.2 { return ["Krok på veggen", "Holder for mobilen", "Klips for kabel"] }
        return ["Brett", "Stopper", "Fot under"]
    }

    /// The room round the first pick (25 cm), Z up in mm with the pick at 0, as a locked surrounding.
    func send() {
        guard let api else { error = "Koble til CadSHAPE først."; return }
        guard let frame = arView?.session.currentFrame else { return }
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !anchors.isEmpty else { error = "LiDAR-nettet er ikke klart ennå. Gå sakte rundt stedet et øyeblikk."; return }
        let centre: SIMD3<Float> = picks.isEmpty ? (frame.camera.transform * SIMD4<Float>(0, 0, -0.5, 1)).xyz : picks.map(\.point).reduce(.zero, +) / Float(picks.count)
        let c = V3(Double(centre.x), Double(centre.y), Double(centre.z))
        sending = true
        error = nil
        let facts = self.facts
        let want = self.want.trimmingCharacters(in: .whitespaces)
        // Copying the room mesh can take a moment on a big room: not on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let world = meshOf(anchors)
            let piece = crop(world, centre: c, radius: 0.25).mapped { worldToCad($0, origin: c) }
            let stl = binarySTL(piece, header: "CadSHAPE Maal - stedet").base64EncodedString()
            let s = piece.size
            DispatchQueue.main.async {
                guard piece.triangleCount > 0 else {
                    self.sending = false
                    self.error = "Ingen flater å sende rundt punktet."
                    return
                }
                var notes = facts
                if !want.isEmpty { notes.append("Skal lages her: \(want)") }
                notes.append("Origo er det første punktet du valgte. Nettet er grovt (± noen mm) – bruk det til plassering, ikke passform.")
                let body: [String: Any] = ["type": "mesh", "role": "omgivelse", "name": want.isEmpty ? "Stedet" : "Stedet for \(want)", "stl": stl, "size": [s.x, s.y, s.z].map { ($0 * 10).rounded() / 10 }, "notes": notes]
                api.postJSON("api/live/scan", body: body, timeout: 180) { [weak self] r in
                    guard let self else { return }
                    self.sending = false
                    switch r {
                    case .success(let j):
                        self.sent = (j["result"] as? [String: Any])?["label"] as? String ?? "Sendt til CadSHAPE"
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    case .failure(let e):
                        self.error = e.message
                    }
                }
            }
        }
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3<Float>(x, y, z) }
}

/// ARKit's room mesh (all anchors) as one mesh in world coordinates (m, Y up).
func meshOf(_ anchors: [ARMeshAnchor]) -> TriangleMesh {
    var vertices: [V3] = []
    var faces: [UInt32] = []
    for a in anchors {
        let g = a.geometry
        let t = a.transform
        let vs = g.vertices
        let base = UInt32(vertices.count)
        let vp = vs.buffer.contents()
        for i in 0..<vs.count {
            let p = vp.advanced(by: vs.offset + vs.stride * i).assumingMemoryBound(to: Float.self)
            let w = t * SIMD4<Float>(p[0], p[1], p[2], 1)
            vertices.append(V3(Double(w.x), Double(w.y), Double(w.z)))
        }
        let f = g.faces
        let fp = f.buffer.contents()
        let n = f.count * f.indexCountPerPrimitive
        for k in 0..<n {
            let idx: UInt32 = f.bytesPerIndex == 4 ? fp.load(fromByteOffset: k * 4, as: UInt32.self) : UInt32(fp.load(fromByteOffset: k * 2, as: UInt16.self))
            faces.append(base + idx)
        }
    }
    return TriangleMesh(vertices: vertices, faces: faces)
}

struct PlaceARView: UIViewRepresentable {
    let model: PlaceModel

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        // The LiDAR mesh drawn over the picture: one sees what the phone has understood.
        view.debugOptions.insert(.showSceneUnderstanding)
        view.session.run(config)
        model.arView = view
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: ()) {
        uiView.session.pause()
    }
}

struct PlaceScreen: View {
    @StateObject private var place: PlaceModel
    let close: () -> Void
    @FocusState private var typing: Bool

    init(model: MeasureModel, close: @escaping () -> Void) {
        self.close = close
        _place = StateObject(wrappedValue: PlaceModel(api: model.api))
    }

    var body: some View {
        ZStack {
            PlaceARView(model: place).ignoresSafeArea()
            Crosshair().allowsHitTesting(false)
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Button(action: close) {
                        Image(systemName: "chevron.left").font(.headline).frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Tilbake")
                    Text("Skann stedet").font(.subheadline.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 10).background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    ForEach(0..<place.picks.count, id: \.self) { i in
                        Text(i == 0 ? "Flate 1" : "Flate 2")
                            .font(.footnote.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(i == 0 ? blueTint : accent, in: Capsule())
                            .foregroundStyle(.black)
                    }
                }
                Spacer()
                sheet
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
        .foregroundStyle(.white)
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !place.meshReady {
                Text("Denne telefonen har ikke LiDAR-nett. Flater og mål virker, men stedet kan ikke sendes som 3D.").font(.footnote).opacity(0.8)
            }
            if place.picks.isEmpty {
                Text("Sikt krysset på flaten delen skal sitte mot").font(.headline)
                Text("Gå sakte rundt først, så LiDAR ser stedet (rutenettet).").font(.subheadline).opacity(0.8)
            } else {
                ForEach(place.facts, id: \.self) { Text($0).font(.subheadline.weight(.semibold)) }
            }
            HStack(spacing: 8) {
                Button { place.pick() } label: { Label(place.picks.count < 2 ? "Velg flaten i krysset" : "Velg på nytt", systemImage: "scope") }
                    .buttonStyle(PrimaryStyle())
                if !place.picks.isEmpty {
                    Button { place.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(SecondaryStyle())
                        .frame(maxWidth: 70)
                        .accessibilityLabel("Angre siste flate")
                }
            }
            TextField("Hva skal sitte her?", text: $place.want)
                .textFieldStyle(.roundedBorder)
                .foregroundStyle(.black)
                .focused($typing)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(place.suggestions, id: \.self) { s in
                        Button(s) { place.want = s; typing = false }
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 40)
                            .background(.ultraThinMaterial, in: Capsule())
                            .buttonStyle(.plain)
                    }
                }
            }
            if let e = place.error { Text(e).font(.subheadline).foregroundStyle(Color(red: 1, green: 0.56, blue: 0.53)) }
            if let s = place.sent {
                Label(s, systemImage: "checkmark.circle.fill").foregroundStyle(good).font(.subheadline.weight(.semibold))
            }
            Button { place.send() } label: { Label(place.sending ? "Sender …" : "Send stedet til CadSHAPE", systemImage: "paperplane.fill") }
                .buttonStyle(SecondaryStyle())
                .disabled(place.sending || !place.meshReady)
        }
        .modifier(GlassPanel())
    }
}

/// The cross-hair in the middle of the picture.
struct Crosshair: View {
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            var cross = Path()
            for (dx, dy) in [(-1.0, 0.0), (1.0, 0.0), (0.0, -1.0), (0.0, 1.0)] {
                cross.move(to: CGPoint(x: c.x + dx * 6, y: c.y + dy * 6))
                cross.addLine(to: CGPoint(x: c.x + dx * 22, y: c.y + dy * 22))
            }
            ctx.stroke(cross, with: .color(.black.opacity(0.5)), lineWidth: 4)
            ctx.stroke(cross, with: .color(.white), lineWidth: 2)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)), with: .color(accent))
        }
        .ignoresSafeArea()
    }
}
