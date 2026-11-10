import HoleKit
import SwiftUI
import UIKit

// MARK: Bottom

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
