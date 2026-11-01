import Foundation
import UIKit

/// «Rapporter problem»: what the app did lately, as plain text the user can send.
/// Only numbers, hints and errors – never pictures, passwords, keys or the PC's address key.
final class AppLog {
    static let shared = AppLog()
    private let lock = NSLock()
    private var lines: [String] = []
    private var last: String?
    private let keep = 300
    private let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Adds a line (the same line twice in a row is kept once – hints repeat many times a second).
    func add(_ area: String, _ text: String) {
        let line = "\(area): \(text)"
        lock.lock()
        defer { lock.unlock() }
        if line == last { return }
        last = line
        lines.append("\(time.string(from: Date())) \(line)")
        if lines.count > keep { lines.removeFirst(lines.count - keep) }
    }

    var recent: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

/// Short for `AppLog.shared.add` (not `log`: that would hide the maths function).
func applog(_ area: String, _ text: String) { AppLog.shared.add(area, text) }

extension MeasureModel {
    /// The report: app and phone, connection, what is being measured, the last measurement's
    /// numbers and the recent log.
    func problemReport() -> String {
        var out: [String] = []
        let info = Bundle.main.infoDictionary
        out.append("CadSHAPE Mål \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))")
        out.append("iOS \(UIDevice.current.systemVersion), \(deviceModel()), LiDAR: \(hasLidar ? "ja" : "nei")")
        out.append("Tid: \(Date().formatted(date: .numeric, time: .standard))")
        if let p = pairing {
            out.append("Tilkobling: \(p.isOnline ? "nett" : "PC på wifi") · CadSHAPE \(pcOpen == true ? "åpent" : (pcOpen == false ? "ikke åpent" : "ingen kontakt"))")
        } else {
            out.append("Tilkobling: ikke koblet til")
        }
        if let e = connectionError { out.append("Tilkoblingsfeil: \(e)") }
        out.append("Modus: \(mode.label) · autolås: \(autoLock ? "på" : "av") · låst: \(locked ? "ja" : "nei")")
        out.append("Hint nå: \(hint)")
        if let d = diagnosticsText { out.append("Siste låste måling:\n\(d)") }
        if mode.isSpace { out.append("LiDAR-modus: \(space.hint) · stødighet \(String(format: "%.2f", space.steadiness))") }
        out.append("Ventende målinger: \(store.waiting.count) av \(store.items.count)")
        out.append("")
        out.append("Siste hendelser:")
        out.append(contentsOf: AppLog.shared.recent.suffix(150))
        return out.joined(separator: "\n")
    }

    private func deviceModel() -> String {
        var s = utsname()
        uname(&s)
        return withUnsafeBytes(of: &s.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
