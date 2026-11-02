import HoleKit
import SwiftUI
import UIKit

let accent = Color(red: 0.95, green: 0.66, blue: 0.23)
let good = Color(red: 0.36, green: 0.85, blue: 0.55)
/// Something to look at (not an error): yellow, not the orange of the buttons.
let warn = Color(red: 1.0, green: 0.82, blue: 0.36)
/// Errors – always this, never the button orange.
let bad = Color(red: 1.0, green: 0.45, blue: 0.42)

/// Back / cancel on every full-screen view: the same 44 pt round button top left.
struct CloseButton: View {
    var label = "Tilbake"
    var icon = "xmark"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.headline)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.35), in: Circle())
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Measuring with the camera (one hole, or the inside of a box) – one of the screens under «Hjem».
/// The mode is fixed by the home screen's tile; this screen only shows its title.
struct ContentView: View {
    @ObservedObject var model: MeasureModel
    /// Back to the home screen.
    var onHome: (() -> Void)? = nil

    var body: some View {
        ZStack {
            ARMeasureView(model: model).ignoresSafeArea()
            OverlayView(model: model, space: model.space).ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    if let onHome {
                        CloseButton(label: "Til start", action: onHome)
                            .padding(.top, 4)
                    }
                    TopBar(model: model)
                }
                if !model.wantsPairing {
                    ModeTitle(mode: model.mode)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
    }
}

/// What this camera screen measures (Hull / Inni boks), small, under the top bar.
struct ModeTitle: View {
    let mode: MeasureMode

    var body: some View {
        Label(mode.title, systemImage: mode == .box ? "shippingbox" : "circle.dashed")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.35), in: Capsule())
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Drawn on top of the camera

/// The cross-hair, the hole's outline as found, and its size next to it.
struct OverlayView: View {
    @ObservedObject var model: MeasureModel
    @ObservedObject var space: SpaceModel

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            if model.wantsPairing {
                let side = min(size.width, size.height) * 0.62
                let frame = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
                ctx.stroke(Path(roundedRect: frame, cornerRadius: 28), with: .color(accent), style: StrokeStyle(lineWidth: 3, dash: [18, 12]))
                return
            }
            // The box's floor, from the LiDAR points.
            if model.mode.isSpace {
                let poly = space.polygonOnScreen
                if poly.count > 2 && !space.locked {
                    var p = Path()
                    p.addLines(poly)
                    p.closeSubpath()
                    let color = space.steadiness > 0.7 ? good : accent
                    ctx.fill(p, with: .color(color.opacity(0.18)))
                    ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 3, lineJoin: .round))
                    for q in poly {
                        ctx.fill(Path(ellipseIn: CGRect(x: q.x - 5, y: q.y - 5, width: 10, height: 10)), with: .color(color))
                    }
                }
            }
            let pts = model.mode.isSpace ? [] : model.outlineOnScreen
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
            if !model.locked && !(model.mode.isSpace && space.locked) {
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
                .frame(minHeight: 44)
                .background(Color.black.opacity(0.35), in: Capsule())
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
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(store.waiting.isEmpty ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(accent.opacity(0.85)), in: Capsule())
                .foregroundStyle(store.waiting.isEmpty ? Color.white : Color.black)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Lagrede målinger")
            // Only worth saying when it is missing: then holes and boxes are measured coarser.
            if !model.hasLidar {
                Label("Uten dybdesensor", systemImage: "camera")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding(.top, 4)
    }

    private var dot: Color {
        if model.pairing == nil { return .gray }
        if model.pcOpen == true { return good }
        return model.connectionError == nil ? .yellow : .red
    }

    private var status: String {
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
            // A dark tint under the glass: white text stays readable over a bright white ceiling.
            .background(Color.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
    }
}

struct BottomPanel: View {
    @ObservedObject var model: MeasureModel

    var body: some View {
        VStack(spacing: 8) {
            WaitingBanner(model: model, store: model.store)
            VStack(spacing: 12) {
                ViewThatFits(in: .vertical) {
                    content
                    ScrollView { content }
                }
                // The main buttons sit below the scrolling part: always visible.
                if !model.isCalibrating && !model.mode.isSpace && model.locked {
                    LockedActions(model: model)
                }
            }
            .modifier(GlassPanel())
        }
    }

    @ViewBuilder private var content: some View {
        if model.isCalibrating {
            CalibrationContent(model: model)
        } else if model.mode.isSpace {
            SpaceContent(model: model, space: model.space)
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
        if model.connected && !store.waiting.isEmpty && !model.locked && !model.space.locked {
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
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 8)
                if busy { ProgressView() } else if let label { Text(label).font(.caption.weight(.semibold)).opacity(0.7) }
            }
            if let sure {
                Label(unsure ? "\(sure) – mål gjerne med skyvelære" : sure, systemImage: unsure ? "exclamationmark.triangle.fill" : "scope")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(unsure ? warn : Color.white.opacity(0.75))
            }
        }
    }
}

struct LiveContent: View {
    @ObservedObject var model: MeasureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SizeHeader(text: model.answer?.text ?? model.quick ?? "– mm", sure: model.uncertaintyText, unsure: model.unsure, label: model.answer?.label)
                .foregroundStyle(model.live == nil ? Color.white.opacity(0.45) : Color.white)
            // Right under the number, a fixed two-line slot: the panel no longer jumps as the hint changes.
            Text(model.hint)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(model.live == nil ? Color.white : (model.steadiness > 0.7 ? good : warn))
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
            if !model.details.isEmpty {
                Text(model.details).font(.footnote).foregroundStyle(.secondary)
            }
            SteadyBar(value: model.steadiness)
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
    @State private var control = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SizeHeader(text: model.shape?.text ?? "Tilpasser formen …", sure: model.uncertaintyText, unsure: model.unsure, busy: model.working)
            EdgeChoiceView(model: model)
            HStack(spacing: 8) {
                if let d = model.shape?.diameter, !nearStandard(d).isEmpty {
                    Text("Standard mm:").font(.footnote).foregroundStyle(.secondary).fixedSize()
                    ForEach(nearStandard(d), id: \.self) { s in
                        Button("\(Int(s))") { model.useStandard(s) }
                            .buttonStyle(ChipStyle(on: abs(s - d) < 0.01))
                            .fixedSize()
                            .accessibilityLabel("\(Int(s)) millimeter")
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
                        .frame(minHeight: 44)
                }
            }
            HStack(spacing: 8) {
                ForEach(MakeKind.allCases) { k in
                    ChoiceCard(title: k.short, symbol: k.symbol, on: model.make == k) { model.make = k }
                }
            }
            Text(model.make.hint).font(.footnote).foregroundStyle(.secondary)
            // Everything for fine-tuning in one place: the panel stays short.
            DisclosureGroup(isExpanded: $adjust) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.make.uses) { key in
                        ParamRow(key: key, value: model.params[key] ?? key.defaultValue) { model.setParam(key, $0) }
                    }
                    if let diameter = model.shape?.diameter, model.make == .lokk || model.make == .plugg {
                        let outer = diameter - 2 * (model.params[.clearance] ?? ParamKey.clearance.defaultValue)
                        Text("Hull Ø \(mm(diameter)) → \(model.make == .lokk ? "kragens" : "pluggens") ytre diameter Ø \(mm(outer)) mm")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let depth = model.depthMM {
                        Button {
                            model.useDepth()
                        } label: {
                            Label("Bruk hullets dybde: \(Int(depth.rounded())) mm", systemImage: "arrow.down.to.line")
                                .font(.footnote.weight(.semibold))
                        }
                        .buttonStyle(ChipStyle(on: false))
                    }
                    if model.shape?.diameter != nil {
                        Divider().overlay(Color.white.opacity(0.15))
                        Text("Har du målt selv?").font(.subheadline.weight(.semibold))
                        Text("Skriv hullets innvendige diameter. Gjelder bare dette hullet.")
                            .font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            TextField("Diameter i mm", text: $control)
                                .keyboardType(.decimalPad)
                                .padding(10)
                                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .accessibilityLabel("Hullets innvendige diameter (mm)")
                            Button("Bruk") { model.useControlDiameter(control) }
                                .buttonStyle(ChipStyle(on: false))
                                .disabled(controlDiameter(control) == nil || model.working)
                        }
                        if let d = model.controlDiameterMM {
                            Text("Ditt mål brukes: Ø \(mm(d)) mm. Prøv passformen med en liten prøvebit.")
                                .font(.footnote)
                        }
                    }
                    if let evidence = model.diagnosticsText {
                        ShareLink(item: evidence) { Label("Del måledata", systemImage: "square.and.arrow.up") }
                            .font(.footnote)
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
                Label("Låst automatisk. Feil? Trykk «Mål på nytt».", systemImage: "lock.fill").font(.footnote).foregroundStyle(.secondary)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(bad)
            }
        }
    }
}

/// The buttons under a locked hole – pinned below the panel, so they never scroll away.
struct LockedActions: View {
    @ObservedObject var model: MeasureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.connected && model.shape != nil {
                Label("Lagret på telefonen – sendes når CadSHAPE er åpent", systemImage: "tray.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(good)
            }
            HStack(spacing: 10) {
                if model.done != nil || !model.connected {
                    // Sent (or saved for later): the next step is the next hole. «Lag igjen» stays possible.
                    if model.connected {
                        Button { model.commit() } label: { Label("Lag igjen", systemImage: "cube") }
                            .buttonStyle(SecondaryStyle())
                            .disabled(model.working)
                    } else {
                        Button { model.showSettings = true } label: { Label("Koble til", systemImage: "link") }
                            .buttonStyle(SecondaryStyle())
                    }
                    Button { model.measureAgain() } label: { Label("Mål neste", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(PrimaryStyle())
                } else {
                    Button { model.measureAgain() } label: { Label("Mål på nytt", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(SecondaryStyle())
                    Button { model.commit() } label: { Label("Lag i CadSHAPE", systemImage: "cube.fill") }
                        .buttonStyle(PrimaryStyle(enabled: canMake))
                        .disabled(!canMake)
                }
            }
        }
    }

    private var canMake: Bool { model.connected && model.shape != nil && !model.working }
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
                    Text(problem).font(.footnote).foregroundStyle(bad)
                }
                if !model.connected && !store.waiting.isEmpty {
                    Label("Ikke koblet til – sendes når CadSHAPE er åpent", systemImage: "wifi.slash")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if model.connected && store.waiting.count > 1 {
                    Button { store.waiting.forEach(send) } label: {
                        Label("Send alle \(store.waiting.count) som venter", systemImage: "tray.and.arrow.up.fill")
                    }
                }
                ForEach(store.items) { m in
                    HStack(spacing: 12) {
                        Group {
                            if let img = store.image(m) {
                                Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Image(systemName: m.symbol).font(.title2).foregroundStyle(.secondary)
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
            .overlay {
                if store.items.isEmpty {
                    ContentUnavailableView("Ingen målinger ennå", systemImage: "tray",
                        description: Text("Alt du låser havner her, også uten tilkobling."))
                }
            }
            .navigationTitle("Målinger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ferdig") { model.showSaved = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func subtitle(_ m: SavedMeasurement) -> String {
        var parts = [m.date.formatted(date: .abbreviated, time: .shortened)]
        if let make = m.makeLabel { parts.append(make) }
        if let d = m.controlDiameterMM { parts.append("kontrollmål Ø \(mm(d)) mm") }
        else if let u = m.uncertainty { parts.append("anslått ± \(mm(u)) mm") }
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
            Text("Sikt på QR-koden i CadSHAPE på PC-en (Fil → «Mål med telefonen»). Eller logg inn på nett.")
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
    /// From the home screen: «Skann QR-koden» opens the camera screen (nil = this screen has the camera).
    var onScanQR: (() -> Void)? = nil
    @State private var link = ""
    @State private var badLink = false
    @State private var web = "kloki.no/cadshape"
    @State private var password = ""
    @State private var loggingIn = false
    @State private var loginError: String?
    @Environment(\.dismiss) private var dismiss
    /// One for the app: the sheet's view is rebuilt often, and each URLSession would live on.
    private static let login = WebLogin()
    /// Where there is no camera route (the 3D scan), «Skann QR-koden» is left out.
    private let allowQR: Bool

    init(model: MeasureModel, allowQR: Bool = true, onScanQR: (() -> Void)? = nil) {
        self.model = model
        self.allowQR = allowQR
        self.onScanQR = onScanQR
    }

    private func close() {
        model.showSettings = false
        model.showConnect = false
        dismiss()
    }

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
                        Self.login.login(base: base, password: password) { r in
                            loggingIn = false
                            switch r {
                            case .success(let session):
                                password = ""
                                model.loggedIn(base: base, session: session)
                                close()
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
                        Text(loginError).font(.footnote).foregroundStyle(bad)
                    }
                } header: {
                    Text("CadSHAPE på nett")
                } footer: {
                    Text("Virker hvor som helst med nett, uten .bat-fil og QR-kode. Passordet lagres ikke; innloggingen huskes i 90 dager. Delene lages i CadSHAPE som er åpent i en nettleser.")
                }
                Section {
                    if allowQR {
                        Button {
                            if let onScanQR {
                                onScanQR()
                            } else {
                                model.showSettings = false
                                model.wantsPairing = true
                            }
                        } label: {
                            Label("Skann QR-koden", systemImage: "qrcode.viewfinder")
                        }
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
                        Text("Lenken må være den fra QR-koden i CadSHAPE (med ?k=…).").font(.footnote).foregroundStyle(bad)
                    }
                } header: {
                    Text("PC-en på samme wifi")
                }
                // Calibrating needs the measuring camera: only offered from that screen.
                if onScanQR == nil {
                    CalibrationSection(model: model)
                }
                Section {
                    Toggle("Lås av seg selv når målet er stødig", isOn: $model.autoLock)
                } header: {
                    Text("Måling")
                } footer: {
                    Text("Låser bare når målet er stødig og skarpt nok. Er kanten grov, låser du selv – mål med skyvelære før deler som skal sitte stramt.")
                }
                Section {
                    // Numbers, hints and errors of the last minutes – no pictures or passwords.
                    ShareLink(item: model.problemReport(), subject: Text("CadSHAPE Mål – problem"),
                              message: Text("Hva skjedde, og hva forventet du?")) {
                        Label("Rapporter problem", systemImage: "exclamationmark.bubble")
                    }
                } footer: {
                    Text("Lager en tekst med appens siste hendelser og målinger (ingen bilder eller passord) som du kan sende.")
                }
                Section {
                    // The long explanation on its own page: the sheet stays short.
                    NavigationLink("Slik måler appen") { HowItMeasures() }
                    Text(appVersionText).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("CadSHAPE Mål")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ferdig") { close() }
                }
            }
        }
        .onAppear { if let s = model.webSuggestion { web = s } }
        .preferredColorScheme(.dark)
    }
}

/// «Slik måler appen»: what the numbers rest on, and how to get good ones.
struct HowItMeasures: View {
    var body: some View {
        Form {
            Section {
                    Text("Kanten på hullet finnes i kamerabildet (eller i LiDAR-dybden når hullet ikke skiller seg ut). LiDAR måler flaten rundt hullet – avstand og vinkel – og kanten legges ned på flaten i millimeter. Anslått avvik tar med variasjon, pikseloppløsning og flaten. Det er ikke en kalibrert garanti for passform. Bruk kontrollmål for små, trange hull. LiDAR kan også anslå dybden.")
                        .font(.footnote)
                    Text("Best resultat: 30–80 cm unna, mest mulig rett på, godt lys og hele kanten i bildet.")
                        .font(.footnote)
                    Text("Ser appen to kanter rundt hullet (skygge, fas eller hullets innside), låser den ikke av seg selv – du velger kanten etter låsing.")
                        .font(.footnote)
                    Text("Inni boks bruker LiDAR-punktene fra flere bilder samlet: bunnen, de fire veggene og kanten øverst. Hold telefonen 25–60 cm over, rett ned. Tomme bokser gir best mål; svarte og blanke flater ser LiDAR dårlig.")
                        .font(.footnote)
                    Text("3D-skann («Skann ting») gir formen med noen millimeters nøyaktighet – godt nok til holdere og lommer, ikke til stramme passformer. Mål hull og kanter som må passe med Hull-modus.")
                        .font(.footnote)
            }
        }
        .navigationTitle("Slik måler appen")
        .navigationBarTitleDisplayMode(.inline)
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
            .padding(.vertical, 8)
            .background(on ? accent : Color.white.opacity(configuration.isPressed ? 0.25 : 0.14), in: Capsule())
            .foregroundStyle(on ? Color.black : Color.white)
            // The chip looks small; the finger gets 44 pt.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

struct RoundStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .frame(width: 38, height: 38)
            .background(Color.white.opacity(configuration.isPressed ? 0.28 : 0.14), in: Circle())
            .foregroundStyle(Color.white)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }
}
