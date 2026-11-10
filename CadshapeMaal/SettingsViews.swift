import HoleKit
import SwiftUI
import UIKit

// MARK: Connecting

struct PairingCard: View {
    @ObservedObject var model: MeasureModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "qrcode.viewfinder").font(.system(size: 36)).foregroundStyle(accent)
            Text("Koble til CadSHAPE").font(.title3.bold())
            Text("Sikt på QR-koden i CadSHAPE på PC-en (Fil → «Mål med telefonen»). Eller logg inn på nett.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .opacity(0.8)
            HStack(spacing: 10) {
                Button("CadSHAPE på nett") { model.showSettings = true }
                    .buttonStyle(SecondaryStyle())
                Button(model.pairing == nil ? "Mål uten PC" : "Avbryt") { model.wantsPairing = false }
                    .buttonStyle(SecondaryStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .modifier(GlassPanel())
    }
}

struct SettingsSheet: View {
    @ObservedObject var model: MeasureModel
    /// From the home screen: «Skann QR-koden» opens the camera screen (nil = this screen has the camera).
    var onScanQR: (() -> Void)? = nil
    @State private var link = ""
    @State private var badLink = false
    @State private var web = "kloki.no/cadshape"
    @State private var password = ""
    @State private var loggingIn = false
    @State private var loginError: String?
    @Environment(\.dismiss) private var dismiss
    /// One for the app: the sheet's view is rebuilt often, and each URLSession would live on.
    private static let login = WebLogin()
    /// Where there is no camera route (the 3D scan), «Skann QR-koden» is left out.
    private let allowQR: Bool

    init(model: MeasureModel, allowQR: Bool = true, onScanQR: (() -> Void)? = nil) {
        self.model = model
        self.allowQR = allowQR
        self.onScanQR = onScanQR
    }

    private func close() {
        model.showSettings = false
        model.showConnect = false
        dismiss()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tilkoblet") {
                    if let p = model.pairing {
                        LabeledContent(p.isOnline ? "Nett" : "PC", value: p.hostLabel)
                        LabeledContent("CadSHAPE", value: model.pcOpen == true ? "åpent" : (model.pcOpen == false ? "ikke åpent" : "ingen kontakt"))
                        if let e = model.connectionError {
                            Text(e).font(.footnote).foregroundStyle(accent)
                        }
                        Button("Sjekk tilkoblingen") { model.checkPc() }
                        Button(p.isOnline ? "Logg ut" : "Glem denne PC-en", role: .destructive) { model.forget() }
                    } else {
                        Text("Ikke koblet til ennå.")
                    }
                }
                Section {
                    TextField("kloki.no/cadshape", text: $web)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Passord", text: $password)
                        .textContentType(.password)
                    Button {
                        guard let base = Pairing.webAddress(web) else {
                            loginError = "Skriv adressen, f.eks. kloki.no/cadshape."
                            return
                        }
                        loggingIn = true
                        loginError = nil
                        Self.login.login(base: base, password: password) { r in
                            loggingIn = false
                            switch r {
                            case .success(let session):
                                password = ""
                                model.loggedIn(base: base, session: session)
                                close()
                            case .failure(let e):
                                loginError = e.message
                            }
                        }
                    } label: {
                        HStack {
                            Text("Logg inn")
                            if loggingIn { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(password.isEmpty || loggingIn)
                    if let loginError {
                        Text(loginError).font(.footnote).foregroundStyle(bad)
                    }
                } header: {
                    Text("CadSHAPE på nett")
                } footer: {
                    Text("Virker hvor som helst med nett, uten .bat-fil og QR-kode. Passordet lagres ikke; innloggingen huskes i 90 dager. Delene lages i CadSHAPE som er åpent i en nettleser.")
                }
                Section {
                    if allowQR {
                        Button {
                            if let onScanQR {
                                onScanQR()
                            } else {
                                model.showSettings = false
                                model.wantsPairing = true
                            }
                        } label: {
                            Label("Skann QR-koden", systemImage: "qrcode.viewfinder")
                        }
                    }
                    TextField("https://192.168.…:5192/maal.html?k=…", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Koble til") {
                        if let p = Pairing.parse(link) {
                            badLink = false
                            model.paired(p)
                        } else {
                            badLink = true
                        }
                    }
                    if badLink {
                        Text("Lenken må være den fra QR-koden i CadSHAPE (med ?k=…).").font(.footnote).foregroundStyle(bad)
                    }
                } header: {
                    Text("PC-en på samme wifi")
                }
                // Calibrating needs the measuring camera: only offered from that screen.
                if onScanQR == nil {
                    CalibrationSection(model: model)
                }
                PhoneScaleSection()
                Section {
                    Toggle("Lås av seg selv når målet er stødig", isOn: $model.autoLock)
                } header: {
                    Text("Måling")
                } footer: {
                    Text("Låser bare når målet er stødig og skarpt nok. Er kanten grov, låser du selv – mål med skyvelære før deler som skal sitte stramt.")
                }
                Section {
                    // Numbers, hints and errors of the last minutes – no pictures or passwords.
                    ShareLink(item: model.problemReport(), subject: Text("CadSHAPE Mål – problem"),
                              message: Text("Hva skjedde, og hva forventet du?")) {
                        Label("Rapporter problem", systemImage: "exclamationmark.bubble")
                    }
                } footer: {
                    Text("Lager en tekst med appens siste hendelser og målinger (ingen bilder eller passord) som du kan sende.")
                }
                Section {
                    // The long explanation on its own page: the sheet stays short.
                    NavigationLink("Slik måler appen") { HowItMeasures() }
                    Text(appVersionText).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("CadSHAPE Mål")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ferdig") { close() }
                }
            }
        }
        .onAppear { if let s = model.webSuggestion { web = s } }
        .preferredColorScheme(.dark)
    }
}

/// «Slik måler appen»: what the numbers rest on, and how to get good ones.
struct HowItMeasures: View {
    var body: some View {
        Form {
            Section {
                    Text("Kanten på hullet finnes i kamerabildet (eller i LiDAR-dybden når hullet ikke skiller seg ut). LiDAR måler flaten rundt hullet – avstand og vinkel – og kanten legges ned på flaten i millimeter. Anslått avvik tar med variasjon, pikseloppløsning og flaten. Det er ikke en kalibrert garanti for passform. Bruk kontrollmål for små, trange hull. LiDAR kan også anslå dybden.")
                        .font(.footnote)
                    Text("Best resultat: 30–80 cm unna, mest mulig rett på, godt lys og hele kanten i bildet.")
                        .font(.footnote)
                    Text("Ser appen to kanter rundt hullet (skygge, fas eller hullets innside), låser den ikke av seg selv – du velger kanten etter låsing.")
                        .font(.footnote)
                    Text("Inni boks bruker LiDAR-punktene fra flere bilder samlet: bunnen, de fire veggene og kanten øverst. Hold telefonen 25–60 cm over, rett ned. Tomme bokser gir best mål; svarte og blanke flater ser LiDAR dårlig.")
                        .font(.footnote)
                    Text("3D-skann («Skann ting») gir formen med noen millimeters nøyaktighet – godt nok til holdere og lommer, ikke til stramme passformer. Mål hull og kanter som må passe med Hull-modus.")
                        .font(.footnote)
            }
        }
        .navigationTitle("Slik måler appen")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// «Størrelse i 3D-skann»: what the phone has learnt from caliper corrections, and a way to forget it.
struct PhoneScaleSection: View {
    @State private var scale = PhoneScaleStore.load()

    var body: some View {
        Section {
            if let f = scale.factor {
                LabeledContent("Retting", value: String(format: "%+.1f %%", (f - 1) * 100).replacingOccurrences(of: ".", with: ","))
                LabeledContent("Fra", value: "\(scale.samples.count) rettinger med skyvelære")
                if let sp = scale.spread {
                    LabeledContent("Sprik", value: String(format: "%.1f %%", sp * 100).replacingOccurrences(of: ".", with: ","))
                }
                Button("Glem rettingen", role: .destructive) {
                    PhoneScaleStore.reset()
                    scale = PhoneScaleStore.load()
                }
            } else {
                Text(scale.samples.count == 1 ? "Én retting så langt – trenger to." : "Ingen rettinger ennå.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Størrelse i 3D-skann")
        } footer: {
            Text("Når du retter et skann etter skyvelæren, lærer telefonen hvor mye den bommer, og retter neste skann av seg selv. Lite sprik betyr at rettingen holder.")
        }
    }
}
