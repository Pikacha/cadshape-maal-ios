import Foundation
import HoleKit
import ModelIO
import RealityKit
import SceneKit
import SwiftUI

/// Which part the caliper sheet opens on.
struct CaliperPick: Identifiable {
    let index: Int
    var id: Int { index }
}

struct CaptureScreen: View {
    @StateObject private var cap: CaptureModel
    @ObservedObject private var model: MeasureModel
    @State private var confirmClose = false
    @State private var connect = false
    @State private var drawSide: DrawingSide = .side
    @State private var showModel = false
    @State private var caliperPart: Int?
    let close: () -> Void

    init(model: MeasureModel, close: @escaping () -> Void) {
        self.close = close
        self.model = model
        _cap = StateObject(wrappedValue: CaptureModel(api: model.api))
    }

    var body: some View {
        ZStack {
            if let session = cap.session {
                if cap.passDone && cap.step == .capturing {
                    // Between rounds: what has been covered so far (Apple's point cloud, turnable).
                    ObjectCapturePointCloudView(session: session).ignoresSafeArea()
                } else {
                    ObjectCaptureView(session: session).ignoresSafeArea()
                }
            } else {
                ground.ignoresSafeArea()
            }
            if cap.step == .done {
                result
            } else {
            VStack(spacing: 10) {
                HStack(alignment: .top) {
                    CloseButton(label: "Avbryt skanningen") {
                        // Pictures or a model that has not been sent would be lost: ask first.
                        if cap.shots > 0 && cap.sent == nil { confirmClose = true } else { leave() }
                    }
                    Spacer()
                    if cap.step == .capturing {
                        Text("Runde \(cap.passes)/\(CaptureModel.goodRounds) · \(cap.roundShots) bilder")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                Spacer()
                panel
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            }
        }
        .foregroundStyle(.white)
        .confirmationDialog("Avbryte skanningen?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Avbryt og slett bildene", role: .destructive) { leave() }
            Button("Fortsett", role: .cancel) {}
        } message: {
            Text("Bildene og modellen er ikke sendt, og blir slettet.")
        }
        // Its own sheet: the home screen's «Koble til» sheet sits under this full-screen cover.
        .sheet(isPresented: $connect) {
            SettingsSheet(model: model, allowQR: false) { connect = false }
        }
        .onAppear {
            cap.start()
            // Walking round the thing and building the model take minutes: the screen must not lock.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        // The photos (often several hundred MB) and the model go with the screen.
        .onDisappear {
            cap.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func leave() {
        cap.cancel()
        close()
    }

    @ViewBuilder private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            // While walking round only the ring and one line: the camera must be visible.
            if cap.step != .unsupported && cap.step != .capturing {
                ScanSteps(current: stepIndex)
            }
            switch cap.step {
            case .unsupported:
                Text("Denne telefonen kan ikke 3D-skanne").font(.headline)
                Text("3D-skanning krever en iPhone med LiDAR (Pro-modell) og iOS 17.").font(.subheadline).foregroundStyle(.secondary)
            case .starting:
                HStack { ProgressView(); Text("Starter kameraet …") }
            case .ready:
                Text("Legg tingen på et bord med plass rundt").font(.headline)
                Text("Matt underlag og jevnt lys gir best modell. Sikt på tingen. Skannet gir formen med noen millimeters nøyaktighet.").font(.subheadline).foregroundStyle(.secondary)
                Button("Finn tingen") { cap.detect() }.buttonStyle(PrimaryStyle())
            case .detecting:
                Text("Juster boksen rundt tingen").font(.headline)
                Text("Dra i hjørnene til boksen så vidt rommer den.").font(.subheadline).foregroundStyle(.secondary)
                Button("Start skanningen") { cap.capture() }.buttonStyle(PrimaryStyle())
            case .capturing:
                rounds
                if cap.passDone {
                    Text("Runde \(cap.passes) av \(CaptureModel.goodRounds) er ferdig").font(.headline)
                    Text(nextRoundText).font(.subheadline).foregroundStyle(.secondary)
                    if cap.passes < CaptureModel.goodRounds {
                        Button("Neste runde") { cap.newPass() }.buttonStyle(PrimaryStyle())
                        HStack(spacing: 8) {
                            Button("Lag modellen nå") { cap.finish() }.buttonStyle(SecondaryStyle())
                            Button("Snu tingen") { cap.flip() }.buttonStyle(SecondaryStyle())
                        }
                    } else {
                        Button("Lag modellen") { cap.finish() }.buttonStyle(PrimaryStyle())
                        Button("En runde til") { cap.newPass() }.buttonStyle(SecondaryStyle())
                    }
                } else {
                    Text(roundTitle).font(.headline)
                    message
                    HStack(spacing: 8) {
                        if cap.canShoot {
                            Button("Ta bilde") { cap.shoot() }.buttonStyle(SecondaryStyle())
                        }
                        if cap.shots >= 20 {
                            Button("Lag modellen nå") { cap.finish() }.buttonStyle(SecondaryStyle())
                        }
                    }
                    if cap.stalled && cap.shots < 20 {
                        Button("Start kameraet på nytt") { cap.again() }.buttonStyle(SecondaryStyle())
                    }
                }
            case .finishing:
                HStack { ProgressView(); Text("Lagrer bildene …") }
            case .reconstructing(let f):
                Text("Lager 3D-modellen på telefonen").font(.headline)
                if f < 0.01 {
                    ProgressView().tint(accent).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView(value: f).tint(accent)
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("\(Int(f * 100)) % · \(cap.elapsedText) · vanligvis 1–3 min. Ikke lukk appen.")
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
            case .done:
                EmptyView()
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(bad)
                Button("Prøv igjen") { cap.again() }.buttonStyle(PrimaryStyle())
            }
            if cap.session != nil, cap.step != .capturing, let line = cap.error ?? cap.trackingHint {
                Label(line, systemImage: cap.error != nil ? "exclamationmark.circle" : "camera.metering.unknown")
                    .font(.subheadline)
                    .foregroundStyle(cap.error != nil ? bad : .white)
                    .lineLimit(3)
            }
        }
        .modifier(GlassPanel())
    }

    /// One message while walking round: error > no progress > camera advice > the instruction.
    @ViewBuilder private var message: some View {
        if let e = cap.error {
            Label(e, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(bad).lineLimit(3)
        } else if cap.stalled {
            Label("Ingen nye bilder. Gå videre rundt tingen og hold den midt i bildet\(cap.canShoot ? ", eller trykk «Ta bilde»" : "").",
                  systemImage: "pause.circle").font(.subheadline).foregroundStyle(warn).lineLimit(3)
        } else if let hint = cap.trackingHint {
            Label(hint, systemImage: "camera.metering.unknown").font(.subheadline).lineLimit(3)
        } else {
            Text("Gå sakte rundt tingen. Runden er ferdig når ringen på bakken er full.").font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
        }
    }

    private var stepIndex: Int {
        switch cap.step {
        case .unsupported, .starting, .ready, .detecting: return 0
        case .capturing: return 1
        case .finishing, .reconstructing: return 2
        case .done: return cap.sent == nil ? 3 : 4
        case .failed: return cap.mesh == nil ? 1 : 3
        }
    }

    /// The three rounds: the current one fills as pictures come in (a round is ~30–50 pictures).
    private var rounds: some View {
        HStack(spacing: 6) {
            ForEach(1...max(CaptureModel.goodRounds, cap.passes), id: \.self) { r in
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(accent).frame(width: g.size.width * fill(r))
                    }
                }
                .frame(height: 6)
            }
        }
        .animation(.easeOut(duration: 0.3), value: cap.shots)
        .accessibilityElement()
        .accessibilityLabel("Runde \(cap.passes) av \(CaptureModel.goodRounds), \(cap.roundShots) bilder")
    }

    private func fill(_ round: Int) -> Double {
        if round < cap.passes { return 1 }
        if round > cap.passes { return 0 }
        return cap.passDone ? 1 : min(0.9, Double(cap.roundShots) / 40)
    }

    private var roundTitle: String {
        switch cap.passes {
        case 1: return "Runde 1: rundt tingen, litt ovenfra"
        case 2: return "Runde 2: rundt tingen, i høyde med den"
        default: return "Runde \(cap.passes): lavt rundt tingen"
        }
    }

    private var nextRoundText: String {
        switch cap.passes {
        case 1: return "Neste: en runde i høyde med tingen. «Snu tingen» bare hvis bunnen må med. Bildet bak viser hva som er skannet."
        case 2: return "Neste: en lav runde. Tre runder gir klart best modell."
        default: return "Tingen er sett fra alle kanter. Modellen lages på telefonen (1–3 min)."
        }
    }

    /// «Formen med mål»: the shape as a drawing with dimensions first, the 3D scan only on request.
    private var result: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    CloseButton(label: "Lukk") {
                        if cap.sent == nil { confirmClose = true } else { leave() }
                    }
                    Spacer()
                    Picker("Visning", selection: $drawSide) {
                        ForEach(DrawingSide.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    .disabled(showModel)
                }
                Group {
                    if let s = cap.shapes, !s.parts.isEmpty, !showModel {
                        ShapeDrawing(shapes: s, side: drawSide)
                    } else if let url = cap.modelURL {
                        ModelPreview(url: url)
                    } else {
                        Color.clear
                    }
                }
                .frame(height: 330)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                HStack {
                    Text("Ytre mål \(cap.sizeText)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    if cap.modelURL != nil, let s = cap.shapes, !s.parts.isEmpty {
                        Button(showModel ? "Vis formen" : "Vis 3D-skannet") { showModel.toggle() }
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                }
                if let note = cap.caliperNote {
                    HStack {
                        Label(note, systemImage: "ruler").font(.subheadline)
                        Spacer()
                        Button("Angre") { cap.undoCorrection() }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    }
                } else if cap.scaleSource == .phone {
                    Label(cap.scaleSource.label, systemImage: "iphone").font(.subheadline).foregroundStyle(.secondary)
                }
                if let s = cap.shapes, !s.parts.isEmpty {
                    PartRows(shapes: s, scale: cap.scaleSource, onTap: cap.sent == nil ? { caliperPart = $0 } : nil)
                } else {
                    Text("Fant ingen enkle former – CadSHAPE får skannet som det er, og du kan lage en holder rundt det.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                done
            }
            .padding(16)
        }
        .background(ground.ignoresSafeArea())
        .sheet(item: Binding(get: { caliperPart.map { CaliperPick(index: $0) } }, set: { caliperPart = $0?.index })) { pick in
            if let s = cap.shapes {
                CaliperSheet(shapes: s, start: pick.index) { i, m, v, learn in
                    cap.correct(part: i, measure: m, truth: v, learn: learn)
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    @ViewBuilder private var done: some View {
        // On the phone Apple builds models at reduced detail; the size is the phone's tracking until corrected.
        if cap.scaleSource != .measured {
            Label("Hull og kanter som skal sitte stramt: rett størrelsen etter skyvelæren først, eller mål dem med «Hull».",
                  systemImage: "ruler")
                .font(.footnote).foregroundStyle(warn)
        }
        if let sent = cap.sent {
            Label(sent, systemImage: "checkmark.circle.fill").foregroundStyle(good).font(.headline)
            ForEach(cap.notes, id: \.self) { n in
                Label(n, systemImage: "books.vertical").font(.subheadline)
            }
            Button("Ferdig") { leave() }.buttonStyle(PrimaryStyle())
            Button("Skann en til") { cap.again() }.buttonStyle(SecondaryStyle())
        } else {
            TextField("Navn", text: $cap.name)
                .padding(12)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Picker("Hva lager vi?", selection: $cap.make) {
                Text("Deler med mål").tag("cad")
                Text("Holder rundt").tag("holder")
                Text("Bare skannet").tag("none")
            }
            .pickerStyle(.segmented)
            if let e = cap.error {
                Label(e, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(bad)
            }
            if !model.connected {
                HStack {
                    Label("Ikke koblet til CadSHAPE", systemImage: "wifi.slash").font(.subheadline)
                    Spacer()
                    Button("Koble til") { connect = true }.buttonStyle(ChipStyle())
                }
            }
            Button {
                cap.send()
            } label: {
                Label(cap.sending ? "Sender …" : "Send til CadSHAPE", systemImage: "paperplane.fill")
            }
            .buttonStyle(PrimaryStyle())
            .disabled(cap.sending || cap.api == nil)
            Button("Skann på nytt") { cap.again() }.buttonStyle(SecondaryStyle())
        }
    }
}

/// Finn · Skann · Lag modell · Send: where in the whole 3D scan we are.
struct ScanSteps: View {
    let current: Int
    private let names = ["Finn", "Skann", "Lag modell", "Send"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(names.indices, id: \.self) { i in
                HStack(spacing: 4) {
                    Image(systemName: i < current ? "checkmark.circle.fill" : (i == current ? "circle.inset.filled" : "circle"))
                        .foregroundStyle(i <= current ? accent : Color.white.opacity(0.35))
                    Text(names[i])
                        .foregroundStyle(i == current ? .white : .secondary)
                }
                if i < names.count - 1 {
                    Rectangle().fill(Color.white.opacity(0.2)).frame(height: 1)
                }
            }
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Steg \(min(current + 1, names.count)) av \(names.count): \(names[min(current, names.count - 1)])")
    }
}
