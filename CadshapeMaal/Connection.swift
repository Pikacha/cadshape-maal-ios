import CryptoKit
import Foundation
import HoleKit
import Security

/// The CadSHAPE server on the PC, from the QR code in CadSHAPE (Fil → Mål med telefonen):
/// https://192.168.1.20:5192/maal.html?k=KEY. The key lets the phone in; nothing else is stored.
struct Pairing: Codable, Equatable {
    var base: URL
    var key: String
    /// SHA-256 of the PC's certificate, remembered the first time (CadSHAPE makes its own certificate).
    var pin: String?

    static func parse(_ text: String) -> Pairing? {
        guard let comps = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = comps.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = comps.host, !host.isEmpty,
              let key = comps.queryItems?.first(where: { $0.name == "k" })?.value,
              key.range(of: "^[A-Za-z0-9_-]{16,}$", options: .regularExpression) != nil
        else { return nil }
        var b = URLComponents()
        b.scheme = scheme
        b.host = host
        b.port = comps.port
        guard let base = b.url else { return nil }
        return Pairing(base: base, key: key, pin: nil)
    }

    func sameServer(_ other: Pairing) -> Bool { base == other.base && key == other.key }

    var hostLabel: String { base.host ?? base.absoluteString }

    private static let store = "cadshape.pairing"

    static func load() -> Pairing? {
        guard let data = UserDefaults.standard.data(forKey: store) else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Pairing.store) }
    }

    static func forget() { UserDefaults.standard.removeObject(forKey: store) }
}

/// The answer to an outline: the shape CadSHAPE fitted (same code as the web page).
struct ShapeAnswer {
    var shape: MeasuredShape
    var text: String
    var label: String
}

enum ClientError: Error {
    case offline(String)
    case refused(String)

    var message: String {
        switch self {
        case .offline(let m), .refused(let m): return m
        }
    }
}

/// Talks to CadSHAPE on the PC (server/live-bridge.ts: /api/live/scan).
final class CadshapeClient: NSObject, URLSessionDelegate {
    let pairing: Pairing
    /// Called (on the main thread) when the certificate was seen for the first time and should be remembered.
    var onPin: ((String) -> Void)?
    private var session: URLSession!
    /// The PC's certificate (SHA-256), guarded by `lock` (the delegate runs on its own queue).
    private var pinned: String?
    private let lock = NSLock()
    /// Set when this client is replaced: its cancelled requests are not reported.
    private var dead = false

    init(pairing: Pairing) {
        self.pairing = pairing
        pinned = pairing.pin
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func invalidate() {
        dead = true
        session.invalidateAndCancel()
    }

    // CadSHAPE's own certificate is not from a public authority: it is trusted for the paired PC only,
    // and after the first contact only if it is the same certificate (else: scan the QR code again).
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host == pairing.base.host,
              let trust = space.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else { return completionHandler(.performDefaultHandling, nil) }
        let der = SecCertificateCopyData(leaf) as Data
        let hash = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        lock.lock()
        let known = pinned
        if known == nil { pinned = hash }
        lock.unlock()
        if let known, known != hash { return completionHandler(.cancelAuthenticationChallenge, nil) }
        if known == nil {
            DispatchQueue.main.async { self.onPin?(hash) }
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private func request(_ path: String, body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: pairing.base.appendingPathComponent(path))
        r.httpShouldHandleCookies = false
        r.setValue("cadshape_key=\(pairing.key)", forHTTPHeaderField: "Cookie")
        if let body {
            r.httpMethod = "POST"
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func call(_ r: URLRequest, done: @escaping (Result<[String: Any], ClientError>) -> Void) {
        session.dataTask(with: r) { data, response, error in
            let result: Result<[String: Any], ClientError>
            if let error = error as NSError? {
                if error.code == NSURLErrorCancelled || error.code == NSURLErrorServerCertificateUntrusted {
                    result = .failure(.refused("Sertifikatet på PC-en er ikke det samme som sist. Skann QR-koden i CadSHAPE på nytt."))
                } else {
                    result = .failure(.offline("Får ikke kontakt med PC-en (\(self.pairing.hostLabel)). Er CadSHAPE startet med START_CADSHAPE_MOBIL.bat, og er telefonen på samme wifi?"))
                }
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
                if status == 403 {
                    result = .failure(.refused("PC-en slapp ikke telefonen inn. Skann QR-koden i CadSHAPE på nytt."))
                } else if status >= 400 || json["ok"] as? Bool == false {
                    result = .failure(.refused(json["error"] as? String ?? "CadSHAPE svarte med feil (\(status))."))
                } else {
                    result = .success(json)
                }
            }
            DispatchQueue.main.async {
                if !self.dead { done(result) }
            }
        }.resume()
    }

    /// Is the CadSHAPE window open on the PC? (nil = no contact)
    func status(done: @escaping (Result<Bool, ClientError>) -> Void) {
        call(request("api/live/scan/status")) { r in done(r.map { $0["pc"] as? Bool ?? false }) }
    }

    /// The hole's outline in mm; CadSHAPE fits the shape (forced to `kind` if given) and shows it when `preview`.
    func outline(_ points: [P2], kind: ShapeKind?, make: MakeKind, params: [ParamKey: Double], preview: Bool, done: @escaping (Result<ShapeAnswer, ClientError>) -> Void) {
        var body: [String: Any] = [
            "type": "outline",
            "points": points.map { [round4($0.x), round4($0.y)] },
            "make": make.rawValue,
            "params": paramsJSON(params),
            "preview": preview,
        ]
        if let kind { body["kind"] = kind.rawValue }
        call(request("api/live/scan", body: try? JSONSerialization.data(withJSONObject: body))) { r in
            done(r.flatMap { json -> Result<ShapeAnswer, ClientError> in
                guard let raw = json["shape"],
                      let data = try? JSONSerialization.data(withJSONObject: raw),
                      let shape = try? JSONDecoder().decode(MeasuredShape.self, from: data)
                else { return .failure(.refused("CadSHAPE sendte ingen form tilbake.")) }
                return .success(ShapeAnswer(shape: shape, text: json["text"] as? String ?? shape.text, label: json["label"] as? String ?? shape.kind.label))
            })
        }
    }

    /// Shows a shape on the PC (after locking: new size, part or settings).
    func preview(_ shape: MeasuredShape, make: MakeKind, params: [ParamKey: Double], locked: Bool, done: @escaping (Result<Void, ClientError>) -> Void = { _ in }) {
        post(type: "preview", shape: shape, make: make, params: params, locked: locked) { done($0.map { _ in () }) }
    }

    /// Makes the parts in CadSHAPE. Gives their description.
    func commit(_ shape: MeasuredShape, make: MakeKind, params: [ParamKey: Double], done: @escaping (Result<String, ClientError>) -> Void) {
        post(type: "commit", shape: shape, make: make, params: params, locked: true) { r in
            done(r.map { json in (json["result"] as? [String: Any])?["label"] as? String ?? "Delen" })
        }
    }

    func clear() {
        call(request("api/live/scan", body: try? JSONSerialization.data(withJSONObject: ["type": "clear"]))) { _ in }
    }

    private func post(type: String, shape: MeasuredShape, make: MakeKind, params: [ParamKey: Double], locked: Bool, done: @escaping (Result<[String: Any], ClientError>) -> Void) {
        guard let shapeData = try? JSONEncoder().encode(shape),
              let shapeJSON = try? JSONSerialization.jsonObject(with: shapeData)
        else { return done(.failure(.refused("Ugyldig form."))) }
        let body: [String: Any] = ["type": type, "shape": shapeJSON, "make": make.rawValue, "params": paramsJSON(params), "locked": locked]
        call(request("api/live/scan", body: try? JSONSerialization.data(withJSONObject: body)), done: done)
    }

    private func paramsJSON(_ p: [ParamKey: Double]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (k, v) in p { out[k.rawValue] = v }
        return out
    }

    private func round4(_ v: Double) -> Double { (v * 1e4).rounded() / 1e4 }
}
