import ARKit
import HoleKit
import SceneKit
import SwiftUI
import Vision

/// The camera, full screen. ARKit gives the picture, LiDAR depth and the camera's lens data for every frame.
struct ARMeasureView: UIViewRepresentable {
    let model: MeasureModel

    func makeCoordinator() -> Measurer { Measurer(model: model) }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.automaticallyUpdatesLighting = false
        view.rendersCameraGrain = false
        view.session.delegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.start()
        // A picture for the saved measurement, and the camera paused while a measurement is locked.
        model.snapshot = { [weak view] in view?.snapshot() }
        model.pauseCamera = { [weak view] in view?.session.pause() }
        model.resumeCamera = { [weak coordinator = context.coordinator] in coordinator?.resume() }
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Measurer) {
        uiView.session.pause()
    }
}

/// Measures the hole in the cross-hair, about eight times a second, off the main thread.
final class Measurer: NSObject, ARSessionDelegate {
    weak var view: ARSCNView?
    let model: MeasureModel
    private let queue = DispatchQueue(label: "cadshape.maal.measure", qos: .userInitiated)
    /// Main thread only.
    private var busy = false
    private var last: TimeInterval = 0
    private var lastOutlineProjection: TimeInterval = 0
    /// Box mode: the last frames' LiDAR points together (used on `queue` only).
    private let cloud = PointCloudFrames()
    /// World-space edge of the last valid hole; projected with every current camera frame.
    private var holeOutline = TrackedHoleOutline()

    init(model: MeasureModel) {
        self.model = model
        super.init()
    }

    private var config: ARWorldTrackingConfiguration?

    /// Goes on after a pause, in the same room.
    func resume() {
        guard let view, let config else { return }
        view.session.run(config)
    }

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            model.fatal = "Denne telefonen støtter ikke ARKit."
            return
        }
        let config = ARWorldTrackingConfiguration()
        self.config = config
        config.planeDetection = [.horizontal, .vertical]
        config.isAutoFocusEnabled = true
        // Both: the smoothed depth gives a calm, accurate wall round a hole and a clean point cloud
        // (the raw depth alone made the wall fit fail often, so the hole kept disappearing);
        // the raw depth is there as a fallback.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        model.hasLidar = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        // An old camera error (e.g. the camera still busy right after the 3D scan) is gone now.
        model.fatal = nil
        view?.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        // Back on a locked measurement: no need for the camera (battery) until «Mål på nytt».
        if model.locked || model.space.locked { view?.session.pause() }
    }

    private var retried = false

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            // Often the camera was just held by another screen: try once more before giving up.
            if !self.retried, let config = self.config {
                self.retried = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { session.run(config, options: [.resetTracking]) }
                return
            }
            self.model.fatal = "Kameraet stoppet: \(error.localizedDescription). Gå tilbake til start og åpne på nytt."
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if !model.locked && !model.mode.isSpace && !model.wantsPairing && frame.timestamp - lastOutlineProjection >= 0.05 {
            lastOutlineProjection = frame.timestamp
            refreshOutline(frame)
        }
        let mode = model.mode
        let spaceMode = mode.isSpace && !model.space.locked && !model.wantsPairing
        if busy || frame.timestamp - last < (spaceMode ? 0.2 : 0.12) { return }
        guard let view = view, view.bounds.width > 0 else { return }
        busy = true
        last = frame.timestamp
        let viewSize = view.bounds.size
        let toView = frame.displayTransform(for: .portrait, viewportSize: viewSize)
        // The cross-hair is the middle of the screen; in the picture's own coordinates (0…1):
        let seed = CGPoint(x: 0.5, y: 0.5).applying(toView.inverted())
        let pairing = model.wantsPairing
        let measuring = !model.locked && !pairing && !mode.isSpace
        let capturedTracking = frame.camera.trackingState
        let imageWidth = Double(frame.camera.imageResolution.width)
        var fallback: Plane? = nil
        // ARKit's own plane under the cross-hair: used when the LiDAR points round the hole do not
        // give a wall (cluttered edge, glossy surface) instead of losing the hole.
        if measuring {
            fallback = FrameReader.raycastPlane(session, frame, at: seed)
        }

        if spaceMode {
            busy = true
            last = frame.timestamp
            let generation = model.space.generation
            queue.async { [weak self] in
                guard let self else { return }
                let result = self.measureSpace(frame, seed: seed, generation: generation)
                DispatchQueue.main.async {
                    self.busy = false
                    // Changed mode or started again while this was measured.
                    guard self.model.space.generation == generation, !self.model.space.locked else { return }
                    guard let result else { return self.model.space.noLidar() }
                    let screen: [CGPoint] = result.world.compactMap { p in
                        let q = view.projectPoint(SCNVector3(Float(p.x), Float(p.y), Float(p.z)))
                        return q.z > 0 && q.z < 1 ? CGPoint(x: CGFloat(q.x), y: CGFloat(q.y)) : nil
                    }
                    let shown = screen.count == result.world.count ? screen : []
                    let space = self.model.space
                    space.update(box: result.box, screen: shown)
                    if space.advice != result.advice { space.advice = result.advice }
                }
            }
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            var found: Pairing? = nil
            var web: URL? = nil
            if pairing {
                for text in FrameReader.qrTexts(frame.capturedImage) {
                    if let p = Pairing.parse(text) { found = p; break }
                    // The QR code of CadSHAPE on the web (kloki.no/cadshape): log in there instead.
                    if web == nil, let u = Pairing.webAddress(text), u.host.map({ !($0.first?.isNumber ?? true) }) == true { web = u }
                }
            }
            var result: Result<FrameMeasurement, MeasureFailure>? = nil
            var gw = 1.0, gh = 1.0
            if measuring, let gray = FrameReader.gray(frame.capturedImage) {
                gw = Double(gray.width)
                gh = Double(gray.height)
                let smoothed = frame.smoothedSceneDepth.flatMap { FrameReader.depth($0) }
                let raw = frame.sceneDepth.flatMap { FrameReader.depth($0) }
                let K = FrameReader.intrinsics(frame.camera)
                let seedPoint = P2(Double(seed.x) * gw, Double(seed.y) * gh)
                func run(_ depth: DepthMap?, smoothedDepth: Bool) -> Result<FrameMeasurement, MeasureFailure> {
                    measureFrame(FrameInput(gray: gray, scale: imageWidth / gw, intrinsics: K, depth: depth,
                        fallbackPlane: fallback, seed: seedPoint, usedSmoothedDepth: smoothedDepth))
                }
                // Smoothed depth first (calm wall); the raw depth if that found nothing.
                var r = run(smoothed ?? raw, smoothedDepth: smoothed != nil)
                if case .failure = r, smoothed != nil, raw != nil { r = run(raw, smoothedDepth: false) }
                result = r
            }
            let w = gw, h = gh
            DispatchQueue.main.async {
                self.busy = false
                if let found { self.model.paired(found) } else if let web { self.model.sawWebAddress(web) }
                guard let result else { return }
                // A result from the previous screen/mode must not overwrite the current one.
                guard self.model.mode == mode, self.model.wantsPairing == pairing else { return }
                let measurement = try? result.get()
                self.holeOutline.update(measurement, intrinsics: FrameReader.intrinsics(frame.camera),
                    scale: imageWidth / w, pose: FrameReader.pose(frame.camera), timestamp: frame.timestamp)
                let current = view.session.currentFrame ?? frame
                let toScreen: (P2) -> CGPoint = { p in
                    let n = CGPoint(x: p.x / w, y: p.y / h).applying(toView)
                    return CGPoint(x: n.x * viewSize.width, y: n.y * viewSize.height)
                }
                // Recovery during analysis must not promote a frame captured with poor tracking.
                let qualityTracking: ARCamera.TrackingState
                if case .normal = capturedTracking {
                    qualityTracking = current.camera.trackingState
                } else {
                    qualityTracking = capturedTracking
                }
                self.model.measured(result, toScreen: toScreen, tracking: qualityTracking,
                    screenOutline: self.projectedOutline(current))
            }
        }
    }

    private func refreshOutline(_ frame: ARFrame) {
        var points: [CGPoint] = []
        if case .normal = frame.camera.trackingState { points = projectedOutline(frame) }
        // 20 times a second: only publish when it changed (an unchanged write still redraws everything).
        if points != model.outlineOnScreen { model.outlineOnScreen = points }
    }

    private func projectedOutline(_ frame: ARFrame) -> [CGPoint] {
        guard let view else { return [] }
        guard case .normal = frame.camera.trackingState else { return [] }
        let size = view.bounds.size
        let transform = frame.displayTransform(for: .portrait, viewportSize: size)
        return holeOutline.projected(intrinsics: FrameReader.intrinsics(frame.camera),
            pose: FrameReader.pose(frame.camera), timestamp: frame.timestamp).map { p in
                let n = CGPoint(x: p.x / Double(frame.camera.imageResolution.width),
                    y: p.y / Double(frame.camera.imageResolution.height)).applying(transform)
                return CGPoint(x: n.x * size.width, y: n.y * size.height)
            }
    }
}

extension Measurer {
    /// The point cloud of the last frames and the box in it. Nil without LiDAR.
    fileprivate struct SpaceResult {
        var box: BoxFit?
        /// What to draw over the picture (world points, closed).
        var world: [V3] = []
        /// Said under the live sizes: why the measurement may be poor (dark surface).
        var advice: String?
    }

    /// The point cloud of the last frames and the box in it. Nil without LiDAR.
    fileprivate func measureSpace(_ frame: ARFrame, seed: CGPoint, generation: Int) -> SpaceResult? {
        // Points from a camera that has lost its place (or moves fast) land in the wrong spot in
        // the world and double the walls: skip such frames (counts as one miss).
        guard case .normal = frame.camera.trackingState else { return nil }
        guard let data = frame.smoothedSceneDepth ?? frame.sceneDepth, let dm = FrameReader.depth(data) else { return nil }
        let K = FrameReader.intrinsics(frame.camera)
        let pose = FrameReader.pose(frame.camera)
        let iw = Double(frame.camera.imageResolution.width)
        let ih = Double(frame.camera.imageResolution.height)
        if cloud.generation != generation { cloud.reset(generation) }
        // A big jump since the last frame (moved > 10 cm or turned > 15°): start the cloud again.
        cloud.follow(pose)
        // Dark, black or glossy surfaces: the sensor is rarely sure of them. Then take the points it is
        // half sure of too (noisier, but something) and say why the numbers may be off.
        let sure = confidentShare(dm, aroundPixel: Double(seed.x) * iw, v: Double(seed.y) * ih, imageWidth: iw, imageHeight: ih)
        let dark = sure < 0.3
        cloud.add(cloudPoints(dm, intrinsics: K, imageWidth: iw, imageHeight: ih, pose: pose, minConfidence: dark ? 1 : 2))
        let darkAdvice = dark ? "Mørk eller blank flate – LiDAR ser lite. Legg et lyst ark under, eller skriv inn målene." : nil
        // Held upright, the screen's right is the camera's y axis (its picture lies on its side).
        let right = pose.y
        guard let aim = pointAt(dm, intrinsics: K, imageWidth: iw, imageHeight: ih, pose: pose, u: Double(seed.x) * iw, v: Double(seed.y) * ih) else {
            return SpaceResult(advice: darkAdvice)
        }
        let fit = fitBox(cloud.points, aim: aim, right: right)
        return SpaceResult(box: fit, world: fit?.corners ?? [], advice: darkAdvice)
    }
}

/// The LiDAR points of the last few frames (ARKit's world stays put while the phone moves, so
/// together they fill each other's gaps).
final class PointCloudFrames {
    private(set) var generation = -1
    private var frames: [[V3]] = []
    private let keep = 5

    private var lastPose: CameraPose?

    func reset(_ g: Int) {
        generation = g
        frames = []
        lastPose = nil
    }

    /// Drops the old frames when the phone has moved a lot since the last one.
    func follow(_ pose: CameraPose) {
        defer { lastPose = pose }
        guard let last = lastPose else { return }
        let moved = simd_length(pose.position - last.position)
        let turned = acos(max(-1, min(1, simd_dot(pose.z, last.z)))) * 180 / .pi
        if moved > 0.10 || turned > 15 { frames = [] }
    }

    func add(_ pts: [V3]) {
        frames.append(pts)
        if frames.count > keep { frames.removeFirst(frames.count - keep) }
    }

    var points: [V3] { frames.flatMap { $0 } }
}

/// Reading ARKit's frame data into HoleKit's plain arrays.
enum FrameReader {
    /// The camera's place and axes in the world.
    static func pose(_ camera: ARCamera) -> CameraPose {
        let t = camera.transform
        func v(_ c: SIMD4<Float>) -> V3 { V3(Double(c.x), Double(c.y), Double(c.z)) }
        return CameraPose(x: v(t.columns.0), y: v(t.columns.1), z: v(t.columns.2), position: v(t.columns.3))
    }

    /// The picture's brightness (the Y plane of the camera's YCbCr picture), at half size.
    static func gray(_ buffer: CVPixelBuffer) -> GrayImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) >= 2, let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let luma = UnsafePointer<UInt8>(base.assumingMemoryBound(to: UInt8.self))
        return GrayImage.halfSize(luma: luma, width: w, height: h, bytesPerRow: bpr)
    }

    /// LiDAR depth (m) and how sure ARKit is of each value.
    static func depth(_ data: ARDepthData) -> DepthMap? {
        let map = data.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32,
              let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map)
        let h = CVPixelBufferGetHeight(map)
        let bpr = CVPixelBufferGetBytesPerRow(map)
        var d = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = (base + y * bpr).assumingMemoryBound(to: Float32.self)
            for x in 0..<w { d[y * w + x] = row[x] }
        }
        var conf: [UInt8]? = nil
        if let cm = data.confidenceMap {
            CVPixelBufferLockBaseAddress(cm, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(cm, .readOnly) }
            if CVPixelBufferGetWidth(cm) == w, CVPixelBufferGetHeight(cm) == h, let cb = CVPixelBufferGetBaseAddress(cm) {
                let cbpr = CVPixelBufferGetBytesPerRow(cm)
                var c = [UInt8](repeating: 0, count: w * h)
                for y in 0..<h {
                    let row = (cb + y * cbpr).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<w { c[y * w + x] = row[x] }
                }
                conf = c
            }
        }
        return DepthMap(width: w, height: h, depth: d, confidence: conf)
    }

    /// The lens: focal length and centre in pixels of the full camera picture.
    static func intrinsics(_ camera: ARCamera) -> Intrinsics {
        let k = camera.intrinsics
        return Intrinsics(fx: Double(k[0][0]), fy: Double(k[1][1]), cx: Double(k[2][0]), cy: Double(k[2][1]))
    }

    /// Without LiDAR: the surface ARKit estimates where the cross-hair points, in camera coordinates
    /// (x right, y down, z forward – ARKit's camera has y up and looks along −z).
    static func raycastPlane(_ session: ARSession, _ frame: ARFrame, at point: CGPoint) -> Plane? {
        let query = frame.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .any)
        guard let hit = session.raycast(query).first else { return nil }
        let toCamera = frame.camera.transform.inverse
        let p = toCamera * hit.worldTransform.columns.3
        let up = hit.worldTransform.columns.1
        let n = toCamera * SIMD4<Float>(up.x, up.y, up.z, 0)
        let pc = V3(Double(p.x), Double(-p.y), Double(-p.z))
        let nc = V3(Double(n.x), Double(-n.y), Double(-n.z))
        return Plane(normal: nc, offset: nc.x * pc.x + nc.y * pc.y + nc.z * pc.z)
    }

    /// QR codes in the picture (to connect to the PC).
    static func qrTexts(_ buffer: CVPixelBuffer) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        return (request.results ?? []).compactMap { $0.payloadStringValue }
    }
}
