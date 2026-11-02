import HoleKit
import SwiftUI

/// «Formen med mål»: the scanned thing as a CAD line drawing with dimension lines – the shape,
/// not the photo. Side view (stacked parts, heights on the right) or top view (outlines).
enum DrawingSide: String, CaseIterable, Identifiable {
    case side, top
    var id: String { rawValue }
    var label: String { self == .side ? "Fra siden" : "Ovenfra" }
}

/// Width of a part seen from the side (mm).
private func sideWidth(_ p: ScanPart) -> Double {
    switch p.kind {
    case .cylinder: return p.d
    case .cone: return max(p.d, p.dTop)
    case .box, .profile: return p.w
    }
}

/// The measure written next to a part: «Ø38,8», «60 × 30», «≈ 42 × 18».
func widthText(_ p: ScanPart) -> String {
    switch p.kind {
    case .cylinder: return p.inner.map { "Ø\(shortMM(p.d))/Ø\(shortMM($0))" } ?? "Ø\(shortMM(p.d))"
    case .cone: return "Ø\(shortMM(p.d))→\(shortMM(p.dTop))"
    case .box: return "\(shortMM(p.w)) × \(shortMM(p.l))"
    case .profile: return "≈ \(shortMM(p.w)) × \(shortMM(p.l))"
    }
}

struct ShapeDrawing: View {
    let shapes: ScanShapes
    let side: DrawingSide

    private let line = Color.white.opacity(0.92)
    private let dim = accent

    var body: some View {
        Canvas { ctx, size in
            if side == .side { drawSide(ctx, size) } else { drawTop(ctx, size) }
        }
        .accessibilityElement()
        .accessibilityLabel("Tegning av formen: " + shapes.lines.joined(separator: ", "))
    }

    private func label(_ ctx: GraphicsContext, _ text: String, at p: CGPoint, anchor: UnitPoint, color: Color = accent, size: CGFloat = 13) {
        ctx.draw(Text(text).font(.system(size: size, weight: .bold)).monospacedDigit().foregroundColor(color), at: p, anchor: anchor)
    }

    private func dimLine(_ ctx: GraphicsContext, from a: CGPoint, to b: CGPoint, vertical: Bool) {
        var p = Path()
        p.move(to: a)
        p.addLine(to: b)
        let t: CGFloat = 4
        if vertical {
            p.move(to: CGPoint(x: a.x - t, y: a.y)); p.addLine(to: CGPoint(x: a.x + t, y: a.y))
            p.move(to: CGPoint(x: b.x - t, y: b.y)); p.addLine(to: CGPoint(x: b.x + t, y: b.y))
        } else {
            p.move(to: CGPoint(x: a.x, y: a.y - t)); p.addLine(to: CGPoint(x: a.x, y: a.y + t))
            p.move(to: CGPoint(x: b.x, y: b.y - t)); p.addLine(to: CGPoint(x: b.x, y: b.y + t))
        }
        ctx.stroke(p, with: .color(dim), lineWidth: 1.2)
    }

    private func drawSide(_ ctx: GraphicsContext, _ size: CGSize) {
        guard let first = shapes.parts.first else { return }
        let widest = CGFloat(max(1, shapes.parts.map(sideWidth).max() ?? 1))
        // Room for the labels left and the height dimensions right.
        let left: CGFloat = 78, right: CGFloat = 92, topPad: CGFloat = 26, bottomPad: CGFloat = 26
        let scale = min((size.width - left - right) / widest, (size.height - topPad - bottomPad) / CGFloat(max(1, shapes.height)))
        let cx = left + (size.width - left - right) / 2
        let base = size.height - bottomPad
        let y = { (z: Double) in base - CGFloat(z - first.z0) * scale }
        // Centre line.
        var axis = Path()
        axis.move(to: CGPoint(x: cx, y: y(first.z0) + 12))
        axis.addLine(to: CGPoint(x: cx, y: y(first.z0 + shapes.height) - 12))
        ctx.stroke(axis, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        let hx = cx + widest * scale / 2 + 18
        for p in shapes.parts {
            let y0 = y(p.z0), y1 = y(p.z1)
            var shape = Path()
            if p.kind == .cone {
                let b = CGFloat(p.d) * scale / 2, t = CGFloat(p.dTop) * scale / 2
                shape.move(to: CGPoint(x: cx - b, y: y0))
                shape.addLine(to: CGPoint(x: cx + b, y: y0))
                shape.addLine(to: CGPoint(x: cx + t, y: y1))
                shape.addLine(to: CGPoint(x: cx - t, y: y1))
                shape.closeSubpath()
            } else {
                let w = CGFloat(sideWidth(p)) * scale
                shape.addRect(CGRect(x: cx - w / 2, y: y1, width: w, height: y0 - y1))
            }
            ctx.stroke(shape, with: .color(line), style: StrokeStyle(lineWidth: 1.6, dash: p.kind == .profile ? [6, 4] : []))
            // Inner bore of a tube.
            if p.kind == .cylinder, let i = p.inner {
                let w = CGFloat(i) * scale
                ctx.stroke(Path(CGRect(x: cx - w / 2, y: y1, width: w, height: y0 - y1)), with: .color(line.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            let mid = (y0 + y1) / 2
            label(ctx, widthText(p), at: CGPoint(x: cx - CGFloat(sideWidth(p)) * scale / 2 - 8, y: mid), anchor: .trailing)
            if y0 - y1 > 14 {
                dimLine(ctx, from: CGPoint(x: hx, y: y0), to: CGPoint(x: hx, y: y1), vertical: true)
                label(ctx, shortMM(p.height), at: CGPoint(x: hx + 8, y: mid), anchor: .leading)
            }
        }
        if shapes.parts.count > 1 {
            let tx = hx + 46
            dimLine(ctx, from: CGPoint(x: tx, y: y(first.z0)), to: CGPoint(x: tx, y: y(first.z0 + shapes.height)), vertical: true)
            label(ctx, shortMM(shapes.height), at: CGPoint(x: tx + 6, y: (y(first.z0) + y(first.z0 + shapes.height)) / 2), anchor: .leading, color: .white)
        }
    }

    private func drawTop(_ ctx: GraphicsContext, _ size: CGSize) {
        guard !shapes.parts.isEmpty else { return }
        let extent = max(1, shapes.parts.map { p -> Double in
            let c = max(abs(p.centre.x), abs(p.centre.y))
            switch p.kind {
            case .cylinder: return c + p.d / 2
            case .cone: return c + max(p.d, p.dTop) / 2
            case .box, .profile: return c + (p.w * p.w + p.l * p.l).squareRoot() / 2
            }
        }.max() ?? 1)
        // Centred on the round parts' common axis (or the first part).
        let o = shapes.parts.first(where: { $0.kind == .cylinder || $0.kind == .cone })?.centre ?? shapes.parts[0].centre
        let scale = (min(size.width, size.height) / 2 - 34) / CGFloat(extent)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let at = { (q: P2) in CGPoint(x: c.x + CGFloat(q.x - o.x) * scale, y: c.y - CGFloat(q.y - o.y) * scale) }
        // Biggest last, so its label is on top.
        let order = shapes.parts.sorted { sideWidth($0) < sideWidth($1) }
        for (n, p) in order.enumerated() {
            let pc = at(p.centre)
            let isLast = n == order.count - 1
            switch p.kind {
            case .cylinder, .cone:
                let r = CGFloat(max(p.d, p.kind == .cone ? p.dTop : 0)) * scale / 2
                ctx.stroke(Path(ellipseIn: CGRect(x: pc.x - r, y: pc.y - r, width: 2 * r, height: 2 * r)), with: .color(line), lineWidth: 1.6)
                if isLast {
                    dimLine(ctx, from: CGPoint(x: pc.x - r, y: pc.y + r + 14), to: CGPoint(x: pc.x + r, y: pc.y + r + 14), vertical: false)
                    label(ctx, widthText(p), at: CGPoint(x: pc.x, y: pc.y + r + 28), anchor: .center)
                }
            case .box, .profile:
                let w = CGFloat(p.w) * scale, l = CGFloat(p.l) * scale
                var r = Path(roundedRect: CGRect(x: -w / 2, y: -l / 2, width: w, height: l), cornerRadius: CGFloat(p.corner) * scale)
                r = r.applying(CGAffineTransform(rotationAngle: -CGFloat(p.angle) * .pi / 180)).applying(CGAffineTransform(translationX: pc.x, y: pc.y))
                ctx.stroke(r, with: .color(line), style: StrokeStyle(lineWidth: 1.6, dash: p.kind == .profile ? [6, 4] : []))
                if isLast { label(ctx, widthText(p), at: CGPoint(x: pc.x, y: pc.y + max(w, l) / 2 + 22), anchor: .center) }
            }
        }
    }
}

/// One row per part, top first: name, measures with ± and a dot that says how well the shape fits
/// the scan. A tap on a row opens «Rett etter skyvelære» for that part.
struct PartRows: View {
    let shapes: ScanShapes
    var scale: ScaleSource = .tracking
    var onTap: ((Int) -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(shapes.parts.enumerated().reversed()), id: \.offset) { i, p in
                Button {
                    onTap?(i)
                } label: {
                    HStack(spacing: 12) {
                        Circle().fill(p.spread < 0.5 ? good : (p.spread < 1.5 ? warn : bad)).frame(width: 10, height: 10)
                        Text(name(p)).font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(widthText(p)) × \(shortMM(p.height))").font(.subheadline).monospacedDigit()
                            Text(plusMinusText(p.plusMinus(p.measures[0], scale: scale)) + " mm")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        if onTap != nil {
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(onTap == nil)
                .accessibilityElement(children: .combine)
                .accessibilityValue(p.spread < 0.5 ? "følger skannet" : "usikker")
                .accessibilityHint(onTap == nil ? "" : "Rett størrelsen etter skyvelæren")
            }
            Text(scale == .measured
                 ? "Størrelsen er rettet etter skyvelæren. ± er det målene fortsatt kan bomme."
                 : "Telefonen kan bomme 1–2 % på størrelsen. Mål ett langt mål med skyvelære og trykk på delen for å rette alle målene.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func name(_ p: ScanPart) -> String {
        switch p.kind {
        case .cylinder: return p.inner == nil ? "Sylinder" : "Rør"
        case .cone: return "Kjegle"
        case .box: return "Kloss"
        case .profile: return "Fri form"
        }
    }
}

/// «Rett etter skyvelære»: one measure from the calipers scales the whole scan.
struct CaliperSheet: View {
    let shapes: ScanShapes
    let start: Int
    let apply: (Int, PartMeasure, Double, Bool) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var part = 0
    @State private var measure: PartMeasure = .diameter
    @State private var text = ""
    @State private var learn = true
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if shapes.parts.count > 1 {
                    Picker("Del", selection: $part) {
                        ForEach(Array(shapes.parts.enumerated().reversed()), id: \.offset) { i, p in
                            Text("\(i + 1). \(p.text)").tag(i)
                        }
                    }
                }
                let p = shapes.parts[min(part, shapes.parts.count - 1)]
                Picker("Mål", selection: $measure) {
                    ForEach(p.measures) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Section {
                    LabeledContent("Skannet viser", value: "\(shortMM(p.value(measure))) mm")
                    HStack {
                        Text("Skyvelæren viser")
                        TextField("mm", text: $text)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .focused($focused)
                        Text("mm").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Ta det lengste målet du kan måle sikkert – da blir resten mest nøyaktig. Alle de andre målene følger med.")
                }
                Section {
                    Toggle("Lær telefonen av dette", isOn: $learn)
                } footer: {
                    Text("Telefonen husker hvor mye den bommet, og retter neste skann av seg selv (etter to rettinger).")
                }
                if let error {
                    Text(error).foregroundStyle(bad)
                }
            }
            .navigationTitle("Rett etter skyvelære")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bruk") {
                        guard let v = Double(text.replacingOccurrences(of: ",", with: ".")), v > 0 else {
                            error = "Skriv målet i millimeter, for eksempel 37,4."
                            return
                        }
                        if let e = apply(part, measure, v, learn) { error = e } else { dismiss() }
                    }
                    .disabled(text.isEmpty)
                }
            }
            .onAppear {
                part = min(max(start, 0), shapes.parts.count - 1)
                measure = shapes.parts[part].measures[0]
                focused = true
            }
            .onChange(of: part) { _, new in
                let ms = shapes.parts[new].measures
                if !ms.contains(measure) { measure = ms[0] }
            }
        }
    }
}

/// This phone's learnt size bias (UserDefaults, the phone only – never sent anywhere).
enum PhoneScaleStore {
    private static let key = "phoneScale"
    static func load() -> PhoneScale {
        guard let d = UserDefaults.standard.data(forKey: key), let v = try? JSONDecoder().decode(PhoneScale.self, from: d) else { return PhoneScale() }
        return v
    }
    static func save(_ v: PhoneScale) {
        if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: key) }
    }
    static func reset() { UserDefaults.standard.removeObject(forKey: key) }
}
