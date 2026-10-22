import Foundation

/// The hole found around the point the user aims at (same method as the web page, src/scan/vision/hole.ts).
public struct Hole {
    /// Outline in picture coordinates, clockwise on screen, sub-pixel.
    public var outline: [P2]
    /// 1 = in the hole (picture size).
    public var mask: [UInt8]
    public var minX: Int
    public var minY: Int
    public var maxX: Int
    public var maxY: Int
    /// Brightness difference between the hole and its surroundings.
    public var contrast: Double

    public var centroid: P2 {
        var c = P2(0, 0)
        for p in outline { c += p }
        return c / Double(max(1, outline.count))
    }
}

/// Square search areas around the point, as a share of the picture's short side.
private let sizes: [Double] = [0.06, 0.1, 0.15, 0.22, 0.31, 0.42, 0.56]

/// The hole: the patch around `seed` that differs from what surrounds it. Tries growing
/// squares; in each, splits by brightness (Otsu), grows the seed's group, and takes the
/// first patch that is closed with a clear edge. Enclosed specks are filled in.
public func findHole(_ g: GrayImage, seed: P2) -> Hole? {
    let w = g.width
    let h = g.height
    let data = g.pixels
    let sx = Int(seed.x)
    let sy = Int(seed.y)
    if sx < 1 || sy < 1 || sx >= w - 1 || sy >= h - 1 { return nil }
    var near: [UInt8] = []
    for dy in -1...1 { for dx in -1...1 { near.append(data[(sy + dy) * w + sx + dx]) } }
    near.sort()
    let seedValue = Double(near[4])
    let minDim = Double(min(w, h))
    var region = [UInt8](repeating: 0, count: w * h)
    var stack = [Int](repeating: 0, count: w * h)

    for f in sizes {
        let half = Int((minDim * f).rounded())
        let x0 = max(0, sx - half), x1 = min(w - 1, sx + half)
        let y0 = max(0, sy - half), y1 = min(h - 1, sy + half)
        var hist = [Int](repeating: 0, count: 256)
        for y in y0...y1 { for x in x0...x1 { hist[Int(data[y * w + x])] += 1 } }
        let (t, low, high) = otsu(hist)
        if high - low < 20 { continue }
        let dark = seedValue < t
        func same(_ i: Int) -> Bool { dark ? Double(data[i]) < t : Double(data[i]) >= t }
        let start = sy * w + sx
        if !same(start) { continue }

        // Grow the seed's group inside the square; give up if it reaches the square's edge.
        for y in y0...y1 { for x in x0...x1 { region[y * w + x] = 0 } }
        var top = 0
        stack[top] = start
        top += 1
        region[start] = 1
        var count = 0
        var touches = false
        var bx0 = sx, bx1 = sx, by0 = sy, by1 = sy
        while top > 0 {
            top -= 1
            let p = stack[top]
            let x = p % w
            let y = p / w
            count += 1
            if x <= x0 || x >= x1 || y <= y0 || y >= y1 {
                touches = true
                break
            }
            bx0 = min(bx0, x); bx1 = max(bx1, x); by0 = min(by0, y); by1 = max(by1, y)
            for q in [p - 1, p + 1, p - w, p + w] where region[q] == 0 && same(q) {
                region[q] = 1
                stack[top] = q
                top += 1
            }
        }
        if touches || count < 40 { continue }

        // Fill everything enclosed: what cannot be reached from the box's border is hole.
        let ox = bx0 - 1, oy = by0 - 1
        let bw = bx1 - bx0 + 3, bh = by1 - by0 + 3
        var outside = [UInt8](repeating: 0, count: bw * bh)
        var st: [Int] = []
        st.reserveCapacity(2 * (bw + bh))
        func push(_ k: Int) { if outside[k] == 0 { outside[k] = 1; st.append(k) } }
        for x in 0..<bw { push(x); push((bh - 1) * bw + x) }
        for y in 0..<bh { push(y * bw); push(y * bw + bw - 1) }
        func inRegion(_ x: Int, _ y: Int) -> Bool { region[(oy + y) * w + ox + x] == 1 }
        while let k = st.popLast() {
            let x = k % bw, y = k / bw
            if x > 0, outside[k - 1] == 0, !inRegion(x - 1, y) { outside[k - 1] = 1; st.append(k - 1) }
            if x < bw - 1, outside[k + 1] == 0, !inRegion(x + 1, y) { outside[k + 1] = 1; st.append(k + 1) }
            if y > 0, outside[k - bw] == 0, !inRegion(x, y - 1) { outside[k - bw] = 1; st.append(k - bw) }
            if y < bh - 1, outside[k + bw] == 0, !inRegion(x, y + 1) { outside[k + bw] = 1; st.append(k + bw) }
        }
        var first = -1
        for y in 1..<(bh - 1) {
            for x in 1..<(bw - 1) where outside[y * bw + x] == 0 {
                let i = (oy + y) * w + ox + x
                region[i] = 1
                if first < 0 { first = i }
            }
        }
        if first < 0 { continue }

        // Sub-pixel outline, and the brightness a little inside and outside of it.
        var inSum = 0.0, outSum = 0.0, n = 0.0
        let reg = region
        let outline = traceOutline(width: w, height: h, start: first, isIn: { x, y in
            x >= 0 && y >= 0 && x < w && y < h && reg[y * w + x] == 1
        }, level: { ix, iy, ox, oy in
            if ox < 0 || oy < 0 || ox >= w || oy >= h { return 0.5 }
            let dx = ox - ix, dy = oy - iy
            let ax = min(w - 1, max(0, ix - 2 * dx)), ay = min(h - 1, max(0, iy - 2 * dy))
            let cx = min(w - 1, max(0, ox + 2 * dx)), cy = min(h - 1, max(0, oy + 2 * dy))
            inSum += Double(data[ay * w + ax])
            outSum += Double(data[cy * w + cx])
            n += 1
            let a = Double(data[iy * w + ix]), b = Double(data[oy * w + ox])
            return a == b ? 0.5 : (t - a) / (b - a)
        })
        let contrast = n > 0 ? abs(outSum - inSum) / n : 0
        if contrast < 18 || outline.count < 12 { continue }
        return Hole(outline: outline, mask: reg, minX: bx0, minY: by0, maxX: bx1, maxY: by1, contrast: contrast)
    }
    return nil
}
