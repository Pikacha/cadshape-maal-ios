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
    private var lastProjected: TimeInterval = 0
    /// Box and object modes: the last frames' LiDAR points together (used on `queue` only).
    private let cloud = PointCloudFrames()

    init(model: MeasureModel) {
        self.model = model
        super.init()
    }

    private var config: ARWorldTrackingConfiguration?

    /// Goes on after a pause, in the same room (the hole pattern keeps its places).
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
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        model.hasLidar = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        view?.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.model.fatal = "Kameraet stoppet: \(error.localizedDescription)" }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // The pattern's holes follow the camera on screen.
        if let view, !model.pattern.isEmpty, frame.timestamp - lastProjected > 0.05 {
            lastProjected = frame.timestamp
            model.patternOnScreen = model.pattern.map { e in
                let p = view.projectPoint(SCNVector3(e.world.x, e.world.y, e.world.z))
                return p.z > 0 && p.z < 1 ? CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)) : nil
            }
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
        let tracking = frame.camera.trackingState
        let cameraToWorld = frame.camera.transform
        let imageWidth = Double(frame.camera.imageResolution.width)
        var fallback: Plane? = nil
        if measuring && frame.smoothedSceneDepth == nil && frame.sceneDepth == nil {
            fallback = FrameReader.raycastPlane(session, frame, at: seed)
        }

        if spaceMode {
            busy = true
            last = frame.timestamp
            let generation = model.space.generation
            let isBox = mode == .box
            queue.async { [weak self] in
                guard let self else { return }
                let result = self.measureSpace(frame, seed: seed, generation: generation, isBox: isBox)
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
                    if isBox { self.model.space.update(box: result.box, screen: shown) } else { self.model.space.update(object: result.object, screen: shown) }
                }
            }
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            var found: Pairing? = nil
            if pairing {
                for text in FrameReader.qrTexts(frame.capturedImage) {
                    if let p = Pairing.parse(text) { found = p; break }
                }
            }
            var result: Result<FrameMeasurement, MeasureFailure>? = nil
            var gw = 1.0, gh = 1.0
            if measuring, let gray = FrameReader.gray(frame.capturedImage) {
                gw = Double(gray.width)
                gh = Double(gray.height)
                let depth = (frame.smoothedSceneDepth ?? frame.sceneDepth).flatMap { FrameReader.depth($0) }
                let input = FrameInput(
                    gray: gray, scale: imageWidth / gw, intrinsics: FrameReader.intrinsics(frame.camera),
                    depth: depth, fallbackPlane: fallback, seed: P2(Double(seed.x) * gw, Double(seed.y) * gh)
                )
                result = measureFrame(input)
            }
            let w = gw, h = gh
            DispatchQueue.main.async {
                self.busy = false
                if let found { self.model.paired(found) }
                guard let result else { return }
                let toScreen: (P2) -> CGPoint = { p in
                    let n = CGPoint(x: p.x / w, y: p.y / h).applying(toView)
                    return CGPoint(x: n.x * viewSize.width, y: n.y * viewSize.height)
                }
                self.model.measured(result, toScreen: toScreen, tracking: tracking, cameraToWorld: cameraToWorld)
            }
        }
    }
}

extension Measurer {
    /// The point cloud of the last frames and the box or object in it. Nil without LiDAR.
    fileprivate func measureSpace(_ frame: ARFrame, seed: CGPoint, generation: Int, isBox: Bool) -> (box: BoxFit?, object: ObjectFit?, world: [V3])? {
        guard let data = frame.smoothedSceneDepth ?? frame.sceneDepth, let dm = FrameReader.depth(data) else { return nil }
        let K = FrameReader.intrinsics(frame.camera)
        let pose = FrameReader.pose(frame.camera)
        let iw = Double(frame.camera.imageResolution.width)
        let ih = Double(frame.camera.imageResolution.height)
        if cloud.generation != generation { cloud.reset(generation) }
        cloud.add(cloudPoints(dm, intrinsics: K, imageWidth: iw, imageHeight: ih, pose: pose))
        // Held upright, the screen's right is the camera's y axis (its picture lies on its side).
        let right = pose.y
        guard let aim = pointAt(dm, intrinsics: K, imageWidth: iw, imageHeight: ih, pose: pose, u: Double(seed.x) * iw, v: Double(seed.y) * ih) else {
            return (nil, nil, [])
        }
        if isBox {
            let fit = fitBox(cloud.points, aim: aim, right: right)
            return (fit, nil, fit?.corners ?? [])
        }
        let fit = fitObject(cloud.points, aim: aim, right: right)
        return (nil, fit, fit?.outlineWorld ?? [])
    }
}

/// The LiDAR points of the last few frames (ARKit's world stays put while the phone moves, so
/// together they fill each other's gaps).
final class PointCloudFrames {
    private(set) var generation = -1
    private var frames: [[V3]] = []
    private let keep = 5

    func reset(_ g: Int) {
        generation = g
        frames = []
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
