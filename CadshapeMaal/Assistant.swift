import SwiftUI

/// One line of the conversation with the assistant in CadSHAPE.
struct AssistantTurn: Identifiable, Equatable {
    let id = UUID()
    let user: Bool
    let text: String
    var actions: [String] = []
    var failed = false
}

/// Talks to the assistant inside CadSHAPE (`POST api/live/assistant`). The model keys and the drawing
/// stay on the PC or on kloki.no: the phone sends the text and shows the answer.
final class AssistantModel: ObservableObject {
    @Published var turns: [AssistantTurn] = []
    @Published var busy = false
    @Published var providers: [String] = []
    @Published var provider: String = UserDefaults.standard.string(forKey: "assistantProvider") ?? "claude" {
        didSet { UserDefaults.standard.set(provider, forKey: "assistantProvider") }
    }

    static let names: [String: String] = ["claude": "Claude", "codex": "Codex", "deepseek": "DeepSeek"]

    /// Which models the server can use (asked once per connection).
    func loadProviders(_ api: CadshapeClient?) {
        guard let api, providers.isEmpty else { return }
        api.getJSON("api/live/assistant") { [weak self] r in
            guard let self, case .success(let j) = r, let list = j["providers"] as? [String] else { return }
            self.providers = list
            if !list.contains(self.provider), let first = list.first { self.provider = first }
        }
    }

    /// Sends one message with the conversation so far. `done` runs when the answer is in (also after an error).
    func send(_ text: String, api: CadshapeClient?, done: @escaping () -> Void = {}) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        let history: [[String: String]] = turns.filter { !$0.failed }.map { ["role": $0.user ? "user" : "assistant", "text": $0.text] }
        turns.append(AssistantTurn(user: true, text: q))
        guard let api else {
            turns.append(AssistantTurn(user: false, text: "Koble til CadSHAPE først (trykk på statusen øverst på Hjem).", failed: true))
            return
        }
        busy = true
        // Drawing, checking and slicing can take minutes.
        api.postJSON("api/live/assistant", body: ["provider": provider, "text": q, "history": history], timeout: 420) { [weak self] r in
            guard let self else { return }
            self.busy = false
            switch r {
            case .success(let j):
                self.turns.append(AssistantTurn(user: false, text: j["text"] as? String ?? "Ferdig.", actions: j["actions"] as? [String] ?? []))
            case .failure(let e):
                self.turns.append(AssistantTurn(user: false, text: e.message, failed: true))
            }
            done()
        }
    }

    func clear() {
        guard !busy else { return }
        turns = []
    }
}

/// «Assistent»: ask for a part, a change, a check or a print from the phone. CadSHAPE draws it
/// (on the PC or on kloki.no); a print still needs «Ja, print» on the card.
struct AssistantSheet: View {
    @ObservedObject var model: MeasureModel
    @ObservedObject var watch: PrintWatch
    @ObservedObject var chat: AssistantModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var typing: Bool

    /// Explicit, so the private state above never decides who may open the sheet.
    init(model: MeasureModel, watch: PrintWatch, chat: AssistantModel) {
        _model = ObservedObject(wrappedValue: model)
        _watch = ObservedObject(wrappedValue: watch)
        _chat = ObservedObject(wrappedValue: chat)
    }

    private let ink = Color(red: 0.13, green: 0.09, blue: 0.04)
    private let starters = ["Er den printklar? Rett det som må fikses", "Gjør den enklere og lettere", "Hva koster den i gram og minutter?", "Print det"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if chat.turns.isEmpty { intro }
                        ForEach(chat.turns) { t in
                            bubble(t).id(t.id)
                        }
                        if chat.busy { working.id("busy") }
                        if let card = watch.card, card.state == "venter" { cardRow(card) }
                    }
                    .padding(16)
                }
                .onChange(of: chat.turns.count) { _, _ in
                    if let last = chat.turns.last?.id { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                }
                .onChange(of: chat.busy) { _, b in
                    if b { withAnimation { proxy.scrollTo("busy", anchor: .bottom) } }
                }
            }
            if !chat.busy { starterRow }
            composer
        }
        .background(ground.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onAppear { chat.loadProviders(model.api) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.headline)
                .foregroundStyle(ink)
                .frame(width: 34, height: 34)
                .background(accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Assistent").font(.headline)
                Text(model.pcOpen == true ? "Tegner i CadSHAPE" : "CadSHAPE er ikke åpent")
                    .font(.footnote)
                    .foregroundStyle(model.pcOpen == true ? muted : warn)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if chat.providers.count > 1 {
                Menu {
                    ForEach(chat.providers, id: \.self) { p in
                        Button(AssistantModel.names[p] ?? p) { chat.provider = p }
                    }
                } label: {
                    Text(AssistantModel.names[chat.provider] ?? chat.provider)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }
            }
            if !chat.turns.isEmpty {
                Button { chat.clear() } label: { circleIcon("square.and.pencil") }
                    .disabled(chat.busy)
                    .accessibilityLabel("Ny samtale")
            }
            Button { dismiss() } label: { circleIcon("xmark") }
                .accessibilityLabel("Lukk")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func circleIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.footnote.weight(.bold))
            .frame(width: 34, height: 34)
            .background(Color.white.opacity(0.08), in: Circle())
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hva skal vi lage?").font(.title2.bold())
            Text("Skriv hva du vil lage eller endre. CadSHAPE tegner det uten støtte, sjekker at det er printklart og sier gram og minutter. En print starter aldri før du har trykket «Ja, print».")
                .font(.subheadline)
                .foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    private func bubble(_ t: AssistantTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !t.actions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(t.actions.enumerated()), id: \.offset) { _, a in
                        Label(a, systemImage: "checkmark").font(.footnote).foregroundStyle(muted)
                    }
                }
            }
            Text(t.failed ? "Det gikk ikke: \(t.text)" : t.text)
                .font(.body)
                .foregroundStyle(t.failed ? bad : (t.user ? ink : Color.white))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(t.user ? accent : panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, alignment: t.user ? .trailing : .leading)
        .padding(t.user ? .leading : .trailing, 36)
    }

    private var working: some View {
        HStack(spacing: 10) {
            ProgressView().tint(accent)
            Text("\(AssistantModel.names[chat.provider] ?? "Assistenten") jobber …").font(.subheadline).foregroundStyle(muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// A «Godkjenn print» card is waiting: close the chat and show it.
    private func cardRow(_ card: ApprovalCard) -> some View {
        Button {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { watch.showCard = true }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "printer.fill").foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Godkjenn print: \(card.name)").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(card.summary).font(.footnote).foregroundStyle(muted)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(muted)
            }
            .padding(14)
            .background(Color(red: 0.13, green: 0.16, blue: 0.21), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(accent.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var starterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(starters, id: \.self) { s in
                    Button(s) { submit(s) }.buttonStyle(ChipStyle())
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 6)
    }

    private var canSend: Bool { !chat.busy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Hva skal vi lage eller endre?", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .focused($typing)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
            Button { submit(text) } label: {
                Image(systemName: "arrow.up")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(ink)
                    .frame(width: 44, height: 44)
                    .background(canSend ? accent : accent.opacity(0.35), in: Circle())
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func submit(_ q: String) {
        chat.send(q, api: model.api) { watch.refresh() }
        text = ""
        typing = false
    }
}
