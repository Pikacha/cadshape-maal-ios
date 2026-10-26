import Foundation
import Security
import UIKit

/// One hole of a pattern, as it will be sent: position on the surface (mm, x right, y up as seen
/// from the room) and its shape.
struct PatternHoleOut: Codable, Equatable {
    var x: Double
    var y: Double
    var shape: MeasuredShape
}

/// The inside of a box, as sent (mm). Height 0 = not measured.
struct BoxOut: Codable, Equatable {
    var width: Double
    var length: Double
    var height: Double
    var wall: Double?

    var json: [String: Any] {
        var out: [String: Any] = ["width": width, "length": length, "height": height]
        if let wall { out["wall"] = wall }
        return out
    }
}

/// Something on a table: its footprint seen from above (mm, x right, y away, centred) and height.
struct ObjectOut: Codable, Equatable {
    var outline: [[Double]]
    var width: Double
    var length: Double
    var height: Double

    var json: [String: Any] { ["outline": outline, "width": width, "length": length, "height": height] }
}

/// A measurement kept on the phone: made from it, or waiting to be sent when CadSHAPE is open.
struct SavedMeasurement: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    /// One hole …
    var shape: MeasuredShape?
    var make: MakeKind?
    var params: [String: Double]?
    /// … or a pattern of holes.
    var holes: [PatternHoleOut]?
    var holesMake: HolesMake?
    var holesParams: [String: Double]?
    /// … or the inside of a box, or something on a table (with what to make and its settings).
    var box: BoxOut?
    var boxMake: BoxMake?
    var object: ObjectOut?
    var objectMake: ObjectMake?
    var spaceParams: [String: Double]?
    var text: String
    /// ± mm, how sure the measurement is.
    var uncertainty: Double?
    var depthMM: Double?
    /// File name of the picture next to the list (Documents/maalinger/).
    var photo: String?
    /// Made in CadSHAPE (and when).
    var sentAt: Date?

    var isPattern: Bool { holes != nil }

    /// A picture for the list when there is no photo.
    var symbol: String {
        if box != nil { return "shippingbox" }
        if object != nil { return "wrench.and.screwdriver" }
        return isPattern ? "circle.grid.2x2" : "circle.dashed"
    }

    /// What is made from it, for the list.
    var makeLabel: String? {
        if let m = boxMake, box != nil { return m.label }
        if let m = objectMake, object != nil { return m.label }
        if let m = holesMake, isPattern { return m.label }
        return make?.label
    }
}

/// The measurements on this phone (Documents/maalinger/liste.json and the pictures next to it).
final class MeasurementStore: ObservableObject {
    @Published private(set) var items: [SavedMeasurement] = []
    private let dir: URL
    private var file: URL { dir.appendingPathComponent("liste.json") }
    /// At most this many are kept (the oldest sent ones go first).
    private let keep = 200

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("maalinger", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([SavedMeasurement].self, from: data) {
            items = list
        }
    }

    var waiting: [SavedMeasurement] { items.filter { $0.sentAt == nil } }

    func photoURL(_ m: SavedMeasurement) -> URL? { m.photo.map { dir.appendingPathComponent($0) } }

    func image(_ m: SavedMeasurement) -> UIImage? { photoURL(m).flatMap { UIImage(contentsOfFile: $0.path) } }

    /// The picture as base64 JPEG for CadSHAPE (nil when there is none).
    func photoData(_ m: SavedMeasurement) -> String? {
        guard let url = photoURL(m), let data = try? Data(contentsOf: url) else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    /// Saves a new measurement (with its picture). Returns its id.
    @discardableResult
    func add(_ m: SavedMeasurement, image: UIImage?) -> UUID {
        var m = m
        if let image, let data = jpeg(image) {
            let name = "\(m.id.uuidString).jpg"
            if (try? data.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil { m.photo = name }
        }
        items.insert(m, at: 0)
        trim()
        save()
        return m.id
    }

    func update(_ id: UUID, _ change: (inout SavedMeasurement) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        save()
    }

    func remove(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if let url = photoURL(items[i]) { try? FileManager.default.removeItem(at: url) }
        items.remove(at: i)
        save()
    }

    private func trim() {
        while items.count > keep {
            let i = items.lastIndex { $0.sentAt != nil } ?? items.count - 1
            if let url = photoURL(items[i]) { try? FileManager.default.removeItem(at: url) }
            items.remove(at: i)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: file, options: .atomic) }
    }

    /// A small JPEG: at most 960 px wide, enough to recognise the hole (≈ 100 kB).
    private func jpeg(_ image: UIImage) -> Data? {
        let maxW: CGFloat = 960
        let size = image.size
        let k = min(1, maxW / max(1, size.width))
        let target = CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: target, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return small.jpegData(compressionQuality: 0.6)
    }
}

/// The login to CadSHAPE on the web, kept in the iPhone's keychain (not in the app's settings).
enum Keychain {
    private static let service = "no.cadshape.maal.session"

    static func save(_ value: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
