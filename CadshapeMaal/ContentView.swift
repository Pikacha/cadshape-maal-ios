import HoleKit
import SwiftUI
import UIKit

let accent = Color(red: 0.95, green: 0.66, blue: 0.23)
let good = Color(red: 0.36, green: 0.85, blue: 0.55)

struct ContentView: View {
    @StateObject private var model = MeasureModel()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            if model.isDemo {
                DemoCameraView(model: model).ignoresSafeArea()
            } else {
                ARMeasureView(model: model).ignoresSafeArea()
            }
            OverlayView(model: model).ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 12) {
                TopBar(model: model)
                Spacer(minLength: 0)
                if model.wantsPairing {
                    PairingCard(model: model)
                } else {
                    BottomPanel(model: model)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            if let fatal = model.fatal {
                Text(fatal)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(32)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showSettings) { SettingsSheet(model: model) }
        .background(EmptyView().sheet(isPresented: $model.showSaved) { SavedSheet(model: model, store: model.store) })
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        // Only ask the PC while the app is on screen.
        .onChange(of: phase) { p in
            if p == .active { model.startChecking() } else { model.stopChecking() }
        }
    }
}

// MARK: Drawn on top of the camera

/// The cross-hair, the hole's outline as found, and its size next to it.
struct OverlayView: View {
    @ObservedObject var model: MeasureModel

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            if model.wantsPairing {
                let side = min(size.width, size.height) * 0.62
                let frame = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
                ctx.stroke(Path(roundedRect: frame, cornerRadius: 28), with: .color(accent), style: StrokeStyle(lineWidth: 3, dash: [18, 12]))
                return
            }
            let pts = model.outlineOnScreen
            if pts.count > 2 {
                var p = Path()
                p.addLines(pts)
                p.closeSubpath()
                let color = model.steadiness > 0.7 ? good : accent
                ctx.fill(p, with: .color(color.opacity(0.2)))
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 3, lineJoin: .round))
                let top = pts.min { $0.y < $1.y } ?? c
                let xs = pts.map(\.x)
                let mid = ((xs.min() ?? c.x) + (xs.max() ?? c.x)) / 2
                if let text = model.answer?.text ?? model.quick {
                    let label = Text(text).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundColor(.white)
                    ctx.draw(label, at: CGPoint(x: mid, y: max(70, top.y - 18)), anchor: .bottom)
                }
            }
            // The holes already in the pattern, numbered.
            for (i, p) in model.patternOnScreen.enumerated() {
                guard let p else { continue }
                let r: CGFloat = 15
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(good.opacity(0.85)))
                ctx.draw(Text("\(i + 1)").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(.black), at: p)
            }
            if !model.locked && !model.patternLocked {
                var cross = Path()
                for (dx, dy) in [(-1.0, 0.0), (1.0, 0.0), (0.0, -1.0), (0.0, 1.0)] {
                    cross.move(to: CGPoint(x: c.x + dx * 6, y: c.y + dy * 6))
                    cross.addLine(to: CGPoint(x: c.x + dx * 20, y: c.y + dy * 20))
                }
                ctx.stroke(cross, with: .color(.black.opacity(0.5)), lineWidth: 4)
                ctx.stroke(cross, with: .color(.white), lineWidth: 2)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)), with: .color(accent))
            }
        }
    }
}

// MARK: Top

struct TopBar: View {
    @ObservedObject var model: MeasureModel
    @ObservedObject var store: MeasurementStore

    init(model: MeasureModel) {
        self.model = model
        store = model.store
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.showSettings = true
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(dot).frame(width: 9, height: 9)
                    Text(status).font(.footnote.weight(.semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold)).opacity(0.7)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                model.showSaved = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "tray.full")
                    if !store.waiting.isEmpty { Text("\(store.waiting.count)").monospacedDigit() }
                }
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(store.waiting.isEmpty ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(accent.opacity(0.85)), in: Capsule())
                .foregroundStyle(store.waiting.isEmpty ? Color.white : Color.black)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Lagrede målinger")
            HStack(spacing: 5) {
                Image(systemName: model.hasLidar ? "dot.radiowaves.left.and.right" : "camera")
                Text(model.hasLidar ? "LiDAR" : "Uten LiDAR")
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(.top, 4)
    }

    private var dot: Color {
        if model.isDemo { return accent }
        if model.pairing == nil { return .gray }
        if model.pcOpen == true { return good }
        return model.connectionError == nil ? .yellow : .red
    }

    private var status: String {
        if model.isDemo { return "Demo – uten kamera og PC" }
        guard let p = model.pairing else { return "Ikke koblet til" }
        if model.pcOpen == true { return "CadSHAPE · \(p.hostLabel)" }
        if model.pcOpen == false { return "CadSHAPE er ikke åpent" }
        return model.connectionError == nil ? "Kobler til \(p.hostLabel) …" : (p.isOnline ? "Får ikke kontakt" : "PC-en svarer ikke")
    }
}

// MARK: Bottom

struct GlassPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
    }
}

struct BottomPanel: View {
    @ObservedObject var model: MeasureModel

    var body: some View {
        VStack(spacing: 8) {
            WaitingBanner(model: model, store: model.store)
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }
            }
            .modifier(GlassPanel())
        }
    }

    @ViewBuilder private var content: some View {
        if model.patternLocked {
            PatternLockedContent(model: model)
        } else if model.locked {
            LockedContent(model: model)
        } else {
            LiveContent(model: model)
        }
    }
}

/// «2 målinger venter – send» when CadSHAPE is open again.
struct WaitingBanner: View {
    @ObservedObject var model: MeasureModel
    @ObservedObject var store: MeasurementStore

    var body: some View {
        if model.connected && !model.isDemo && !store.waiting.isEmpty && !model.locked && !model.patternLocked {
            Button {
                model.showSaved = true
            } label: {
                Label("\(store.waiting.count) \(store.waiting.count == 1 ? "måling venter" : "målinger venter") – send til CadSHAPE", systemImage: "tray.and.arrow.up.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(accent, in: Capsule())
                    .foregroundStyle(Color.black)
            }
            .buttonStyle(.plain)
        }
    }
}

/// The big size, with how sure it is.
struct SizeHeader: View {
    let text: String
    let sure: String?
    let unsure: Bool
    var label: String? = nil
    var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(text)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 8)
                if busy { ProgressView() } else if let label { Text(label).font(.caption.weight(.semibold)).opacity(0.7) }
            }
            if let sure {
                Label(unsure ? "\(sure) – usikkert, gå nærmere og hold stille" : sure, systemImage: unsure ? "exclamationmark.triangle.fill" : "scope")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(unsure ? accent : Color.white.opacity(0.75))
            }
        }
    }
}

struct LiveContent: View {
    @ObservedObject var model: MeasureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Hva måles", selection: $model.mode) {
                ForEach(MeasureMode.allCases) { m in Text(m.label).tag(m) }
            }
            .pickerStyle(.segmented)
            SizeHeader(text: model.answer?.text ?? model.quick ?? "Sikt på hullet", sure: model.uncertaintyText, unsure: model.unsure, label: model.answer?.label)
            if !model.details.isEmpty {
                Text(model.details).font(.footnote).opacity(0.75)
            }
            SteadyBar(value: model.steadiness)
            Text(model.hint).font(.subheadline.weight(.medium)).foregroundStyle(model.steadiness > 0.7 ? good : accent)
            if model.mode == .pattern {
                PatternLive(model: model)
            } else {
                Button {
                    model.lock()
                } label: {
                    Label(model.autoLock ? "Lås nå" : "Lås målet", systemImage: "lock.fill")
                }
                .buttonStyle(PrimaryStyle(enabled: model.canLock))
                .disabled(!model.canLock)
            }
        }
    }
}

/// Adding holes to the pattern: how many, the distances, and the buttons.
struct PatternLive: View {
    @ObservedObject var model: MeasureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.pattern.isEmpty {
                Text("Sikt på hullene ett for ett. Hvert hull legges til når målet er stødig.").font(.footnote).opacity(0.75)
            } else {
                Text(summary).font(.footnote.weight(.semibold)).opacity(0.85)
            }
            HStack(spacing: 10) {
                Button {
                    model.undoHole()
                } label: {
                    Label("Angre", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(SecondaryStyle())
                .disabled(model.pattern.isEmpty)
                Button {
                    model.addHole()
                } label: {
                    Label("Legg til hull", systemImage: "plus.circle.fill")
                }
                .buttonStyle(SecondaryStyle())
                .disabled(!model.canAddHole)
            }
            Button {
                model.finishPattern()
            } label: {
                Label(model.pattern.count >= 2 ? "Ferdig med \(model.pattern.count) hull" : "Minst to hull", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(PrimaryStyle(enabled: model.pattern.count >= 2))
            .disabled(model.pattern.count < 2)
        }
    }

    private var summary: String {
        let gaps = model.patternSpacings.map { mm($0) }.joined(separator: " · ")
        return "\(model.pattern.count) hull" + (gaps.isEmpty ? "" : " · avstand \(gaps) mm")
    }
}

/// A choice shown as a card with a picture: what to make.
struct ChoiceCard: View {
    let title: String
    let symbol: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 22, weight: .semibold))
                Text(title).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(on ? accent : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(on ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct LockedContent: View {
    @ObservedObject var model: MeasureModel
    @State private var adjust = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SizeHeader(text: model.shape?.text ?? "Tilpasser formen …", sure: model.uncertaintyText, unsure: model.unsure, busy: model.working)
            HStack(spacing: 8) {
                if let d = model.shape?.diameter, !nearStandard(d).isEmpty {
                    Text("Standard:").font(.footnote).opacity(0.75)
                    ForEach(nearStandard(d), id: \.self) { s in
                        Button("\(Int(s)) mm") { model.useStandard(s) }
                            .buttonStyle(ChipStyle(on: abs(s - d) < 0.01))
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    Picker("Form", selection: $model.forcedKind) {
                        Text("Automatisk").tag(ShapeKind?.none)
                        ForEach(ShapeKind.allCases) { k in Text(k.label).tag(ShapeKind?.some(k)) }
                    }
                } label: {
                    Label(model.forcedKind?.short ?? "Form", systemImage: "slider.horizontal.3").font(.footnote.weight(.semibold))
                }
            }
            if let depth = model.depthMM {
                Button {
                    model.useDepth()
                } label: {
                    Label("Hullet er \(Int(depth.rounded())) mm dypt (LiDAR) – bruk som dybde", systemImage: "arrow.down.to.line")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(ChipStyle(on: false))
            }
            HStack(spacing: 8) {
                ForEach(MakeKind.allCases) { k in
                    ChoiceCard(title: k.short, symbol: k.symbol, on: model.make == k) { model.make = k }
                }
            }
            Text(model.make.hint).font(.footnote).opacity(0.75)
            DisclosureGroup(isExpanded: $adjust) {
                VStack(spacing: 8) {
                    ForEach(model.make.uses) { key in
                        ParamRow(key: key, value: model.params[key] ?? key.defaultValue) { model.setParam(key, $0) }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Juster mål").font(.subheadline.weight(.semibold))
            }
            .tint(.white)
            if let done = model.done {
                Label(done, systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(good)
            } else if model.lockedByItself {
                Label("Låst av seg selv – trykk «Mål på nytt» hvis det ble feil", systemImage: "lock.fill").font(.footnote).opacity(0.7)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(accent)
            }
            HStack(spacing: 10) {
                Button {
                    model.measureAgain()
                } label: {
                    Label("Mål på nytt", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(SecondaryStyle())
                Button {
                    model.commit()
                } label: {
                    Label(model.connected ? "Lag i CadSHAPE" : "Lagret", systemImage: model.connected ? "cube.fill" : "tray.fill")
                }
                .buttonStyle(PrimaryStyle(enabled: canMake))
                .disabled(!canMake)
            }
        }
    }

    private var canMake: Bool { model.connected && model.shape != nil && !model.working }
}

/// A finished pattern: what to make, and the button.
struct PatternLockedContent: View {
    @ObservedObject var model: MeasureModel
    @State private var adjust = false

    var body: some View {
        let holes = model.patternLayout()
        VStack(alignment: .leading, spacing: 12) {
            SizeHeader(text: "\(holes.count) hull", sure: nil, unsure: false, busy: model.working)
            Text(model.patternText(holes)).font(.footnote).opacity(0.8)
            HStack(spacing: 8) {
                ForEach(HolesMake.allCases) { k in
                    ChoiceCard(title: k.label, symbol: k.symbol, on: model.holesMake == k) { model.setHolesMake(k) }
                }
            }
            Text(model.holesMake.hint).font(.footnote).opacity(0.75)
            DisclosureGroup(isExpanded: $adjust) {
                VStack(spacing: 8) {
                    ForEach(model.holesMake.uses) { key in
                        ParamRow(key: key, value: model.holesParams[key] ?? holesDefaults[key] ?? key.defaultValue) { model.setHolesParam(key, $0) }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Juster mål").font(.subheadline.weight(.semibold))
            }
            .tint(.white)
            if let done = model.done {
                Label(done, systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(good)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(accent)
            }
            HStack(spacing: 10) {
                Button {
                    model.newPattern()
                } label: {
                    Label("Nytt mønster", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(SecondaryStyle())
                Button {
                    model.commitPattern()
                } label: {
                    Label(model.connected ? "Lag i CadSHAPE" : "Lagret", systemImage: model.connected ? "cube.fill" : "tray.fill")
                }
                .buttonStyle(PrimaryStyle(enabled: model.connected && !model.working))
                .disabled(!model.connected || model.working)
            }
        }
    }
}

struct ParamRow: View {
    let key: ParamKey
    let value: Double
    let change: (Double) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(key.label).font(.subheadline)
            Spacer(minLength: 4)
            Button { change(value - key.step) } label: { Image(systemName: "minus") }
                .buttonStyle(RoundStyle())
            Text(mm(value, digits: key.step < 1 ? 1 : 0) + " mm")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 70)
            Button { change(value + key.step) } label: { Image(systemName: "plus") }
                .buttonStyle(RoundStyle())
        }
    }
}

struct SteadyBar: View {
    let value: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(value > 0.7 ? good : accent).frame(width: max(6, g.size.width * value))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.25), value: value)
    }
}

// MARK: Saved measurements

struct SavedSheet: View {
    @ObservedObject var model: MeasureModel
    @ObservedObject var store: MeasurementStore
    @State private var sending: Set<UUID> = []
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(accent)
                }
                if store.items.isEmpty {
                    Text("Ingen målinger ennå. Alt du låser lagres her, også når CadSHAPE ikke er åpent.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(store.items) { m in
                    HStack(spacing: 12) {
                        Group {
                            if let img = store.image(m) {
                                Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Image(systemName: m.isPattern ? "circle.grid.2x2" : "circle.dashed").font(.title2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(m.text).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(subtitle(m)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if m.sentAt != nil {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(good)
                        } else if sending.contains(m.id) {
                            ProgressView()
                        } else {
                            Button("Send") { send(m) }
                                .buttonStyle(ChipStyle(on: model.connected))
                                .disabled(!model.connected)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { store.remove(m.id) } label: { Label("Slett", systemImage: "trash") }
                        if m.sentAt != nil {
                            Button { send(m) } label: { Label("Send igjen", systemImage: "arrow.up.circle") }.tint(.blue)
                        }
                    }
                }
            }
            .navigationTitle("Målinger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if model.connected && !store.waiting.isEmpty {
                        Button("Send alle") { store.waiting.forEach(send) }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ferdig") { model.showSaved = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func subtitle(_ m: SavedMeasurement) -> String {
        var parts = [m.date.formatted(date: .abbreviated, time: .shortened)]
        if let make = m.make, !m.isPattern { parts.append(make.label) }
        if let make = m.holesMake, m.isPattern { parts.append(make.label) }
        if let u = m.uncertainty { parts.append("± \(mm(u)) mm") }
        parts.append(m.sentAt == nil ? "venter" : "laget")
        return parts.joined(separator: " · ")
    }

    private func send(_ m: SavedMeasurement) {
        sending.insert(m.id)
        problem = nil
        model.send(m) { err in
            sending.remove(m.id)
            if let err { problem = err }
        }
    }
}

// MARK: Connecting

struct PairingCard: View {
    @ObservedObject var model: MeasureModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "qrcode.viewfinder").font(.system(size: 36)).foregroundStyle(accent)
            Text("Koble til CadSHAPE").font(.title3.bold())
            Text("På PC-en: start CadSHAPE med START_CADSHAPE_MOBIL.bat, så Fil → «Mål med telefonen». Sikt kameraet på QR-koden. Eller logg inn på CadSHAPE på nett under innstillinger.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .opacity(0.8)
            HStack(spacing: 10) {
                Button("CadSHAPE på nett") { model.showSettings = true }
                    .buttonStyle(SecondaryStyle())
                Button(model.pairing == nil ? "Mål uten PC" : "Avbryt") { model.wantsPairing = false }
                    .buttonStyle(SecondaryStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .modifier(GlassPanel())
    }
}

struct SettingsSheet: View {
    @ObservedObject var model: MeasureModel
    @State private var link = ""
    @State private var badLink = false
    @State private var web = "kloki.no/cadshape"
    @State private var password = ""
    @State private var loggingIn = false
    @State private var loginError: String?
    private let login = WebLogin()

    var body: some View {
        NavigationStack {
            Form {
                Section("Tilkoblet") {
                    if let p = model.pairing {
                        LabeledContent(p.isOnline ? "Nett" : "PC", value: p.hostLabel)
                        LabeledContent("CadSHAPE", value: model.pcOpen == true ? "åpent" : (model.pcOpen == false ? "ikke åpent" : "ingen kontakt"))
                        if let e = model.connectionError {
                            Text(e).font(.footnote).foregroundStyle(accent)
                        }
                        Button("Sjekk tilkoblingen") { model.checkPc() }
                        Button(p.isOnline ? "Logg ut" : "Glem denne PC-en", role: .destructive) { model.forget() }
                    } else {
                        Text("Ikke koblet til ennå.")
                    }
                }
                Section {
                    TextField("kloki.no/cadshape", text: $web)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Passord", text: $password)
                        .textContentType(.password)
                    Button {
                        guard let base = Pairing.webAddress(web) else {
                            loginError = "Skriv adressen, f.eks. kloki.no/cadshape."
                            return
                        }
                        loggingIn = true
                        loginError = nil
                        login.login(base: base, password: password) { r in
                            loggingIn = false
                            switch r {
                            case .success(let session):
                                password = ""
                                model.loggedIn(base: base, session: session)
                            case .failure(let e):
                                loginError = e.message
                            }
                        }
                    } label: {
                        HStack {
                            Text("Logg inn")
                            if loggingIn { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(password.isEmpty || loggingIn)
                    if let loginError {
                        Text(loginError).font(.footnote).foregroundStyle(accent)
                    }
                } header: {
                    Text("CadSHAPE på nett")
                } footer: {
                    Text("Virker hvor som helst med nett, uten .bat-fil og QR-kode. Passordet lagres ikke; innloggingen huskes i 90 dager. Delene lages i CadSHAPE som er åpent i en nettleser.")
                }
                Section {
                    Button {
                        model.showSettings = false
                        model.wantsPairing = true
                    } label: {
                        Label("Skann QR-koden", systemImage: "qrcode.viewfinder")
                    }
                    TextField("https://192.168.…:5192/maal.html?k=…", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Koble til") {
                        if let p = Pairing.parse(link) {
                            badLink = false
                            model.paired(p)
                        } else {
                            badLink = true
                        }
                    }
                    if badLink {
                        Text("Lenken må være den fra QR-koden i CadSHAPE (med ?k=…).").font(.footnote).foregroundStyle(accent)
                    }
                } header: {
                    Text("PC-en på samme wifi")
                }
                Section {
                    Toggle("Lås av seg selv når målet er stødig", isOn: $model.autoLock)
                } header: {
                    Text("Måling")
                } footer: {
                    Text("Låser etter ett stødig sekund (i hullmønster: legger hullet til). Du kan alltid måle på nytt.")
                }
                Section("Slik måler appen") {
                    Text("Kanten på hullet finnes i kamerabildet (eller i LiDAR-dybden når hullet ikke skiller seg ut). LiDAR måler flaten rundt hullet – avstand og vinkel – og kanten legges ned på flaten i millimeter. ± viser hvor sikkert målet er. LiDAR ser også hvor dypt hullet er.")
                        .font(.footnote)
                    Text("Best resultat: 30–80 cm unna, mest mulig rett på, godt lys og hele kanten i bildet.")
                        .font(.footnote)
                }
            }
            .navigationTitle("CadSHAPE Mål")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ferdig") { model.showSettings = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: Buttons

struct PrimaryStyle: ButtonStyle {
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(Color.black)
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
    }
}

struct SecondaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.white.opacity(configuration.isPressed ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(Color.white)
    }
}

struct ChipStyle: ButtonStyle {
    var on = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(on ? accent : Color.white.opacity(configuration.isPressed ? 0.25 : 0.14), in: Capsule())
            .foregroundStyle(on ? Color.black : Color.white)
    }
}

struct RoundStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .frame(width: 34, height: 34)
            .background(Color.white.opacity(configuration.isPressed ? 0.28 : 0.14), in: Circle())
            .foregroundStyle(Color.white)
    }
}
