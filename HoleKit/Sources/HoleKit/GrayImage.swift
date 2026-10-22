import Foundation

/// A point in picture or plane coordinates.
public typealias P2 = SIMD2<Double>

/// A grey picture, row by row. Pixel (i, j) covers [i, i+1] × [j, j+1]; its centre is (i + 0.5, j + 0.5).
public struct GrayImage {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "pixel count")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Half size: the mean of each 2 × 2 block (from a full-size luma plane with `bytesPerRow` padding).
    public static func halfSize(luma: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) -> GrayImage {
        let w = width / 2
        let h = height / 2
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let r0 = luma + (2 * y) * bytesPerRow
            let r1 = r0 + bytesPerRow
            for x in 0..<w {
                let s = Int(r0[2 * x]) + Int(r0[2 * x + 1]) + Int(r1[2 * x]) + Int(r1[2 * x + 1])
                out[y * w + x] = UInt8((s + 2) >> 2)
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }

    /// Gentle blur (binomial 1-4-6-4-1 in both directions) against sensor noise.
    public func blurred() -> GrayImage {
        let w = width
        let h = height
        var tmp = [UInt16](repeating: 0, count: w * h)
        pixels.withUnsafeBufferPointer { d in
            for y in 0..<h {
                let r = y * w
                for x in 0..<w {
                    let a = UInt16(d[r + max(0, x - 2)])
                    let b = UInt16(d[r + max(0, x - 1)])
                    let c = UInt16(d[r + x])
                    let e = UInt16(d[r + min(w - 1, x + 1)])
                    let f = UInt16(d[r + min(w - 1, x + 2)])
                    tmp[r + x] = a + 4 * b + 6 * c + 4 * e + f
                }
            }
        }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let ya = max(0, y - 2) * w
            let yb = max(0, y - 1) * w
            let yc = y * w
            let yd = min(h - 1, y + 1) * w
            let ye = min(h - 1, y + 2) * w
            for x in 0..<w {
                let s = UInt32(tmp[ya + x]) + 4 * UInt32(tmp[yb + x]) + 6 * UInt32(tmp[yc + x]) + 4 * UInt32(tmp[yd + x]) + UInt32(tmp[ye + x])
                out[yc + x] = UInt8(min(255, (s + 128) >> 8))
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }
}

/// Otsu's threshold for a 256-bin histogram, and the mean of each side.
func otsu(_ hist: [Int]) -> (t: Double, low: Double, high: Double) {
    var total = 0
    var sum = 0.0
    for i in 0..<256 {
        total += hist[i]
        sum += Double(i * hist[i])
    }
    var wB = 0
    var sumB = 0.0
    var best = -1.0
    var t = 128.0
    var low = 0.0
    var high = 255.0
    for i in 0..<256 {
        wB += hist[i]
        if wB == 0 { continue }
        let wF = total - wB
        if wF == 0 { break }
        sumB += Double(i * hist[i])
        let mB = sumB / Double(wB)
        let mF = (sum - sumB) / Double(wF)
        let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
        if between > best {
            best = between
            t = Double(i) + 0.5
            low = mB
            high = mF
        }
    }
    return (t, low, high)
}

/// The outer outline of a 4-connected region that contains pixel `start` (its first pixel
/// in reading order), clockwise on screen, one point per pixel edge, placed between the
/// inside and the outside pixel at the fraction `level` gives (sub-pixel), else halfway.
func traceOutline(width w: Int, height h: Int, start: Int, isIn: (Int, Int) -> Bool, level: ((Int, Int, Int, Int) -> Double)?) -> [P2] {
    let sx = start % w
    let sy = start / w
    // A crack starts at corner (x, y) and runs right (0), down (1), left (2) or up (3).
    // Its inside pixel is on the right-hand side, the outside pixel on the left.
    func inX(_ x: Int, _ d: Int) -> Int { d == 1 || d == 2 ? x - 1 : x }
    func inY(_ y: Int, _ d: Int) -> Int { d >= 2 ? y - 1 : y }
    func outX(_ x: Int, _ d: Int) -> Int { d == 1 ? x : (d == 3 ? x - 1 : inX(x, d)) }
    func outY(_ y: Int, _ d: Int) -> Int { d == 0 ? y - 1 : (d == 2 ? y : inY(y, d)) }
    func isCrack(_ x: Int, _ y: Int, _ d: Int) -> Bool { isIn(inX(x, d), inY(y, d)) && !isIn(outX(x, d), outY(y, d)) }
    var x = sx
    var y = sy
    var d = 0
    var out: [P2] = []
    let limit = 4 * (w + 2) * (h + 2)
    var n = 0
    while n < limit {
        n += 1
        let ix = inX(x, d), iy = inY(y, d), ox = outX(x, d), oy = outY(y, d)
        var t = 0.5
        if let level = level { t = min(1, max(0, level(ix, iy, ox, oy))) }
        out.append(P2(Double(ix) + 0.5 + Double(ox - ix) * t, Double(iy) + 0.5 + Double(oy - iy) * t))
        x += d == 0 ? 1 : (d == 2 ? -1 : 0)
        y += d == 1 ? 1 : (d == 3 ? -1 : 0)
        let r = (d + 1) & 3
        let l = (d + 3) & 3
        if isCrack(x, y, r) {
            d = r
        } else if !isCrack(x, y, d) {
            if !isCrack(x, y, l) { break }
            d = l
        }
        if x == sx && y == sy && d == 0 { break }
    }
    return out
}

/// Signed area (positive = counter-clockwise in a y-up frame).
public func polygonArea(_ pts: [P2]) -> Double {
    var a = 0.0
    for i in 0..<pts.count {
        let p = pts[i]
        let q = pts[(i + 1) % pts.count]
        a += p.x * q.y - q.x * p.y
    }
    return a / 2
}
