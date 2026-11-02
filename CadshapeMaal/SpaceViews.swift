import HoleKit
import SwiftUI

// The bottom panel for «Inni boks»: live sizes while measuring, then what to make, with a drawing
// of the inside seen from above.

struct SpaceContent: View {
    @ObservedObject var model: MeasureModel
    @ObservedObject var space: SpaceModel

    var body: some View {
        if space.locked {
            BoxLockedContent(model: model, space: space)
        } else {
            SpaceLiveContent(model: model, space: space)
        }
    }
}

struct SpaceLiveContent: View {
    @ObservedObject var model: MeasureModel
    @ObservedObject var space: SpaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SizeHeader(text: sizeText, sure: space.box.map { "± \(mm($0.spread)) mm" }, unsure: false, label: "innvendig")
            if let b = space.box {
                WallsSeen(seen: b.seen, wall: b.wall)
            }
            SteadyBar(value: space.steadiness)
            Text(space.hint).font(.subheadline.weight(.semibold)).foregroundStyle(space.steadiness > 0.7 ? good : warn)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
            if let advice = space.advice {
                Label(advice, systemImage: "info.circle").font(.footnote).foregroundStyle(warn).lineLimit(2)
            }
            HStack(spacing: 10) {
                Button {
                    space.typeIn()
                } label: {
                    Label("Skriv inn", systemImage: "keyboard")
                }
                .buttonStyle(SecondaryStyle())
                Button {
                    space.lock()
                } label: {
                    Label(model.autoLock ? "Lås nå" : "Lås målet", systemImage: "lock.fill")
                }
                .buttonStyle(PrimaryStyle(enabled: space.canLock))
                .disabled(!space.canLock)
            }
        }
    }

    private var sizeText: String {
        guard let b = space.box else { return "Sikt på bunnen" }
        // ± 20 mm is not a measure: say so instead of showing numbers that look exact.
        if b.spread > max(3, 0.08 * min(b.width, b.length)) { return "Ser ikke boksen ennå" }
        return "\(mm(b.width, digits: 0)) × \(mm(b.length, digits: 0))" + (b.height.map { " × \(mm($0, digits: 0))" } ?? "") + " mm"
    }
}

/// Four small marks: which walls the LiDAR sees.
struct WallsSeen: View {
    let seen: [Bool]
    let wall: Double?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<seen.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2).fill(seen[i] ? good : Color.white.opacity(0.25)).frame(width: 18, height: 6)
            }
            Text(seen.allSatisfy { $0 } ? "alle fire vegger" : "\(seen.filter { $0 }.count) av 4 vegger").font(.caption).opacity(0.75)
            if let wall { Text("· vegg \(mm(wall)) mm").font(.caption).opacity(0.75) }
        }
    }
}

// MARK: The inside of a box

private enum DimField: Hashable { case width, length, height }

struct BoxLockedContent: View {
    @ObservedObject var model: MeasureModel
    @ObservedObject var space: SpaceModel
    @State private var adjust = false
    @FocusState private var focus: DimField?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SizeHeader(text: SpaceModel.text(space.boxOut).replacingOccurrences(of: "Boks ", with: ""), sure: space.spread.map { "± \(mm($0)) mm" }, unsure: (space.spread ?? 0) > 4, label: space.manual ? "skrevet inn" : "innvendig", busy: space.working)
            if space.manual || adjust {
                VStack(spacing: 6) {
                    DimRow(label: "Bredde", value: space.boxOut.width, focus: $focus, field: .width) { space.setBox(width: $0) }
                    DimRow(label: "Lengde", value: space.boxOut.length, focus: $focus, field: .length) { space.setBox(length: $0) }
                    DimRow(label: "Høyde", value: space.boxOut.height, focus: $focus, field: .height) { space.setBox(height: $0) }
                    if focus != nil {
                        Button("Ferdig") { focus = nil }
                            .buttonStyle(ChipStyle(on: true))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            Picker("Lag", selection: Binding(get: { space.boxMake }, set: { space.setBoxMake($0) })) {
                ForEach(BoxMake.offered) { k in
                    Text(k.choice).tag(k)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
            if space.boxMake.hasRooms {
                VStack(spacing: 4) {
                    RoomStepper(param: .cols, value: space.values[.cols] ?? SpaceParam.cols.defaultValue) { space.setValue(.cols, $0) }
                    RoomStepper(param: .rows, value: space.values[.rows] ?? SpaceParam.rows.defaultValue) { space.setValue(.rows, $0) }
                }
            }
            if space.boxMake == .gridfinity {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bokser som fyller skuffen").font(.subheadline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(0..<binSizes.count, id: \.self) { i in
                                Button(binSizes[i].x == 0 ? "Ingen" : "\(binSizes[i].x)×\(binSizes[i].y)") { space.setBins(i) }
                                    .buttonStyle(ChipStyle(on: space.bins == i))
                            }
                        }
                    }
                }
            }
            BoxSketch(box: space.boxOut, make: space.boxMake, cols: Int(space.values[.cols] ?? 3), rows: Int(space.values[.rows] ?? 2), clearance: space.values[.clearance] ?? 0.5)
                .frame(height: 150)
            Text(space.boxMake.hint).font(.footnote).opacity(0.75)
            DisclosureGroup(isExpanded: $adjust) {
                VStack(spacing: 8) {
                    ForEach(space.boxMake.uses.filter { !$0.isCount }) { p in
                        SpaceParamRow(param: p, value: space.values[p] ?? p.defaultValue, auto: p == .height ? space.autoHeight : nil) { space.setValue(p, $0) }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text(space.manual ? "Mer" : "Juster mål").font(.subheadline.weight(.semibold))
            }
            .tint(.white)
            SpaceStatus(space: space)
            SpaceButtons(model: model, space: space, again: space.manual ? "Mål med LiDAR" : "Mål på nytt")
        }
    }
}

/// Number of rooms one way: big − and + (44 pt), the count in the middle.
struct RoomStepper: View {
    let param: SpaceParam
    let value: Double
    let change: (Double) -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(param.label).font(.subheadline.weight(.semibold))
                Text(param == .cols ? "rom i bredden" : "rom i lengden").font(.caption).opacity(0.65)
            }
            Spacer(minLength: 4)
            Button { change(value - 1) } label: { Image(systemName: "minus") }
                .buttonStyle(RoundStyle())
                .disabled(value <= param.range.lowerBound)
                .accessibilityLabel("Færre rom \(param.label.lowercased())")
            Text("\(Int(value))")
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .frame(minWidth: 36)
            Button { change(value + 1) } label: { Image(systemName: "plus") }
                .buttonStyle(RoundStyle())
                .disabled(value >= param.range.upperBound)
                .accessibilityLabel("Flere rom \(param.label.lowercased())")
        }
        .accessibilityElement(children: .contain)
    }
}

/// A size you can type or nudge.
private struct DimRow: View {
    let label: String
    let value: Double
    var focus: FocusState<DimField?>.Binding
    let field: DimField
    var unit = "mm"
    var step = 0.5
    let change: (Double) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.subheadline)
            Spacer(minLength: 4)
            Button { change(value - step) } label: { Image(systemName: "minus") }
                .buttonStyle(RoundStyle())
            TextField("", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(width: 64)
                .focused(focus, equals: field)
                .onChange(of: text) { t in
                    if let v = Double(t.replacingOccurrences(of: ",", with: ".")), v >= 0, abs(v - value) > 0.001 { change(v) }
                }
            Text(unit).font(.subheadline).opacity(0.7)
            Button { change(value + step) } label: { Image(systemName: "plus") }
                .buttonStyle(RoundStyle())
        }
        .onAppear { text = mm(value) }
        .onChange(of: value) { v in
            if focus.wrappedValue != field { text = mm(v) }
        }
    }
}

struct SpaceParamRow: View {
    let param: SpaceParam
    let value: Double
    /// What «auto» comes out as (shown with it).
    let auto: Double?
    let change: (Double) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(param.label).font(.subheadline)
            Spacer(minLength: 4)
            Button { change(value - param.step) } label: { Image(systemName: "minus") }
                .buttonStyle(RoundStyle())
            Text(valueText)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minWidth: 76)
            Button { change(value + param.step) } label: { Image(systemName: "plus") }
                .buttonStyle(RoundStyle())
        }
    }

    private var valueText: String {
        if param.isCount { return "\(Int(value))" }
        if value == 0, let z = param.zeroText { return auto.map { "\(z) \(mm($0, digits: 0))" } ?? z }
        return mm(value, digits: param.step < 1 ? 1 : 0) + " mm"
    }
}

/// The box from above: its inside and what will go in it.
struct BoxSketch: View {
    let box: BoxOut
    let make: BoxMake
    let cols: Int
    let rows: Int
    let clearance: Double

    var body: some View {
        Canvas { ctx, size in
            let pad = 18.0
            let outer = make == .lid ? (box.wall ?? 2) : 0
            let W = box.width + 2 * outer, L = box.length + 2 * outer
            let sw = Double(size.width), sh = Double(size.height)
            let k = min((sw - 2 * pad) / W, (sh - 2 * pad) / L)
            let cx = sw / 2, cy = sh / 2
            func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: cx + x * k, y: cy - y * k) }
            func rect(_ w: Double, _ l: Double, _ x: Double = 0, _ y: Double = 0) -> CGRect {
                CGRect(x: cx + (x - w / 2) * k, y: cy - (y + l / 2) * k, width: w * k, height: l * k)
            }
            let inside = rect(box.width, box.length)
            ctx.fill(Path(roundedRect: inside, cornerRadius: 3), with: .color(.white.opacity(0.06)))
            ctx.stroke(Path(roundedRect: inside, cornerRadius: 3), with: .color(.white.opacity(0.55)), lineWidth: 1.5)
            let W2 = box.width - 2 * clearance, L2 = box.length - 2 * clearance
            switch make {
            case .dividers, .grid, .insert:
                var p = Path()
                if make != .dividers { p.addRect(rect(W2, L2)) }
                for i in 1..<max(1, cols) {
                    let x = -W2 / 2 + Double(i) * W2 / Double(cols)
                    p.move(to: pt(x, -L2 / 2))
                    p.addLine(to: pt(x, L2 / 2))
                }
                for j in 1..<max(1, rows) {
                    let y = -L2 / 2 + Double(j) * L2 / Double(rows)
                    p.move(to: pt(-W2 / 2, y))
                    p.addLine(to: pt(W2 / 2, y))
                }
                ctx.stroke(p, with: .color(accent), lineWidth: 2.5)
            case .gridfinity:
                let ux = Int((W2 + 1e-6) / 42), uy = Int((L2 + 1e-6) / 42)
                ctx.fill(Path(rect(W2, L2)), with: .color(accent.opacity(0.25)))
                for i in 0..<max(0, ux) {
                    for j in 0..<max(0, uy) {
                        let x = (Double(i) - Double(ux - 1) / 2) * 42
                        let y = (Double(j) - Double(uy - 1) / 2) * 42
                        ctx.fill(Path(roundedRect: rect(36, 36, x, y), cornerRadius: 2), with: .color(.black.opacity(0.55)))
                    }
                }
                if ux < 1 || uy < 1 {
                    ctx.draw(Text("For liten for Gridfinity").font(.caption.weight(.semibold)).foregroundColor(accent), at: CGPoint(x: cx, y: cy))
                }
            case .lid:
                let r = rect(W, L)
                ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(accent.opacity(0.3)))
                ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(accent), lineWidth: 2)
                ctx.stroke(Path(rect(W2, L2)), with: .color(accent), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            let font = Font.caption2.weight(.semibold)
            ctx.draw(Text("\(mm(box.width, digits: 0)) mm").font(font).foregroundColor(.white.opacity(0.8)), at: CGPoint(x: Double(inside.midX), y: Double(inside.maxY) + 9))
            ctx.draw(Text("\(mm(box.length, digits: 0))").font(font).foregroundColor(.white.opacity(0.8)), at: CGPoint(x: Double(inside.minX) - 12, y: cy))
        }
        .accessibilityLabel("Boksen sett ovenfra, \(mm(box.width, digits: 0)) × \(mm(box.length, digits: 0)) mm innvendig, \(cols) × \(rows) rom")
    }
}

// MARK: Shared

struct SpaceStatus: View {
    @ObservedObject var space: SpaceModel

    var body: some View {
        if let done = space.done {
            Label(done, systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(good)
            ForEach(space.notes, id: \.self) { n in
                Text(n).font(.footnote).opacity(0.8)
            }
        }
        if let error = space.error {
            Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(bad)
        }
    }
}

struct SpaceButtons: View {
    @ObservedObject var model: MeasureModel
    @ObservedObject var space: SpaceModel
    let again: String

    var body: some View {
        CommitButtons(connected: model.connected, done: space.done != nil, working: space.working,
                      again: again, measureAgain: space.measureAgain, commit: space.commit,
                      connect: { model.showSettings = true })
    }
}

/// «Mål på nytt / Lag i CadSHAPE» – and what they become when it was sent (Mål neste) or when
/// CadSHAPE is not open (saved on the phone, not a dead grey button).
struct CommitButtons: View {
    let connected: Bool
    let done: Bool
    let working: Bool
    let again: String
    let measureAgain: () -> Void
    let commit: () -> Void
    let connect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !connected {
                Label("Lagret på telefonen – sendes når CadSHAPE er åpent", systemImage: "tray.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(good)
            }
            HStack(spacing: 10) {
                if done || !connected {
                    if connected {
                        Button(action: commit) { Label("Lag igjen", systemImage: "cube") }
                            .buttonStyle(SecondaryStyle())
                            .disabled(working)
                    } else {
                        Button(action: connect) { Label("Koble til", systemImage: "link") }
                            .buttonStyle(SecondaryStyle())
                    }
                    Button(action: measureAgain) { Label("Mål neste", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(PrimaryStyle())
                } else {
                    Button(action: measureAgain) { Label(again, systemImage: "arrow.counterclockwise") }
                        .buttonStyle(SecondaryStyle())
                    Button(action: commit) { Label("Lag i CadSHAPE", systemImage: "cube.fill") }
                        .buttonStyle(PrimaryStyle(enabled: !working))
                        .disabled(working)
                }
            }
        }
    }
}
