import Foundation

// Meshes between the phone and CadSHAPE: binary STL in millimetres with Z up (CadSHAPE's
// convention), and ARKit/RealityKit's world in metres with Y up.

/// A triangle mesh: corners and faces (three indices each).
public struct TriangleMesh {
    public var vertices: [V3]
    public var faces: [UInt32]

    public init(vertices: [V3], faces: [UInt32]) {
        self.vertices = vertices
        self.faces = faces
    }

    public var triangleCount: Int { faces.count / 3 }

    /// The outer box: smallest and largest corner.
    public var bounds: (min: V3, max: V3)? {
        guard var lo = vertices.first else { return nil }
        var hi = lo
        for v in vertices {
            lo = V3(Swift.min(lo.x, v.x), Swift.min(lo.y, v.y), Swift.min(lo.z, v.z))
            hi = V3(Swift.max(hi.x, v.x), Swift.max(hi.y, v.y), Swift.max(hi.z, v.z))
        }
        return (lo, hi)
    }

    /// Size of the outer box.
    public var size: V3 {
        guard let b = bounds else { return V3(0, 0, 0) }
        return b.max - b.min
    }

    /// Every corner moved by `f`.
    public func mapped(_ f: (V3) -> V3) -> TriangleMesh { TriangleMesh(vertices: vertices.map(f), faces: faces) }
}

/// ARKit's world (metres, Y up, −Z away) to CadSHAPE (millimetres, Z up). `origin` (world) becomes 0.
public func worldToCad(_ p: V3, origin: V3 = V3(0, 0, 0)) -> V3 {
    let d = (p - origin) * 1000
    return V3(d.x, -d.z, d.y)
}

/// CadSHAPE (mm, Z up) to RealityKit's local space (m, Y up). The inverse of `worldToCad`.
public func cadToWorld(_ p: V3) -> V3 { V3(p.x, p.z, -p.y) / 1000 }

/// A binary STL (little endian, a normal per triangle). Degenerate triangles are left out.
public func binarySTL(_ mesh: TriangleMesh, header: String = "CadSHAPE Maal") -> Data {
    var tris: [(V3, V3, V3)] = []
    tris.reserveCapacity(mesh.triangleCount)
    var i = 0
    while i + 2 < mesh.faces.count {
        let a = Int(mesh.faces[i]), b = Int(mesh.faces[i + 1]), c = Int(mesh.faces[i + 2])
        i += 3
        guard a < mesh.vertices.count, b < mesh.vertices.count, c < mesh.vertices.count else { continue }
        let pa = mesh.vertices[a], pb = mesh.vertices[b], pc = mesh.vertices[c]
        if vlength(vcross(pb - pa, pc - pa)) < 1e-12 { continue }
        tris.append((pa, pb, pc))
    }
    var data = Data(count: 84 + 50 * tris.count)
    data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
        let h = Array(header.utf8.prefix(80))
        for (k, byte) in h.enumerated() { raw[k] = byte }
        raw.storeBytes(of: UInt32(tris.count).littleEndian, toByteOffset: 80, as: UInt32.self)
        var at = 84
        func put(_ v: Float) {
            raw.storeBytes(of: v.bitPattern.littleEndian, toByteOffset: at, as: UInt32.self)
            at += 4
        }
        for (pa, pb, pc) in tris {
            let n = vnormalized(vcross(pb - pa, pc - pa))
            for p in [n, pa, pb, pc] { put(Float(p.x)); put(Float(p.y)); put(Float(p.z)) }
            at += 2
        }
    }
    return data
}

/// Reads a binary STL (as CadSHAPE exports it). Corners are not merged: three per triangle.
public func parseBinarySTL(_ data: Data) -> TriangleMesh? {
    guard data.count >= 84 else { return nil }
    let bytes = [UInt8](data)
    func u32(_ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
    let n = Int(u32(80))
    guard n > 0, data.count >= 84 + 50 * n else { return nil }
    var vertices: [V3] = []
    vertices.reserveCapacity(3 * n)
    var faces: [UInt32] = []
    faces.reserveCapacity(3 * n)
    for t in 0..<n {
        let base = 84 + 50 * t + 12
        for k in 0..<3 {
            let at = base + 12 * k
            let x = Float(bitPattern: u32(at)), y = Float(bitPattern: u32(at + 4)), z = Float(bitPattern: u32(at + 8))
            faces.append(UInt32(vertices.count))
            vertices.append(V3(Double(x), Double(y), Double(z)))
        }
    }
    return TriangleMesh(vertices: vertices, faces: faces)
}

/// The triangles of `mesh` with their middle within `radius` of `centre` (a piece of the room).
public func crop(_ mesh: TriangleMesh, centre: V3, radius: Double) -> TriangleMesh {
    var map: [UInt32: UInt32] = [:]
    var vertices: [V3] = []
    var faces: [UInt32] = []
    var i = 0
    while i + 2 < mesh.faces.count {
        let idx = [mesh.faces[i], mesh.faces[i + 1], mesh.faces[i + 2]]
        i += 3
        guard idx.allSatisfy({ Int($0) < mesh.vertices.count }) else { continue }
        let mid = (mesh.vertices[Int(idx[0])] + mesh.vertices[Int(idx[1])] + mesh.vertices[Int(idx[2])]) / 3
        if vlength(mid - centre) > radius { continue }
        for k in idx {
            if let m = map[k] { faces.append(m); continue }
            let m = UInt32(vertices.count)
            map[k] = m
            vertices.append(mesh.vertices[Int(k)])
            faces.append(m)
        }
    }
    return TriangleMesh(vertices: vertices, faces: faces)
}

/// At most `count` corners spread over the mesh (for checks every frame).
public func sampleVertices(_ mesh: TriangleMesh, count: Int) -> [V3] {
    if mesh.vertices.count <= count { return mesh.vertices }
    let step = Double(mesh.vertices.count) / Double(count)
    return (0..<count).map { mesh.vertices[Int(Double($0) * step)] }
}
