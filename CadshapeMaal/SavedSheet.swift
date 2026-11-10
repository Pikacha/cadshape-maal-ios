import HoleKit
import SwiftUI
import UIKit

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
