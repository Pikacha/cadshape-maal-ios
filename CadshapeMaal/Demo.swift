import ARKit
import HoleKit
import SwiftUI
import UIKit

/// Demo mode (`-demo pairing|live|locked|done|settings`): shows the app without a camera or a PC,
/// for screenshots in the simulator. A made-up ceiling with a Ø 68 mm hole, 55 cm away and a little
/// skewed, is measured with exactly the same code as the camera picture (HoleKit).
final class DemoScene {
    static let shared = DemoScene()

    let gray: GrayImage
    let depth: DepthMap
    let image: UIImage
    let intrinsics: Intrinsics
    /// Full-picture pixels per `gray` pixel.
    let scale = 2.0

    private init() {
        let gw = 600, gh = 1300
        let fullW = Double(gw) * scale, fullH = Double(gh) * scale
        let K = Intrinsics(fx: 1900, fy: 1900, cx: fullW / 2, cy: fullH / 2)
        intrinsics = K
        func dot3(_ a: V3, _ b: V3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
        var n = V3(0.17, -0.09, -1)
        n /= dot3(n, n).squareRoot()
        let plane = Plane(normal: n, offset: dot3(n, V3(0, 0, 0.55)))
        let centre = plane.hit(K.ray(fullW / 2 + 30, fullH / 2 - 40)) ?? V3(0, 0, 0.55)
        let radius = 0.034

        // The picture: a light, slightly uneven ceiling, a dark hole that is a little lighter towards its rim.
        func hash(_ x: Int, _ y: Int) -> Double {
            var h = UInt64(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663)
            h = (h ^ (h >> 13)) &* 0x5BD1_E995
            return Double(h & 0xFFFF) / 65_535 - 0.5
        }
        var px = [UInt8](repeating: 0, count: gw * gh)
        var rgba = [UInt8](repeating: 255, count: gw * gh * 4)
        for j in 0..<gh {
            for i in 0..<gw {
                var sum = 0.0
                for a in 0..<2 {
                    for b in 0..<2 {
                        let u = (Double(i) + (Double(a) + 0.5) / 2) * scale
                        let v = (Double(j) + (Double(b) + 0.5) / 2) * scale
                        guard let hit = plane.hit(K.ray(u, v)) else { continue }
                        let d = hit - centre
                        let r = dot3(d, d).squareRoot()
                        if r < radius {
                            sum += 34 + 34 * (r / radius) * (r / radius)
                        } else {
                            sum += 214 - 22 * v / fullH + 12 * u / fullW - 26 * exp(-(r - radius) / 0.004) * 0.35
                        }
                    }
                }
                let value = max(0, min(255, sum / 4 + 7 * hash(i, j)))
                px[j * gw + i] = UInt8(value.rounded())
                let k = (j * gw + i) * 4
                rgba[k] = UInt8(min(255, value * 1.02))
                rgba[k + 1] = UInt8(value * 0.99)
                rgba[k + 2] = UInt8(value * 0.93)
            }
        }
        gray = GrayImage(width: gw, height: gh, pixels: px)

        // LiDAR: the ceiling, and 15 cm deeper inside the hole.
        let dw = 192, dh = 416
        var depthValues = [Float](repeating: 0, count: dw * dh)
        for j in 0..<dh {
            for i in 0..<dw {
                let u = (Double(i) + 0.5) * fullW / Double(dw)
                let v = (Double(j) + 0.5) * fullH / Double(dh)
                guard let hit = plane.hit(K.ray(u, v)) else { continue }
                let d = hit - centre
                let inside = dot3(d, d).squareRoot() < radius
                depthValues[j * dw + i] = Float(hit.z + (inside ? 0.15 : 0) + 0.003 * hash(i + 7, j + 3))
            }
        }
        depth = DepthMap(width: dw, height: dh, depth: depthValues, confidence: nil)

        let data = Data(rgba) as CFData
        let provider = CGDataProvider(data: data)!
        let cg = CGImage(
            width: gw, height: gh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: gw * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
        image = UIImage(cgImage: cg)
    }

    func input(seed: P2) -> FrameInput {
        FrameInput(gray: gray, scale: scale, intrinsics: intrinsics, depth: depth, fallbackPlane: nil, seed: seed)
    }
}

/// The made-up camera picture, measured about seven times a second like the real one.
struct DemoCameraView: View {
    let model: MeasureModel
    @StateObject private var driver = DemoDriver()

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image = driver.image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    Color(white: 0.75)
                }
            }
            .onAppear { driver.start(model: model, size: geo.size) }
        }
    }
}

final class DemoDriver: ObservableObject {
    @Published var image: UIImage?
    private var timer: Timer?
    private var ticks = 0
    private var busy = false
    private let queue = DispatchQueue(label: "cadshape.maal.demo", qos: .userInitiated)

    func start(model: MeasureModel, size: CGSize) {
        guard timer == nil else { return }
        queue.async {
            let scene = DemoScene.shared
            DispatchQueue.main.async {
                self.image = scene.image
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                    self?.tick(model: model, size: size, scene: scene)
                }
            }
        }
    }

    private func tick(model: MeasureModel, size: CGSize, scene: DemoScene) {
        ticks += 1
        // Scripted steps for the screenshots.
        if ticks == 14 {
            switch model.demo {
            case "locked":
                model.lock()
            case "done":
                model.lock()
                model.commit()
            case "settings":
                model.showSettings = true
            default:
                break
            }
        }
        if busy || model.locked || model.wantsPairing { return }
        busy = true
        // Aspect fill: the picture covers the screen, centred.
        let gw = Double(scene.gray.width), gh = Double(scene.gray.height)
        let k = max(Double(size.width) / gw, Double(size.height) / gh)
        let ox = (Double(size.width) - gw * k) / 2, oy = (Double(size.height) - gh * k) / 2
        let seed = P2((Double(size.width) / 2 - ox) / k, (Double(size.height) / 2 - oy) / k)
        queue.async {
            let result = measureFrame(scene.input(seed: seed))
            DispatchQueue.main.async {
                self.busy = false
                model.measured(result, toScreen: { p in CGPoint(x: p.x * k + ox, y: p.y * k + oy) }, tracking: .normal)
            }
        }
    }
}
