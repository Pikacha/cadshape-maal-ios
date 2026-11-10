import HoleKit
import SwiftUI
import UIKit

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
