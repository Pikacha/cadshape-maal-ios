import HoleKit
import SwiftUI

// The bottom panel for «Inni boks» and «Gjenstand»: live sizes while measuring, then what to make,
// with a small drawing of it seen from above.

/// The four kinds of measuring.
struct ModePicker: View {
    @ObservedObject var model: MeasureModel

    var body: some View {
        Picker("Hva måles", selection: $model.mode) {
            ForEach(MeasureMode.allCases) { m in Text(m.short).tag(m) }
        }
        .pickerStyle(.segmented)
    }
}

struct SpaceContent: View {
    @ObservedObject var model: MeasureModel
    @ObservedObject var space: SpaceModel

    var body: some View {
        if space.locked {
            if model.mode == .box {
                BoxLockedContent(model: model, space: space)
            } else {
                ObjectLockedContent(model: model, space: space)
            }
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
            ModePicker(model: model)
            SizeHeader(text: sizeText, sure: sureText, unsure: false, label: model.mode == .box ? "innvendig" : "fotavtrykk")
            if model.mode == .box, let b = space.box {
                WallsSeen(seen: b.seen, wall: b.wall)
            }
            SteadyBar(value: space.steadiness)
            Text(space.hint).font(.subheadline.weight(.medium)).foregroundStyle(space.steadiness > 0.7 ? good : accent)
            HStack(spacing: 10) {
                if model.mode == .box {
                    Button {
                        space.typeIn()
                    } label: {
                        Label("Skriv inn", systemImage: "keyboard")
                    }
                    .buttonStyle(SecondaryStyle())
                }
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
        if model.mode == .box {
            guard let b = space.box else { return "Sikt på bunnen" }
            return "\(mm(b.width, digits: 0)) × \(mm(b.length, digits: 0))" + (b.height.map { " × \(mm($0, digits: 0))" } ?? "") + " mm"
        }
        guard let o = space.object else { return "Sikt på tingen" }
        return "\(mm(o.width, digits: 0)) × \(mm(o.length, digits: 0)) mm, \(mm(o.height, digits: 0)) høy"
    }

    private var sureText: String? {
        if model.mode == .box, let b = space.box { return "± \(mm(b.spread)) mm" }
        if model.mode == .object, space.object != nil { return "± 2 mm (LiDAR)" }
        return nil
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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(BoxMake.allCases) { k in
                        ChoiceCard(title: k.short, symbol: k.symbol, on: space.boxMake == k) { space.setBoxMake(k) }
                            .frame(width: 84)
                    }
                }
            }
            BoxSketch(box: space.boxOut, make: space.boxMake, cols: Int(space.values[.cols] ?? 3), rows: Int(space.values[.rows] ?? 2), clearance: space.values[.clearance] ?? 0.5)
                .frame(height: 130)
            Text(space.boxMake.hint).font(.footnote).opacity(0.75)
            VStack(spacing: 8) {
                ForEach(space.boxMake.uses.filter { $0.isCount }) { p in
                    SpaceParamRow(param: p, value: space.values[p] ?? p.defaultValue, auto: nil) { space.setValue(p, $0) }
                }
            }
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

/// A size you can type or nudge.
private struct DimRow: View {
    let label: String
    let value: Double
    var focus: FocusState<DimField?>.Binding
    let field: DimField
    let change: (Double) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.subheadline)
            Spacer(minLength: 4)
            Button { change(value - 0.5) } label: { Image(systemName: "minus") }
                .buttonStyle(RoundStyle())
            TextField("", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(width: 64)
                .focused(focus, equals: field)
                .onChange(of: text) { t in
                    if let v = Double(t.replacingOccurrences(of: ",", with: ".")), v > 0, abs(v - value) > 0.001 { change(v) }
                }
            Text("mm").font(.subheadline).opacity(0.7)
            Button { change(value + 0.5) } label: { Image(systemName: "plus") }
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
        if param.isSwitch {
            Toggle(param.label, isOn: Binding(get: { value >= 0.5 }, set: { change($0 ? 1 : 0) }))
                .font(.subheadline)
                .tint(accent)
        } else {
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
        .accessibilityLabel("Tegning av boksen sett ovenfra")
    }
}

// MARK: Something on a table

struct ObjectLockedContent: View {
    @ObservedObject var model: MeasureModel
    @ObservedObject var space: SpaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let o = space.objectOut {
                SizeHeader(text: "\(mm(o.width, digits: 0)) × \(mm(o.length, digits: 0)) mm", sure: "\(mm(o.height, digits: 0)) mm høy", unsure: false, label: "fotavtrykk", busy: space.working)
                HStack(spacing: 8) {
                    ForEach(ObjectMake.allCases) { k in
                        ChoiceCard(title: k.short, symbol: k.symbol, on: space.objectMake == k) { space.setObjectMake(k) }
                    }
                }
                ObjectSketch(object: o, make: space.objectMake, clearance: space.values[.clearanceObject] ?? 1, rim: space.values[.rim] ?? 6, notch: (space.values[.notch] ?? 1) >= 0.5)
                    .frame(height: 130)
                Text(space.objectMake.hint).font(.footnote).opacity(0.75)
                VStack(spacing: 8) {
                    ForEach(space.objectMake.uses) { p in
                        SpaceParamRow(param: p, value: space.values[p] ?? p.defaultValue, auto: p == .depth ? max(3, min(80, o.height * 0.8)) : nil) { space.setValue(p, $0) }
                    }
                }
            }
            SpaceStatus(space: space)
            SpaceButtons(model: model, space: space, again: "Mål på nytt")
        }
    }
}

/// The footprint from above, the pocket round it and what holds it.
struct ObjectSketch: View {
    let object: ObjectOut
    let make: ObjectMake
    let clearance: Double
    let rim: Double
    let notch: Bool

    var body: some View {
        Canvas { ctx, size in
            let pw = object.width + 2 * clearance, pl = object.length + 2 * clearance
            let W: Double = make == .tray ? pw + 2 * rim : ceil((pw + 5.5) / 42) * 42 - 0.5
            let L: Double = make == .tray ? pl + 2 * rim : ceil((pl + 5.5) / 42) * 42 - 0.5
            let pad = 12.0
            let sw = Double(size.width), sh = Double(size.height)
            let k = min((sw - 2 * pad) / W, (sh - 2 * pad) / L)
            let cx = sw / 2, cy = sh / 2
            func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: cx + x * k, y: cy - y * k) }
            let slab = CGRect(x: cx - W / 2 * k, y: cy - L / 2 * k, width: W * k, height: L * k)
            ctx.fill(Path(roundedRect: slab, cornerRadius: 6), with: .color(accent.opacity(0.85)))
            if make == .gridfinity {
                var g = Path()
                var x = -W / 2 + 42
                while x < W / 2 - 1 {
                    g.move(to: pt(x, -L / 2))
                    g.addLine(to: pt(x, L / 2))
                    x += 42
                }
                var y = -L / 2 + 42
                while y < L / 2 - 1 {
                    g.move(to: pt(-W / 2, y))
                    g.addLine(to: pt(W / 2, y))
                    y += 42
                }
                ctx.stroke(g, with: .color(.black.opacity(0.25)), lineWidth: 1)
            }
            var pocket = Path()
            if let first = object.outline.first, first.count >= 2 {
                pocket.move(to: pt(first[0], first[1]))
                for q in object.outline.dropFirst() where q.count >= 2 { pocket.addLine(to: pt(q[0], q[1])) }
                pocket.closeSubpath()
            }
            // The clearance as a thicker edge round the outline.
            let edge = CGFloat(max(1, 2 * clearance * k))
            ctx.stroke(pocket, with: .color(.black.opacity(0.8)), style: StrokeStyle(lineWidth: edge, lineJoin: .round))
            ctx.fill(pocket, with: .color(.black.opacity(0.8)))
            if notch {
                let d = max(14, min(26, min(pw, pl) * 0.5)) * k
                let c = pt(0, -pl / 2)
                ctx.fill(Path(ellipseIn: CGRect(x: Double(c.x) - d / 2, y: Double(c.y) - d / 2, width: d, height: d)), with: .color(.black.opacity(0.8)))
            }
        }
        .accessibilityLabel("Tegning av brettet med lommen sett ovenfra")
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
            Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(accent)
        }
    }
}

struct SpaceButtons: View {
    @ObservedObject var model: MeasureModel
    @ObservedObject var space: SpaceModel
    let again: String

    var body: some View {
        HStack(spacing: 10) {
            Button {
                space.measureAgain()
            } label: {
                Label(again, systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(SecondaryStyle())
            Button {
                space.commit()
            } label: {
                Label(model.connected ? "Lag i CadSHAPE" : "Lagret", systemImage: model.connected ? "cube.fill" : "tray.fill")
            }
            .buttonStyle(PrimaryStyle(enabled: model.connected && !space.working))
            .disabled(!model.connected || space.working)
        }
    }
}
