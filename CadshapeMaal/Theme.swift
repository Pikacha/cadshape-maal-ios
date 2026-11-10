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
