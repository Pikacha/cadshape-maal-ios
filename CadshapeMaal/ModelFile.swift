import Foundation
import HoleKit
import ModelIO
import RealityKit
import SceneKit
import SwiftUI

/// Every triangle of a USDZ/OBJ as one mesh in the file's own space (metres for Object Capture).
func readModel(_ url: URL) -> TriangleMesh? {
    let asset = MDLAsset(url: url)
    var vertices: [V3] = []
    var faces: [UInt32] = []
    for case let mesh as MDLMesh in asset.childObjects(of: MDLMesh.self) {
        let m = MDLTransform.globalTransform(with: mesh, atTime: 0)
        guard let attr = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else { continue }
        let base = UInt32(vertices.count)
        for i in 0..<mesh.vertexCount {
            let p = attr.dataStart.advanced(by: i * attr.stride).assumingMemoryBound(to: Float.self)
            let w = m * SIMD4<Float>(p[0], p[1], p[2], 1)
            vertices.append(V3(Double(w.x), Double(w.y), Double(w.z)))
        }
        for sub in (mesh.submeshes as? [MDLSubmesh]) ?? [] where sub.geometryType == .triangles {
            let map = sub.indexBuffer.map()
            let n = sub.indexCount
            switch sub.indexType {
            case .uInt32:
                let p = map.bytes.assumingMemoryBound(to: UInt32.self)
                for k in 0..<n { faces.append(base + p[k]) }
            case .uInt16:
                let p = map.bytes.assumingMemoryBound(to: UInt16.self)
                for k in 0..<n { faces.append(base + UInt32(p[k])) }
            case .uInt8:
                let p = map.bytes.assumingMemoryBound(to: UInt8.self)
                for k in 0..<n { faces.append(base + UInt32(p[k])) }
            default:
                continue
            }
        }
    }
    return vertices.isEmpty || faces.isEmpty ? nil : TriangleMesh(vertices: vertices, faces: faces)
}

/// The finished model, turnable with a finger (SceneKit shows the USDZ with its colours).
struct ModelPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = try? SCNScene(url: url, options: nil)
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = true
        v.backgroundColor = UIColor(red: 0.11, green: 0.13, blue: 0.17, alpha: 1)
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}
