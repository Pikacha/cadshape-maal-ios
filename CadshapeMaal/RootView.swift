import HoleKit
import SwiftUI
import UIKit
import UserNotifications

/// The screens under «Hjem». Each has the camera to itself (one AR session at a time).
enum Screen: String, Identifiable {
    case measure, capture, part, place
    var id: String { rawValue }
}

struct RootView: View {
    @StateObject private var model = MeasureModel()
    @StateObject private var watch = PrintWatch()
    @State private var screen: Screen?
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if model.isDemo {
                ContentView(model: model)
            } else {
                HomeView(model: model, watch: watch) { screen = $0 }
                    .fullScreenCover(item: $screen) { s in
                        switch s {
                        case .measure: ContentView(model: model) { screen = nil }
                        case .capture: CaptureScreen(model: model) { screen = nil }
                        case .part: PartARScreen(model: model, watch: watch) { screen = nil }
                        case .place: PlaceScreen(model: model) { screen = nil }
                        }
                    }
                    .sheet(isPresented: $watch.showCard) { ApprovalSheet(watch: watch) }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            watch.model = model
            watch.start()
        }
        // Only ask the PC while the app is on screen.
        .onChange(of: phase) { _, p in
            if p == .active {
                model.startChecking()
                watch.start()
            } else {
                model.stopChecking()
                watch.stop()
            }
        }
    }
}

// MARK: Home

let ground = Color(red: 0.08, green: 0.10, blue: 0.13)
let panel = Color(red: 0.11, green: 0.13, blue: 0.17)
let muted = Color(red: 0.64, green: 0.68, blue: 0.73)
let blueTint = Color(red: 0.35, green: 0.64, blue: 0.90)

struct HomeView: View {
    @ObservedObject var model: MeasureModel
    @ObservedObject var watch: PrintWatch
    let open: (Screen) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Text("Hva vil du lage?")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .padding(.top, 4)
                if model.pairing == nil {
                    connectCard
                }
                bigTile
                HStack(spacing: 12) {
                    tile("Skann stedet", "Pek der delen skal sitte", "house", blueTint) { open(.place) }
                    tile("Se delen i AR", watch.lastPartLabel ?? "Ekte størrelse, før print", "cube.transparent", accent) { open(.part) }
                }
                quickMeasure
                if let card = watch.card, card.state == "venter" {
                    approvalBanner(card)
                }
                if !watch.openJoints.isEmpty, watch.sawFinish || watch.printer?.state == "complete" {
                    JointFitCard(watch: watch)
                }
                if let p = watch.printer, p.online {
                    PrinterRow(printer: p)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(ground.ignoresSafeArea())
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cube").foregroundStyle(accent).font(.title3.weight(.semibold))
                (Text("CadSHAPE ") + Text("Mål").foregroundColor(accent)).font(.headline)
            }
            Spacer()
            Button { open(.measure); model.showSettings = true } label: {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText).font(.footnote.weight(.semibold)).lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(statusColor.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var statusColor: Color {
        if model.pairing == nil { return .gray }
        return model.pcOpen == true ? good : (model.connectionError == nil ? .yellow : .red)
    }

    private var statusText: String {
        guard let p = model.pairing else { return "Ikke koblet til" }
        if model.pcOpen == true { return watch.printer?.ready == true ? "PC-en og skriveren er klare" : "Koblet til \(p.hostLabel)" }
        return model.pcOpen == false ? "CadSHAPE er ikke åpent" : "Kobler til …"
    }

    private var connectCard: some View {
        Button { open(.measure) } label: {
            HStack(spacing: 12) {
                Image(systemName: "qrcode.viewfinder").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Koble til CadSHAPE").font(.headline)
                    Text("Skann QR-koden under Fil → Mål med telefonen").font(.subheadline).foregroundStyle(muted)
                }
                Spacer()
            }
            .padding(16)
            .background(panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(accent.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var bigTile: some View {
        Button { open(.capture) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "viewfinder").font(.system(size: 30, weight: .semibold))
                Spacer(minLength: 24)
                Text("Skann en ting").font(.title2.bold())
                Text("Gå rundt den. Få en ekte 3D-modell å bygge holder, lokk eller lomme rundt.")
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                    .opacity(0.85)
            }
            .foregroundStyle(Color(red: 0.13, green: 0.09, blue: 0.04))
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
            .padding(18)
            .background(accent, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Åpner 3D-skanning med kamera og LiDAR")
    }

    private func tile(_ title: String, _ sub: String, _ icon: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon).font(.title2.weight(.semibold)).foregroundStyle(tint)
                Spacer(minLength: 16)
                Text(title).font(.headline)
                Text(sub).font(.subheadline).foregroundStyle(muted).lineLimit(2).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
            .padding(16)
            .background(panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var quickMeasure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mål raskt").font(.subheadline).foregroundStyle(muted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MeasureMode.allCases) { m in
                        Button {
                            model.mode = m
                            open(.measure)
                        } label: {
                            Label(m.short, systemImage: m.symbol)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .frame(minHeight: 44)
                                .background(panel, in: Capsule())
                                .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func approvalBanner(_ card: ApprovalCard) -> some View {
        Button { watch.showCard = true } label: {
            HStack(spacing: 12) {
                Group {
                    if let img = card.thumb {
                        Image(uiImage: img).resizable().scaledToFit()
                    } else {
                        Image(systemName: "cube.fill").foregroundStyle(accent)
                    }
                }
                .frame(width: 64, height: 52)
                .background(ground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Venter på deg").font(.footnote.weight(.semibold)).foregroundStyle(accent)
                    Text("Godkjenn print: \(card.name)").font(.headline).lineLimit(1)
                    Text(card.summary).font(.subheadline).foregroundStyle(muted)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(Color(red: 0.13, green: 0.16, blue: 0.21), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(accent.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// A joint in the model and the answers that make sense for it (from `GET api/live/phone/joints`).
struct JointQuestion: Identifiable, Equatable {
    struct Feel: Equatable {
        let feel: String
        let label: String
    }
    let id: String
    let part: String
    let label: String
    let felt: String?
    let feels: [Feel]

    init?(_ j: [String: Any]) {
        guard let key = j["key"] as? String, let label = j["label"] as? String else { return nil }
        id = key
        part = j["part"] as? String ?? ""
        self.label = label
        felt = j["felt"] as? String
        feels = (j["feels"] as? [[String: Any]] ?? []).compactMap { f in
            guard let feel = f["feel"] as? String, let label = f["label"] as? String else { return nil }
            return Feel(feel: feel, label: label)
        }
        if feels.isEmpty { return nil }
    }
}

/// «Hvordan passet den?» – after a print: one joint at a time, one tap teaches the printer twin.
struct JointFitCard: View {
    @ObservedObject var watch: PrintWatch

    var body: some View {
        let open = watch.openJoints
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "puzzlepiece.extension").foregroundStyle(accent)
                Text("Hvordan passet den?").font(.headline)
                Spacer()
                if open.count > 1 { Text("1 av \(open.count)").font(.footnote).foregroundStyle(muted) }
            }
            if let q = open.first {
                Text("\(q.label) i «\(q.part)»").font(.subheadline).foregroundStyle(muted)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(q.feels, id: \.feel) { f in
                        Button { watch.answer(q, feel: f.feel) } label: {
                            Text(f.label)
                                .font(.subheadline.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(f.feel == "slide" || f.feel == "press" ? accent.opacity(0.2) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(watch.jointBusy)
                    }
                }
            }
            if let m = watch.jointMessage {
                Text(m).font(.footnote).foregroundStyle(muted)
            }
        }
        .padding(16)
        .background(panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(accent.opacity(0.35), lineWidth: 1))
    }
}

/// The printer now: what it prints, how far, when it is done.
struct PrinterRow: View {
    let printer: PrinterInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(printer.stateLabel).font(.footnote.weight(.semibold)).foregroundStyle(printer.printing ? accent : muted)
                Spacer()
                if let end = printer.finishText { Text(end).font(.footnote.weight(.semibold)).monospacedDigit() }
            }
            Text(printer.title).font(.headline).lineLimit(1)
            if printer.printing {
                ProgressView(value: printer.progress ?? 0).tint(accent)
            }
        }
        .padding(14)
        .background(panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: «Godkjenn print» and the printer

struct ApprovalCard: Equatable {
    var id: String
    var name: String
    var seconds: Double?
    var grams: Double?
    var price: Double?
    var material: String
    var process: String
    var layers: Double?
    var gcodeName: String
    var warnings: [String]
    var note: String
    var state: String
    var error: String?
    var by: String
    var thumb: UIImage?

    init?(_ j: [String: Any], thumb: UIImage? = nil) {
        guard let id = j["id"] as? String, let name = j["name"] as? String else { return nil }
        self.id = id
        self.name = name
        seconds = j["seconds"] as? Double
        grams = j["grams"] as? Double
        price = j["price"] as? Double
        layers = j["layers"] as? Double
        material = j["material"] as? String ?? "PLA"
        process = j["process"] as? String ?? ""
        gcodeName = j["gcodeName"] as? String ?? ""
        warnings = j["warnings"] as? [String] ?? []
        note = j["note"] as? String ?? ""
        state = j["state"] as? String ?? "venter"
        error = j["error"] as? String
        by = j["by"] as? String ?? "assistent"
        if let t = j["thumb"] as? String, let comma = t.firstIndex(of: ","), let data = Data(base64Encoded: String(t[t.index(after: comma)...])) {
            self.thumb = UIImage(data: data)
        } else {
            self.thumb = thumb
        }
    }

    var summary: String {
        [duration(seconds), grams.map { "\(mm($0, digits: 1)) g" }, price.map { kroner($0) }].compactMap { $0 }.joined(separator: ", ")
    }

    static func == (a: ApprovalCard, b: ApprovalCard) -> Bool { a.id == b.id && a.state == b.state && a.error == b.error && (a.thumb == nil) == (b.thumb == nil) }
}

struct PrinterInfo: Equatable {
    var name: String
    var online: Bool
    var ready: Bool
    var state: String
    var progress: Double?
    var remaining: Double?
    var filename: String?

    init(_ j: [String: Any]) {
        name = j["name"] as? String ?? "Skriveren"
        online = (j["configured"] as? Bool ?? false) && (j["online"] as? Bool ?? true)
        ready = j["ready"] as? Bool ?? false
        state = j["state"] as? String ?? ""
        progress = j["progress"] as? Double
        remaining = j["remainingSeconds"] as? Double
        filename = j["filename"] as? String
    }

    var printing: Bool { state == "printing" || state == "paused" }
    var stateLabel: String {
        switch state {
        case "printing": return "Printer nå"
        case "paused": return "Pauset"
        case "complete": return "Ferdig"
        case "error": return "Stoppet med feil"
        default: return ready ? "Skriveren er klar" : "Skriveren"
        }
    }
    var title: String {
        if let f = filename, printing { return f.replacingOccurrences(of: ".gcode", with: "").replacingOccurrences(of: "_", with: " ") }
        return name
    }
    var finishText: String? {
        guard printing, let r = remaining, r > 0 else { return nil }
        let end = Date().addingTimeInterval(r)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "ferdig \(f.string(from: end)), \(duration(r) ?? "")"
    }
}

func duration(_ s: Double?) -> String? {
    guard let s, s > 0 else { return nil }
    let m = Int((s / 60).rounded())
    if m < 60 { return "\(max(1, m)) min" }
    return "\(m / 60) t \(m % 60) min"
}

func kroner(_ v: Double) -> String {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "nb_NO")
    f.minimumFractionDigits = 2
    f.maximumFractionDigits = 2
    return (f.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v)) + " kr"
}

/// Asks CadSHAPE every few seconds (while the app is on screen) for a waiting «Godkjenn print»
/// card and the printer's state, and puts a notification on the expected finish time.
final class PrintWatch: ObservableObject {
    @Published var card: ApprovalCard?
    @Published var printer: PrinterInfo?
    @Published var showCard = false
    @Published var answering = false
    @Published var answerError: String?
    /// The part last shown in AR (for the home screen).
    @Published var lastPartLabel: String?
    weak var model: MeasureModel?

    /// «Hvordan passet den?»: the joints in the open model (made with «Koble sammen»).
    @Published var joints: [JointQuestion] = []
    @Published var jointMessage: String?
    @Published var jointBusy = false
    /// A print finished while the app was watching – time to ask how the joints fit.
    @Published var sawFinish = false
    var openJoints: [JointQuestion] { joints.filter { $0.felt == nil } }

    private var timer: Timer?
    private var shownFor: String?
    private var notifiedFor: String?
    private var tick = 0
    private var lastState: String?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard let api = model?.api, model?.pcOpen != false else { return }
        api.getJSON("api/live/approval", query: ["brief": "1"]) { [weak self] r in
            guard let self, case .success(let j) = r else { return }
            guard let raw = j["card"] as? [String: Any], let brief = ApprovalCard(raw, thumb: self.card?.thumb) else {
                // Answered elsewhere: show how it ended, then let it go.
                if let latest = j["latest"] as? [String: Any], let l = ApprovalCard(latest, thumb: self.card?.thumb), l.id == self.card?.id { self.card = l } else if self.card?.state == "venter" { self.card = nil }
                return
            }
            if brief.id == self.card?.id {
                self.card = brief
            } else {
                self.card = brief
                api.getJSON("api/live/approval") { r in
                    if case .success(let full) = r, let raw = full["card"] as? [String: Any], let c = ApprovalCard(raw), c.id == brief.id { self.card = c }
                }
                // A new card: show it once on its own.
                if self.shownFor != brief.id {
                    self.shownFor = brief.id
                    self.showCard = true
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                }
            }
        }
        api.getJSON("api/live/printer/status") { [weak self] r in
            guard let self, case .success(let j) = r else { return }
            let p = PrinterInfo(j)
            self.printer = p
            self.scheduleDone(p)
            if self.lastState == "printing", p.state == "complete" {
                self.sawFinish = true
                self.loadJoints()
            }
            self.lastState = p.state
        }
        tick += 1
        if tick % 5 == 1 { loadJoints() }
    }

    func loadJoints() {
        guard let api = model?.api else { return }
        api.getJSON("api/live/phone/joints") { [weak self] r in
            guard let self, case .success(let j) = r, let res = j["result"] as? [String: Any] else { return }
            let list = (res["joints"] as? [[String: Any]] ?? []).compactMap(JointQuestion.init)
            if list != self.joints { self.joints = list }
        }
    }

    /// One answer for a joint: goes to the printer twin on the PC and onto the holes in the model.
    func answer(_ q: JointQuestion, feel: String) {
        guard let api = model?.api else { return }
        jointBusy = true
        jointMessage = nil
        api.postJSON("api/live/phone/joint", body: ["key": q.id, "feel": feel], timeout: 20) { [weak self] r in
            guard let self else { return }
            self.jointBusy = false
            switch r {
            case .success(let j):
                self.jointMessage = (j["result"] as? [String: Any])?["text"] as? String ?? "Lagret."
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self.loadJoints()
            case .failure(let e):
                self.jointMessage = e.message
            }
        }
    }

    /// «Ja, print» or «Nei» – only from the buttons.
    func answer(_ yes: Bool) {
        guard let api = model?.api, let card else { return }
        answering = true
        answerError = nil
        api.postJSON("api/live/approval/answer", body: ["id": card.id, "yes": yes, "confirmed": yes], timeout: 60) { [weak self] r in
            guard let self else { return }
            self.answering = false
            switch r {
            case .success(let j):
                if let raw = j["card"] as? [String: Any], let c = ApprovalCard(raw, thumb: card.thumb) { self.card = c }
                if j["failed"] as? Bool == true { self.answerError = j["error"] as? String ?? "Skriveren svarte ikke." }
                UINotificationFeedbackGenerator().notificationOccurred(yes ? .success : .warning)
                self.refresh()
            case .failure(let e):
                self.answerError = e.message
            }
        }
    }

    /// A notification when the print should be done (local – no Apple account or push needed).
    private func scheduleDone(_ p: PrinterInfo) {
        let center = UNUserNotificationCenter.current()
        let id = "cadshape.print.done"
        guard p.printing, p.state == "printing", let r = p.remaining, r > 60 else {
            if !p.printing { center.removePendingNotificationRequests(withIdentifiers: [id]) }
            return
        }
        // Re-plan when the estimate moves by more than two minutes.
        let key = "\(p.filename ?? "")|\(Int(r / 120))"
        if notifiedFor == key { return }
        notifiedFor = key
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let content = UNMutableNotificationContent()
            content.title = "Printen er ferdig"
            content.body = "\(p.title) skal være ferdig nå. Ta den av platen før neste print."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: r, repeats: false)
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }
}

struct ApprovalSheet: View {
    @ObservedObject var watch: PrintWatch
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let card = watch.card {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(card.by == "assistent" ? "Assistenten spør" : "Klar til print").font(.subheadline.weight(.semibold)).foregroundStyle(accent)
                        Text(card.name).font(.title2.bold())
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(panel)
                            if let img = card.thumb {
                                Image(uiImage: img).resizable().scaledToFit().padding(8)
                            } else {
                                Image(systemName: "cube").font(.largeTitle).foregroundStyle(muted)
                            }
                        }
                        .frame(height: 220)
                        HStack(alignment: .top) {
                            fact("Tid", duration(card.seconds) ?? "–")
                            fact("Plast", card.grams.map { "\(mm($0, digits: 1)) g \(card.material)" } ?? "–")
                            fact("Pris", card.price.map { kroner($0) } ?? "–")
                        }
                        Text([card.process, card.layers.map { "\(Int($0)) lag" }, card.gcodeName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
                            .font(.footnote).foregroundStyle(muted)
                        if !card.note.isEmpty { Text(card.note).font(.body) }
                        if card.warnings.isEmpty {
                            Label("Ingen advarsler", systemImage: "checkmark.circle").foregroundStyle(good).font(.subheadline)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(card.warnings, id: \.self) { w in
                                    Label(w, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.white)
                                }
                            }
                        }
                        if card.state == "venter" {
                            if let e = card.error ?? watch.answerError { Text("Ble ikke startet: \(e)").font(.subheadline).foregroundStyle(.red) }
                            Text("Er platen tom og ren?").font(.subheadline).foregroundStyle(muted)
                            HStack(spacing: 10) {
                                Button("Nei") { watch.answer(false) }
                                    .buttonStyle(SecondaryStyle())
                                    .frame(maxWidth: 110)
                                Button { watch.answer(true) } label: {
                                    Label(watch.answering ? "Sender …" : "Ja, print", systemImage: "play.fill")
                                }
                                .buttonStyle(PrimaryStyle())
                                .disabled(watch.answering)
                            }
                        } else {
                            Text(resultText(card)).font(.headline).foregroundStyle(card.state == "printer" ? good : muted)
                        }
                    }
                    .padding(20)
                } else {
                    Text("Ingen print venter.").foregroundStyle(muted).padding(40)
                }
            }
            .background(ground.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Lukk") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(muted)
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultText(_ c: ApprovalCard) -> String {
        switch c.state {
        case "printer": return "Sendt – skriveren printer nå."
        case "avvist": return "Ikke printet."
        case "erstattet": return "Erstattet av et nyere kort."
        case "utløpt": return "Kortet gikk ut. Be om et nytt."
        default: return c.error.map { "Feilet: \($0)" } ?? c.state
        }
    }
}
