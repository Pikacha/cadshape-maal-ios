import XCTest
@testable import HoleKit

/// Same flat scenes as tests/edgeprofile.test.ts: a round hole (40) on a wall (200), optionally a ring.
private func flatScene(hole: Double, ring: Double?, ringValue: Double = 110, size: Int = 160) -> GrayImage {
    var px = [UInt8](repeating: 0, count: size * size)
    let c = Double(size) / 2
    for y in 0..<size {
        for x in 0..<size {
            var s = 0.0
            for j in 0..<4 {
                for i in 0..<4 {
                    let dx = Double(x) + (Double(i) + 0.5) / 4 - c, dy = Double(y) + (Double(j) + 0.5) / 4 - c
                    let r = (dx * dx + dy * dy).squareRoot()
                    s += r < hole ? 40 : (ring.map { r < $0 } ?? false) ? ringValue : 200
                }
            }
            px[y * size + x] = UInt8((s / 16).rounded())
        }
    }
    return GrayImage(width: size, height: size, pixels: px)
}

private func meanRadius(_ o: [P2]) -> Double {
    var c = P2(0, 0)
    for p in o { c += p }
    c /= Double(o.count)
    return o.reduce(0) { $0 + (($1.x - c.x) * ($1.x - c.x) + ($1.y - c.y) * ($1.y - c.y)).squareRoot() } / Double(o.count)
}

final class EdgeProfileTests: XCTestCase {
    func testOneEdgeOnACleanHole() {
        let g = flatScene(hole: 30, ring: nil).blurred()
        guard let h = findHole(g, seed: P2(80, 80)), let p = edgeProfile(g, outline: h.outline) else { return XCTFail("no hole") }
        XCTAssertNil(p.altOffset)
        XCTAssertEqual(meanRadius(h.outline), 30, accuracy: 0.5)
    }

    func testBothEdgesWhenADarkerRingSurroundsTheHole() {
        let g = flatScene(hole: 24, ring: 30).blurred()
        guard let h = findHole(g, seed: P2(80, 80)), let p = edgeProfile(g, outline: h.outline), let off = p.altOffset else {
            return XCTFail("the second edge was not found")
        }
        let radii = [meanRadius(h.outline), meanRadius(shiftOutline(h.outline, normals: p.normals, offset: off))].sorted()
        XCTAssertEqual(radii[0], 24, accuracy: 0.5)
        XCTAssertEqual(radii[1], 30, accuracy: 0.5)
        XCTAssertGreaterThan(p.altShare, 0.25)
    }

    func testFaintRingIsIgnored() {
        let g = flatScene(hole: 24, ring: 30, ringValue: 180).blurred()
        guard let h = findHole(g, seed: P2(80, 80)), let p = edgeProfile(g, outline: h.outline) else { return XCTFail("no hole") }
        XCTAssertNil(p.altOffset)
    }

    /// The failed lid: a 23 mm hole with a ~2.5 mm shadowed rim, seen from 30 cm. Both sizes must be offered
    /// and the measurement must not lock by itself.
    func testShadowRimRoundA23mmHoleGivesTwoSizesAndNoAutoLock() {
        var scene = Scene(tiltDegrees: 10, distance: 0.3, radius: 0.0115)
        scene.K = Intrinsics(fx: 1450, fy: 1450, cx: 320, cy: 240)
        let ring = 0.014
        let w = scene.fullW / 2, h = scene.fullH / 2
        var px = [UInt8](repeating: 0, count: w * h)
        var rnd = Noise()
        for j in 0..<h {
            for i in 0..<w {
                var sum = 0.0
                for a in 0..<4 {
                    for b in 0..<4 {
                        let u = (Double(i) + (Double(a) + 0.5) / 4) * 2, v = (Double(j) + (Double(b) + 0.5) / 4) * 2
                        let hit = scene.plane.hit(scene.K.ray(u, v))!
                        let r = vlength(hit - scene.centre)
                        sum += r < scene.radius ? 45 : r < ring ? 120 : 205
                    }
                }
                px[j * w + i] = UInt8(max(0, min(255, (sum / 16 + (rnd.next() - 0.5) * 4).rounded())))
            }
        }
        let input = FrameInput(gray: GrayImage(width: w, height: h, pixels: px), scale: 2, intrinsics: scene.K, depth: scene.depth(), fallbackPlane: nil, seed: scene.seed)
        guard case .success(let m) = measureFrame(input), let alt = m.edgeAlternative else { return XCTFail("two edges expected") }
        let sizes = [m.widthMM, alt.widthMM].sorted()
        XCTAssertEqual(sizes[0], 23, accuracy: 0.8)
        XCTAssertEqual(sizes[1], 28, accuracy: 0.8)
        let q = measurementQuality(Array(repeating: m, count: 8), trackingNormal: true)
        XCTAssertFalse(q.canAutoLock)
        XCTAssertGreaterThan(q.uncertaintyMM ?? 0, 2)
    }
}
