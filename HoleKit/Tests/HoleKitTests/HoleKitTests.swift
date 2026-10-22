import XCTest
@testable import HoleKit

/// A small, repeatable random number source for noise.
struct Noise {
    var state: UInt64 = 12345
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

/// A scene: a flat wall with a round hole, seen by a pinhole camera.
struct Scene {
    var K = Intrinsics(fx: 520, fy: 520, cx: 320, cy: 240)
    let fullW = 640
    let fullH = 480
    var plane: Plane
    var centre: V3
    var radius: Double
    /// How much deeper the hole's inside is (m).
    var holeDepth = 0.1

    init(tiltDegrees: Double, distance: Double, radius: Double) {
        let a = tiltDegrees * .pi / 180
        let n = vnormalized(V3(sin(a), 0.12, cos(a)))
        let c = V3(0.02, -0.01, distance)
        centre = c
        plane = Plane(normal: n, offset: vdot(n, c))
        self.radius = radius
    }

    func inHole(_ u: Double, _ v: Double) -> (Bool, Double) {
        let hit = plane.hit(K.ray(u, v))!
        return (vlength(hit - centre) < radius, hit.z)
    }

    /// The camera picture at half size (anti-aliased), dark hole on a light wall.
    func picture(hole: UInt8 = 45, wall: UInt8 = 205, noise: Double = 3) -> GrayImage {
        let w = fullW / 2, h = fullH / 2
        var px = [UInt8](repeating: 0, count: w * h)
        var rnd = Noise()
        for j in 0..<h {
            for i in 0..<w {
                var sum = 0.0
                for a in 0..<4 {
                    for b in 0..<4 {
                        let u = (Double(i) + (Double(a) + 0.5) / 4) * 2
                        let v = (Double(j) + (Double(b) + 0.5) / 4) * 2
                        sum += inHole(u, v).0 ? Double(hole) : Double(wall)
                    }
                }
                let value = sum / 16 + (rnd.next() - 0.5) * 2 * noise
                px[j * w + i] = UInt8(max(0, min(255, value.rounded())))
            }
        }
        return GrayImage(width: w, height: h, pixels: px)
    }

    /// LiDAR-like depth map (soft at the edges, a little noise).
    func depth(width: Int = 160, height: Int = 120, noise: Double = 0.002) -> DepthMap {
        let sx = Double(fullW) / Double(width), sy = Double(fullH) / Double(height)
        var d = [Float](repeating: 0, count: width * height)
        var rnd = Noise(state: 777)
        for j in 0..<height {
            for i in 0..<width {
                var sum = 0.0
                for a in 0..<3 {
                    for b in 0..<3 {
                        let u = (Double(i) + (Double(a) + 0.5) / 3) * sx
                        let v = (Double(j) + (Double(b) + 0.5) / 3) * sy
                        let (inside, z) = inHole(u, v)
                        sum += inside ? z + holeDepth : z
                    }
                }
                d[j * width + i] = Float(sum / 9 + (rnd.next() - 0.5) * 2 * noise)
            }
        }
        return DepthMap(width: width, height: height, depth: d, confidence: nil)
    }

    /// Where the hole's centre is in the half-size picture.
    var seed: P2 {
        P2((K.fx * centre.x / centre.z + K.cx) / 2, (K.fy * centre.y / centre.z + K.cy) / 2)
    }
}

final class HoleKitTests: XCTestCase {
    func testFindsRoundHoleInPicture() {
        let scene = Scene(tiltDegrees: 0, distance: 0.8, radius: 0.04)
        let g = scene.picture().blurred()
        guard let hole = findHole(g, seed: scene.seed) else { return XCTFail("no hole") }
        // Radius in half-size pixels: f · r / z / 2.
        let r = 520 * 0.04 / 0.8 / 2
        let area = abs(polygonArea(hole.outline))
        XCTAssertEqual(area, Double.pi * r * r, accuracy: Double.pi * r * r * 0.03)
        XCTAssertGreaterThan(hole.contrast, 100)
    }

    func testNoHoleOnPlainWall() {
        let scene = Scene(tiltDegrees: 0, distance: 0.8, radius: 0.0)
        XCTAssertNil(findHole(scene.picture().blurred(), seed: scene.seed))
    }

    func testPlaneThroughNoisyPointsWithOutliers() {
        let n = vnormalized(V3(0.3, -0.2, 1))
        let plane = Plane(normal: n, offset: 1.2)
        var rnd = Noise()
        var pts: [V3] = []
        for _ in 0..<400 {
            let ray = V3(rnd.next() - 0.5, rnd.next() - 0.5, 1)
            var p = plane.hit(ray)!
            p += n * (rnd.next() - 0.5) * 0.004
            pts.append(p)
        }
        for _ in 0..<120 { pts.append(V3(rnd.next() - 0.5, rnd.next() - 0.5, 1.5 + rnd.next())) }
        guard let fit = fitPlane(pts) else { return XCTFail("no plane") }
        XCTAssertGreaterThan(fit.inliers, 380)
        XCTAssertLessThan(fit.inliers, 430)
        XCTAssertGreaterThan(vdot(fit.plane.normal, plane.normal), 0.9995)
        XCTAssertEqual(fit.plane.offset, 1.2, accuracy: 0.002)
    }

    func testPlaneFrameDirections() {
        let frame = PlaneFrame(Plane(normal: V3(0, 0, -1), offset: 1))
        // Camera coordinates: x right, y down. Plane mm: x right, y up.
        let right = frame.mm(V3(0.1, 0, 1))
        let up = frame.mm(V3(0, -0.1, 1))
        XCTAssertEqual(right.x, 100, accuracy: 1e-6)
        XCTAssertEqual(right.y, 0, accuracy: 1e-6)
        XCTAssertEqual(up.x, 0, accuracy: 1e-6)
        XCTAssertEqual(up.y, 100, accuracy: 1e-6)
    }

    func testMeasuresHoleStraightOn() {
        let scene = Scene(tiltDegrees: 0, distance: 0.7, radius: 0.04)
        check(scene, source: .picture, tolerance: 0.015)
    }

    func testMeasuresHoleOnTiltedWall() {
        let scene = Scene(tiltDegrees: 35, distance: 0.9, radius: 0.035)
        check(scene, source: .picture, tolerance: 0.02)
    }

    func testMeasuresFromRaycastSurfaceWithoutLidar() {
        let scene = Scene(tiltDegrees: 20, distance: 0.8, radius: 0.03)
        let input = FrameInput(gray: scene.picture(), scale: 2, intrinsics: scene.K, depth: nil, fallbackPlane: scene.plane, seed: scene.seed)
        guard case .success(let m) = measureFrame(input) else { return XCTFail("no measurement") }
        XCTAssertEqual(m.planePoints, 0)
        XCTAssertEqual(m.sizeMM, Double.pi.squareRoot() * 30, accuracy: Double.pi.squareRoot() * 30 * 0.02)
    }

    func testFindsHoleFromDepthWhenPictureShowsNothing() {
        let scene = Scene(tiltDegrees: 10, distance: 0.8, radius: 0.06)
        check(scene, picture: scene.picture(hole: 205, wall: 205), source: .depth, tolerance: 0.05)
    }

    func testNoSurfaceWithoutDepthOrRaycast() {
        let scene = Scene(tiltDegrees: 0, distance: 0.8, radius: 0.04)
        let input = FrameInput(gray: scene.picture(), scale: 2, intrinsics: scene.K, depth: nil, fallbackPlane: nil, seed: scene.seed)
        guard case .failure(let f) = measureFrame(input) else { return XCTFail("should fail") }
        XCTAssertEqual(f, .noSurface)
    }

    func testCircleFitAndQuickText() {
        let pts = (0..<60).map { i -> P2 in
            let a = Double(i) / 60 * 2 * Double.pi
            return P2(12 + 34 * cos(a), -5 + 34 * sin(a))
        }
        guard let c = fitCircle(pts) else { return XCTFail("no circle") }
        XCTAssertEqual(c.radius, 34, accuracy: 1e-6)
        XCTAssertEqual(c.centre.x, 12, accuracy: 1e-6)
        XCTAssertEqual(c.centre.y, -5, accuracy: 1e-6)
        XCTAssertEqual(mmText(68.04), "68,0")

        let scene = Scene(tiltDegrees: 0, distance: 0.7, radius: 0.04)
        let input = FrameInput(gray: scene.picture(), scale: 2, intrinsics: scene.K, depth: scene.depth(), fallbackPlane: nil, seed: scene.seed)
        guard case .success(let m) = measureFrame(input) else { return XCTFail("no measurement") }
        XCTAssertTrue(quickText(m).hasPrefix("Ø "), quickText(m))
    }

    private func check(_ scene: Scene, picture: GrayImage? = nil, source: HoleSource, tolerance: Double, file: StaticString = #filePath, line: UInt = #line) {
        let input = FrameInput(gray: picture ?? scene.picture(), scale: 2, intrinsics: scene.K, depth: scene.depth(), fallbackPlane: nil, seed: scene.seed)
        let r = measureFrame(input)
        guard case .success(let m) = r else { return XCTFail("no measurement: \(r)", file: file, line: line) }
        let d = scene.radius * 2000
        XCTAssertEqual(m.source, source, file: file, line: line)
        XCTAssertEqual(m.sizeMM, Double.pi.squareRoot() * d / 2, accuracy: Double.pi.squareRoot() * d / 2 * tolerance, "√area", file: file, line: line)
        XCTAssertEqual(m.widthMM, d, accuracy: d * tolerance * 1.5, "width", file: file, line: line)
        XCTAssertEqual(m.heightMM, d, accuracy: d * tolerance * 1.5, "height", file: file, line: line)
        XCTAssertEqual(m.plane.distance, abs(vdot(scene.plane.normal, scene.centre)), accuracy: 0.01, file: file, line: line)
        XCTAssertGreaterThan(m.planePoints, 50, file: file, line: line)
    }
}
