import HoleKit
import SwiftUI

// The bottom panel for «Inni boks» and «Gjenstand»: live sizes while measuring, then what to make,
// with a small drawing of it seen from above.

/// The kinds of measuring, as a row of chips (six do not fit a segmented control).
struct ModePicker: View {
    @ObservedObject var model: MeasureModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MeasureMode.allCases) { m in
                        Button {
                            model.mode = m
                        } label: {
                            Label(m.short, systemImage: m.symbol)
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .background(model.mode == m ? accent : Color.white.opacity(0.12), in: Capsule())
                                .foregroundStyle(model.mode == m ? Color.black : Color.white)
                        }
                        .buttonStyle(.plain)
                        .id(m)
                        .accessibilityAddTraits(model.mode == m ? .isSelected : [])
                    }
                }
            }
            .onAppear { proxy.scrollTo(model.mode, anchor: .center) }
        }
    }
}

struct SpaceContent: View {
    @ObservedObject var model: MeasureModel
    @ObservedObject var space: SpaceModel

    var body: some View {
        if space.locked {
            switch model.mode {
            case .box: BoxLockedContent(model: model, space: space)
            case .object: ObjectLockedContent(model: model, space: space)
            case .pipe: PipeLockedContent(model: model, space: space)
            default: GapLockedContent(model: model, space: space)
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
            SizeHeader(text: sizeText, sure: sureText, unsure: false, label: label)
            if model.mode == .box, let b = space.box {
                WallsSeen(seen: b.seen, wall: b.wall)
            }
            if model.mode == .object, !space.objectsBefore.isEmpty {
                Text("\(space.objectsBefore.count) ting i brettet – nå ting nr. \(space.objectsBefore.count + 1)").font(.footnote.weight(.semibold)).opacity(0.85)
            }
            if model.mode == .pipe, let d = space.pipe?.diameter, let s = nearPipes(d).first {
                Text("Nærmeste standard: Ø \(mm(s, digits: 0)) mm").font(.footnote.weight(.semibold)).opacity(0.85)
            }
            if model.mode == .gap, space.firstSurface != nil {
                Label("Flate 1 er valgt", systemImage: "1.circle.fill").font(.footnote).opacity(0.8)
            }
            SteadyBar(value: space.steadiness)
            Text(space.hint).font(.subheadline.weight(.medium)).foregroundStyle(space.steadiness > 0.7 ? good : accent)
            HStack(spacing: 10) {
                if model.mode != .object {
                    Button {
                        space.typeIn()
                    } label: {
                        Label("Skriv inn", systemImage: "keyboard")
                    }
                    .buttonStyle(SecondaryStyle())
                }
                if model.mode == .gap {
                    Button {
                        space.takeSurface()
                    } label: {
                        Label(space.firstSurface == nil ? "Flate 1" : "Flate 2", systemImage: space.firstSurface == nil ? "1.circle.fill" : "2.circle.fill")
                    }
                    .buttonStyle(PrimaryStyle(enabled: space.canTakeSurface))
                    .disabled(!space.canTakeSurface)
                } else {
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
    }

    private var label: String? {
        switch model.mode {
        case .box: return "innvendig"
        case .object: return space.object?.sharpened == true ? "skarp kant" : "fotavtrykk"
        case .pipe: return space.measuringSecond ? "rør 2" : "utvendig"
        default: return nil
        }
    }

    private var sizeText: String {
        switch model.mode {
        case .box:
            guard let b = space.box else { return "Sikt på bunnen" }
            return "\(mm(b.width, digits: 0)) × \(mm(b.length, digits: 0))" + (b.height.map { " × \(mm($0, digits: 0))" } ?? "") + " mm"
        case .object:
            guard let o = space.object else { return "Sikt på tingen" }
            return "\(mm(o.width, digits: 0)) × \(mm(o.length, digits: 0)) mm, \(mm(o.height, digits: 0)) høy"
        case .pipe:
            guard let p = space.pipe else { return "Sikt på røret" }
            return "Ø \(mm(p.diameter)) mm"
        default:
            return space.surface == nil ? "Sikt på en flate" : (space.firstSurface == nil ? "Flate 1" : "Flate 2")
        }
    }

    private var sureText: String? {
        switch model.mode {
        case .box: return space.box.map { "± \(mm($0.spread)) mm" }
        case .object: return space.object.map { $0.sharpened ? "± 0,7 mm (kanten fra bildet)" : "± 2 mm (LiDAR)" }
        case .pipe: return space.pipe.map { "avvik fra sylinder \(mm($0.residual)) mm" }
        default: return nil
        }
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

private enum DimField: Hashable { case width, length, height, diameter, second, gap, angle }

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
        let list = space.allObjects
        VStack(alignment: .leading, spacing: 12) {
            if let o = list.last {
                SizeHeader(text: list.count == 1 ? "\(mm(o.width, digits: 0)) × \(mm(o.length, digits: 0)) mm" : "\(list.count) ting", sure: list.count == 1 ? "\(mm(o.height, digits: 0)) mm høy" : nil, unsure: false, label: list.count == 1 ? "fotavtrykk" : "i samme brett", busy: space.working)
                if list.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(0..<list.count, id: \.self) { i in
                                Button {
                                    space.removeObject(at: i)
                                } label: {
                                    Label("\(mm(list[i].width, digits: 0)) × \(mm(list[i].length, digits: 0))", systemImage: "xmark.circle.fill")
                                }
                                .buttonStyle(ChipStyle(on: false))
                            }
                        }
                    }
                }
                HStack(spacing: 8) {
                    ForEach(ObjectMake.allCases) { k in
                        ChoiceCard(title: k.short, symbol: k.symbol, on: space.objectMake == k) { space.setObjectMake(k) }
                    }
                }
                ObjectSketch(objects: list, make: space.objectMake, clearance: space.values[.clearanceObject] ?? 1, rim: space.values[.rim] ?? 6, notch: (space.values[.notch] ?? 1) >= 0.5)
                    .frame(height: 130)
                Text(space.objectMake.hint).font(.footnote).opacity(0.75)
                Button {
                    space.addAnotherObject()
                } label: {
                    Label("Legg til en ting til", systemImage: "plus.circle.fill")
                }
                .buttonStyle(SecondaryStyle())
                .disabled(list.count >= 12)
                VStack(spacing: 8) {
                    ForEach(space.objectMake.uses) { p in
                        SpaceParamRow(param: p, value: space.values[p] ?? p.defaultValue, auto: p == .depth ? max(3, min(80, (list.map(\.height).max() ?? o.height) * 0.8)) : nil) { space.setValue(p, $0) }
                    }
                }
            }
            SpaceStatus(space: space)
            SpaceButtons(model: model, space: space, again: "Mål på nytt")
        }
    }
}

// MARK: A pipe

struct PipeLockedContent: View {
    @ObservedObject var model: MeasureModel
    @ObservedObject var space: SpaceModel
    @FocusState private var focus: DimField?

    var body: some View {
        let p = space.pipeOut
        VStack(alignment: .leading, spacing: 12) {
            SizeHeader(text: SpaceModel.text(p).replacingOccurrences(of: "Rør ", with: ""), sure: space.spread.map { "± \(mm($0)) mm" }, unsure: (space.spread ?? 0) > 2, label: space.manual ? "skrevet inn" : "utvendig", busy: space.working)
            StandardChips(value: p.diameter) { space.setPipe(diameter: $0) }
            VStack(spacing: 6) {
                DimRow(label: "Diameter", value: p.diameter, focus: $focus, field: .diameter, step: 0.1) { space.setPipe(diameter: $0) }
                if p.second != nil || space.pipeMake == .adapter {
                    DimRow(label: "Rør 2", value: p.second ?? p.diameter, focus: $focus, field: .second, step: 0.1) { space.setPipe(second: $0) }
                }
                if focus != nil {
                    Button("Ferdig") { focus = nil }
                        .buttonStyle(ChipStyle(on: true))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            HStack(spacing: 8) {
                ForEach(PipeMake.allCases) { k in
                    ChoiceCard(title: k.label, symbol: k.symbol, on: space.pipeMake == k) { space.setPipeMake(k) }
                }
            }
            Text(space.pipeMake.hint).font(.footnote).opacity(0.75)
            if space.pipeMake == .adapter && !space.manual {
                Button {
                    space.measureSecond()
                } label: {
                    Label(p.second == nil ? "Mål den andre diameteren" : "Mål rør 2 på nytt", systemImage: "camera.metering.center.weighted")
                }
                .buttonStyle(SecondaryStyle())
            }
            VStack(spacing: 8) {
                ForEach(space.pipeMake.uses) { q in
                    SpaceParamRow(param: q, value: space.values[q] ?? q.defaultValue, auto: nil) { space.setValue(q, $0) }
                }
            }
            SpaceStatus(space: space)
            SpaceButtons(model: model, space: space, again: space.manual ? "Mål med LiDAR" : "Mål på nytt")
        }
    }
}

/// Standard pipe sizes near the measured one, one tap to use.
struct StandardChips: View {
    let value: Double
    let use: (Double) -> Void

    var body: some View {
        let near = nearPipes(value)
        if !near.isEmpty {
            HStack(spacing: 8) {
                Text("Standard:").font(.footnote).opacity(0.75)
                ForEach(near, id: \.self) { s in
                    Button("Ø \(mm(s, digits: 0))") { use(s) }
                        .buttonStyle(ChipStyle(on: abs(s - value) < 0.01))
                }
            }
        }
    }
}

// MARK: A gap

struct GapLockedContent: View {
    @ObservedObject var model: MeasureModel
    @ObservedObject var space: SpaceModel
    @FocusState private var focus: DimField?

    var body: some View {
        let g = space.gapOut
        VStack(alignment: .leading, spacing: 12) {
            SizeHeader(text: "\(mm(g.gap)) mm", sure: g.angle >= 0.5 ? "\(mm(g.angle))° skjevt" : "parallelle flater", unsure: false, label: space.manual ? "skrevet inn" : "spalte", busy: space.working)
            VStack(spacing: 6) {
                DimRow(label: "Spalte", value: g.gap, focus: $focus, field: .gap, step: 0.1) { space.setGap($0) }
                DimRow(label: "Vinkel", value: g.angle, focus: $focus, field: .angle, unit: "°", step: 0.5) { space.setGap(angle: $0) }
                if focus != nil {
                    Button("Ferdig") { focus = nil }
                        .buttonStyle(ChipStyle(on: true))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            HStack(spacing: 8) {
                ForEach(GapMake.allCases) { k in
                    ChoiceCard(title: k.label, symbol: k.symbol, on: space.gapMake == k) { space.setGapMake(k) }
                }
            }
            Text(space.gapMake.hint).font(.footnote).opacity(0.75)
            VStack(spacing: 8) {
                ForEach(space.gapMake.uses) { q in
                    SpaceParamRow(param: q, value: space.values[q] ?? q.defaultValue, auto: nil) { space.setValue(q, $0) }
                }
            }
            SpaceStatus(space: space)
            SpaceButtons(model: model, space: space, again: space.manual ? "Mål med LiDAR" : "Mål på nytt")
        }
    }
}

/// The footprints from above (in rows, as CadSHAPE lays them out), the pockets and what holds them.
struct ObjectSketch: View {
    let objects: [ObjectOut]
    let make: ObjectMake
    let clearance: Double
    let rim: Double
    let notch: Bool

    private struct Item {
        var pts: [[Double]]
        var w: Double
        var l: Double
        var c = (0.0, 0.0)
    }

    /// Long side along x, deepest first, rows no wider than the plate allows (as packPockets).
    private func layout() -> (items: [Item], w: Double, l: Double) {
        let gap = 4.0
        var items: [Item] = objects.map { o in
            let turn = o.length > o.width + 0.01
            let pts = turn ? o.outline.map { [-$0[1], $0[0]] } : o.outline
            return Item(pts: pts, w: (turn ? o.length : o.width) + 2 * clearance, l: (turn ? o.width : o.length) + 2 * clearance)
        }
        let order = items.indices.sorted { items[$0].l > items[$1].l }
        let area = items.reduce(0) { $0 + ($1.w + gap) * ($1.l + gap) }
        let limit = max(items.map(\.w).max() ?? 0, min(203, area.squareRoot() * 1.3))
        var rows: [(ids: [Int], w: Double, l: Double)] = []
        for i in order {
            if var last = rows.last, last.w + gap + items[i].w <= limit + 1e-6 {
                last.ids.append(i)
                last.w += gap + items[i].w
                last.l = max(last.l, items[i].l)
                rows[rows.count - 1] = last
            } else {
                rows.append(([i], items[i].w, items[i].l))
            }
        }
        let rowGap = notch ? 13.0 + 2 : gap
        let total = rows.reduce(0) { $0 + $1.l } + rowGap * Double(max(0, rows.count - 1))
        var y = total / 2
        for r in rows {
            var x = -r.w / 2
            for i in r.ids {
                items[i].c = (x + items[i].w / 2, y - items[i].l / 2)
                x += items[i].w + gap
            }
            y -= r.l + rowGap
        }
        return (items, rows.map { $0.w }.max() ?? 0, total)
    }

    var body: some View {
        Canvas { ctx, size in
            let lay = layout()
            let W: Double = make == .tray ? lay.w + 2 * rim : ceil((lay.w + 5.5) / 42) * 42 - 0.5
            let L: Double = make == .tray ? lay.l + 2 * rim : ceil((lay.l + 5.5) / 42) * 42 - 0.5
            let pad = 12.0
            let sw = Double(size.width), sh = Double(size.height)
            let k = min((sw - 2 * pad) / max(1, W), (sh - 2 * pad) / max(1, L))
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
            let edge = CGFloat(max(1, 2 * clearance * k))
            for it in lay.items {
                var pocket = Path()
                if let first = it.pts.first, first.count >= 2 {
                    pocket.move(to: pt(it.c.0 + first[0], it.c.1 + first[1]))
                    for q in it.pts.dropFirst() where q.count >= 2 { pocket.addLine(to: pt(it.c.0 + q[0], it.c.1 + q[1])) }
                    pocket.closeSubpath()
                }
                // The clearance as a thicker edge round the outline.
                ctx.stroke(pocket, with: .color(.black.opacity(0.8)), style: StrokeStyle(lineWidth: edge, lineJoin: .round))
                ctx.fill(pocket, with: .color(.black.opacity(0.8)))
                if notch {
                    let d = max(14, min(26, min(it.w, it.l) * 0.5)) * k
                    let c = pt(it.c.0, it.c.1 - it.l / 2)
                    ctx.fill(Path(ellipseIn: CGRect(x: Double(c.x) - d / 2, y: Double(c.y) - d / 2, width: d, height: d)), with: .color(.black.opacity(0.8)))
                }
            }
        }
        .accessibilityLabel("Tegning av brettet med lommene sett ovenfra")
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
