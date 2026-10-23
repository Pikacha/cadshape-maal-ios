import HoleKit
import SwiftUI
import UIKit

let accent = Color(red: 0.95, green: 0.66, blue: 0.23)
let good = Color(red: 0.36, green: 0.85, blue: 0.55)

struct ContentView: View {
    @StateObject private var model = MeasureModel()

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
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
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
            if !model.locked {
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
        guard let p = model.pairing else { return "Ikke koblet til PC" }
        if model.pcOpen == true { return "CadSHAPE · \(p.hostLabel)" }
        if model.pcOpen == false { return "CadSHAPE er ikke åpent" }
        return model.connectionError == nil ? "Kobler til \(p.hostLabel) …" : "PC-en svarer ikke"
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
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
        .modifier(GlassPanel())
    }

    @ViewBuilder private var content: some View {
        if model.locked {
            LockedContent(model: model)
        } else {
            LiveContent(model: model)
        }
    }
}

struct LiveContent: View {
    @ObservedObject var model: MeasureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.answer?.text ?? model.quick ?? "Sikt på hullet")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 8)
                if let label = model.answer?.label {
                    Text(label).font(.caption.weight(.semibold)).opacity(0.7)
                }
            }
            if !model.details.isEmpty {
                Text(model.details).font(.footnote).opacity(0.75)
            }
            SteadyBar(value: model.steadiness)
            Text(model.hint).font(.subheadline.weight(.medium)).foregroundStyle(model.steadiness > 0.7 ? good : accent)
            Picker("Form", selection: $model.forcedKind) {
                Text("Auto").tag(ShapeKind?.none)
                ForEach(ShapeKind.allCases) { k in
                    Text(k.short).tag(ShapeKind?.some(k))
                }
            }
            .pickerStyle(.segmented)
            Button {
                model.lock()
            } label: {
                Label("Lås målet", systemImage: "lock.fill")
            }
            .buttonStyle(PrimaryStyle(enabled: model.canLock))
            .disabled(!model.canLock)
        }
    }
}

struct LockedContent: View {
    @ObservedObject var model: MeasureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.shape?.text ?? "Tilpasser formen …")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 8)
                if model.working { ProgressView() }
            }
            if let d = model.shape?.diameter, !nearStandard(d).isEmpty {
                HStack(spacing: 8) {
                    Text("Standard:").font(.footnote).opacity(0.75)
                    ForEach(nearStandard(d), id: \.self) { s in
                        Button("\(Int(s)) mm") { model.useStandard(s) }
                            .buttonStyle(ChipStyle(on: abs(s - d) < 0.01))
                    }
                }
            }
            Picker("Form", selection: $model.forcedKind) {
                Text("Auto").tag(ShapeKind?.none)
                ForEach(ShapeKind.allCases) { k in
                    Text(k.short).tag(ShapeKind?.some(k))
                }
            }
            .pickerStyle(.segmented)
            Picker("Lag", selection: $model.make) {
                ForEach(MakeKind.allCases) { k in
                    Text(k.short).tag(k)
                }
            }
            .pickerStyle(.segmented)
            Text(model.make.hint).font(.footnote).opacity(0.75)
            ForEach(model.make.uses) { key in
                ParamRow(key: key, value: model.params[key] ?? key.defaultValue) { model.setParam(key, $0) }
            }
            if let done = model.done {
                Label(done, systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(good)
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
                    Label("Lag i CadSHAPE", systemImage: "cube.fill")
                }
                .buttonStyle(PrimaryStyle(enabled: canMake))
                .disabled(!canMake)
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

// MARK: Connecting

struct PairingCard: View {
    @ObservedObject var model: MeasureModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "qrcode.viewfinder").font(.system(size: 36)).foregroundStyle(accent)
            Text("Koble til CadSHAPE").font(.title3.bold())
            Text("Start CadSHAPE med START_CADSHAPE_MOBIL.bat. På PC-en: Fil → «Mål med telefonen / åpne på mobil». Sikt kameraet på QR-koden – telefonen kobler seg til av seg selv.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .opacity(0.8)
            HStack(spacing: 10) {
                Button("Lim inn lenke") { model.showSettings = true }
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

    var body: some View {
        NavigationStack {
            Form {
                Section("PC-en") {
                    if let p = model.pairing {
                        LabeledContent("Adresse", value: p.base.absoluteString)
                        LabeledContent("CadSHAPE", value: model.pcOpen == true ? "åpent" : (model.pcOpen == false ? "ikke åpent" : "ingen kontakt"))
                        if let e = model.connectionError {
                            Text(e).font(.footnote).foregroundStyle(accent)
                        }
                    } else {
                        Text("Ikke koblet til en PC ennå.")
                    }
                    Button {
                        model.showSettings = false
                        model.wantsPairing = true
                    } label: {
                        Label("Skann QR-koden", systemImage: "qrcode.viewfinder")
                    }
                    if model.pairing != nil {
                        Button("Sjekk tilkoblingen") { model.checkPc() }
                        Button("Glem denne PC-en", role: .destructive) { model.forget() }
                    }
                }
                Section {
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
                    Text("Eller lim inn lenken")
                }
                Section("Slik måler appen") {
                    Text("Kanten på hullet finnes i kamerabildet (eller i LiDAR-dybden når hullet ikke skiller seg ut). LiDAR måler flaten rundt hullet – avstand og vinkel – og kanten legges ned på flaten i millimeter. Formen (rund, firkantet eller fri) tilpasses av CadSHAPE på PC-en, med samme kode som nettsiden.")
                        .font(.footnote)
                    Text("Best resultat: 30–80 cm unna, mest mulig rett på, godt lys og hele kanten i bildet. Hold stille til streken blir grønn.")
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
