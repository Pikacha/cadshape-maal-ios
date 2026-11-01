import XCTest
@testable import HoleKit

/// «Finn målene» on the phone: the same shapes as tests/scanshapes.test.ts in CadSHAPE.
final class ScanShapesTests: XCTestCase {
    /// A closed turned shape from (radius, z) points, bottom on the axis to top on the axis, Z up.
    private func lathe(_ profile: [(Double, Double)], segments: Int = 72, noise: Double = 0) -> TriangleMesh {
        var v: [V3] = []
        var f: [UInt32] = []
        let rings = profile.count
        for (r, z) in profile {
            for k in 0..<segments {
                let a = 2 * Double.pi * Double(k) / Double(segments)
                v.append(V3(r * cos(a), r * sin(a), z))
            }
        }
        for i in 0..<(rings - 1) {
            for k in 0..<segments {
                let a = UInt32(i * segments + k), b = UInt32(i * segments + (k + 1) % segments)
                let c = UInt32((i + 1) * segments + k), d = UInt32((i + 1) * segments + (k + 1) % segments)
                f += [a, b, d, a, d, c]
            }
        }
        if noise > 0 {
            // Object Capture-like: every corner nudged, the same nudge wherever it is used.
            v = v.map { p in
                let h = noise * sin(p.x * 12.9898 + p.y * 78.233 + p.z * 37.719) * cos(p.x * 4.1414 - p.z * 9.31)
                let k = noise * sin(p.y * 12.9898 + p.z * 78.233 + p.x * 37.719) * cos(p.y * 4.1414 - p.x * 9.31)
                return V3(p.x + h, p.y + k, p.z + h * 0.3)
            }
        }
        return TriangleMesh(vertices: v, faces: f)
    }

    /// Julian's pill bottle: body Ø37,4 × 59, cap Ø38,8 × 17, rounded bottom edge.
    private func bottle(noise: Double = 0.3) -> TriangleMesh {
        var p: [(Double, Double)] = [(0, 0)]
        for k in 0...6 {
            let a = -Double.pi / 2 + Double(k) / 6 * (Double.pi / 2)
            p.append((16.7 + 2 * cos(a), 2 + 2 * sin(a)))
        }
        p += [(18.7, 59), (19.4, 59), (19.4, 75.5), (18.6, 76.3), (0, 76.3)]
        return lathe(p, noise: noise)
    }

    func testPillBottleIsCapAndBody() throws {
        let s = try XCTUnwrap(fitScanShapes(bottle()))
        XCTAssertEqual(s.parts.map(\.kind), [.cylinder, .cylinder])
        XCTAssertEqual(s.parts[0].d, 37.4, accuracy: 0.6)
        XCTAssertEqual(s.parts[1].d, 38.8, accuracy: 0.6)
        XCTAssertEqual(s.parts[0].height, 59, accuracy: 2)
        XCTAssertEqual(s.parts[1].height, 17.3, accuracy: 1.5)
        XCTAssertTrue(s.lines[0].hasPrefix("Sylinder Ø38"), s.lines[0])
    }

    func testHeavierNoiseStillTwoParts() throws {
        let s = try XCTUnwrap(fitScanShapes(bottle(noise: 0.8)))
        XCTAssertEqual(s.parts.map(\.kind), [.cylinder, .cylinder])
    }

    func testFunnelIsCylinderAndCone() throws {
        let s = try XCTUnwrap(fitScanShapes(lathe([(0, 0), (10, 0), (10, 20), (30, 50), (0, 50)], noise: 0.25)))
        XCTAssertEqual(s.parts.map(\.kind), [.cylinder, .cone])
        XCTAssertEqual(s.parts[1].d, 20, accuracy: 2.5)
        XCTAssertEqual(s.parts[1].dTop, 60, accuracy: 2.5)
    }

    func testTurnedBoxHasSidesAngleAndCorners() throws {
        // A 60 × 30 × 25 box with R5 corners, turned 30°: four corner arcs as a lathe can't, so by hand.
        var outline: [P2] = []
        let w = 60.0, l = 30.0, r = 5.0
        let centres = [P2(w / 2 - r, -l / 2 + r), P2(w / 2 - r, l / 2 - r), P2(-w / 2 + r, l / 2 - r), P2(-w / 2 + r, -l / 2 + r)]
        for (q, c) in centres.enumerated() {
            for k in 0...8 {
                let a = -Double.pi / 2 + Double(q) * Double.pi / 2 + Double(k) / 8 * Double.pi / 2
                outline.append(c + P2(r * cos(a), r * sin(a)))
            }
        }
        let t = 30 * Double.pi / 180
        outline = outline.map { P2($0.x * cos(t) - $0.y * sin(t), $0.x * sin(t) + $0.y * cos(t)) }
        var v: [V3] = []
        var f: [UInt32] = []
        let n = outline.count
        for z in [0.0, 25.0] { for p in outline { v.append(V3(p.x, p.y, z)) } }
        for k in 0..<n {
            let a = UInt32(k), b = UInt32((k + 1) % n), c = UInt32(n + k), d = UInt32(n + (k + 1) % n)
            f += [a, b, d, a, d, c]
        }
        // Caps as fans from a centre point.
        v.append(V3(0, 0, 0)); v.append(V3(0, 0, 25))
        let bottom = UInt32(v.count - 2), top = UInt32(v.count - 1)
        for k in 0..<n {
            f += [bottom, UInt32((k + 1) % n), UInt32(k)]
            f += [top, UInt32(n + k), UInt32(n + (k + 1) % n)]
        }
        let s = try XCTUnwrap(fitScanShapes(TriangleMesh(vertices: v, faces: f)))
        XCTAssertEqual(s.parts.map(\.kind), [.box])
        XCTAssertEqual(s.parts[0].w, 60, accuracy: 0.6)
        XCTAssertEqual(s.parts[0].l, 30, accuracy: 0.6)
        XCTAssertEqual(s.parts[0].angle, 30, accuracy: 2)
        XCTAssertEqual(s.parts[0].corner, 5, accuracy: 1.2)
    }

    func testShortTextHasNorwegianComma() {
        XCTAssertEqual(shortMM(37.44), "37,4")
        XCTAssertEqual(shortMM(59.02), "59")
    }

    func testEmptyOrFlatGivesNothing() {
        XCTAssertNil(fitScanShapes(TriangleMesh(vertices: [], faces: [])))
    }
}
