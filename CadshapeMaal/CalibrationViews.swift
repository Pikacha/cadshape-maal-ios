import HoleKit
import SwiftUI

/// The bottom panel while the phone is calibrated with CadSHAPE's printed calibration plate.
struct CalibrationContent: View {
    @ObservedObject var model: MeasureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let step = model.calibrationStep {
                HStack {
                    Text("Kalibrering \(step + 1) av \(calibrationHolesMM.count)").font(.footnote.weight(.semibold)).opacity(0.75)
                    Spacer()
                    Button("Avbryt") { model.cancelCalibration() }.font(.footnote.weight(.semibold))
                }
                Text("Hullet merket \(Int(calibrationHolesMM[step]))")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    ForEach(calibrationHolesMM.indices, id: \.self) { i in
                        Circle()
                            .fill(i < step ? (model.calibrationSamples[i] == nil ? Color.white.opacity(0.3) : good) : (i == step ? accent : Color.white.opacity(0.15)))
                            .frame(width: 10, height: 10)
                    }
                }
                if let d = model.calibrationReading {
                    Text("Telefonen måler Ø \(mm(d, digits: 2)) mm").font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                SteadyBar(value: model.steadiness)
                Text(model.calibrationBlocker ?? "Stødig – trykk «Bruk».")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(model.calibrationBlocker == nil ? good : accent)
                HStack(spacing: 10) {
                    Button { model.skipCalibrationSample() } label: { Label("Hopp over", systemImage: "forward.fill") }
                        .buttonStyle(SecondaryStyle())
                    Button { model.takeCalibrationSample() } label: { Label("Bruk", systemImage: "checkmark.circle.fill") }
                        .buttonStyle(PrimaryStyle(enabled: model.calibrationBlocker == nil))
                        .disabled(model.calibrationBlocker != nil)
                }
                Text("Legg platen flatt på et lyst bord i godt lys. Hold telefonen 25–40 cm over, rett ned.")
                    .font(.footnote).opacity(0.7)
            } else if let result = model.calibrationResult {
                switch result {
                case .success(let c):
                    Label("Kalibreringen ble god", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(good)
                    Text(calibrationSummary(c)).font(.subheadline).monospacedDigit()
                    Text(example(c)).font(.footnote).opacity(0.8)
                    HStack(spacing: 10) {
                        Button { model.startCalibration() } label: { Label("Mål på nytt", systemImage: "arrow.counterclockwise") }
                            .buttonStyle(SecondaryStyle())
                        Button { model.keepCalibration() } label: { Label("Bruk kalibreringen", systemImage: "checkmark.circle.fill") }
                            .buttonStyle(PrimaryStyle())
                    }
                case .failure(let problem):
                    Label("Kalibreringen ble ikke god nok", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(accent)
                    Text(problem.message).font(.subheadline)
                    HStack(spacing: 10) {
                        Button { model.cancelCalibration() } label: { Text("Avbryt") }
                            .buttonStyle(SecondaryStyle())
                        Button { model.startCalibration() } label: { Label("Prøv igjen", systemImage: "arrow.counterclockwise") }
                            .buttonStyle(PrimaryStyle())
                    }
                }
            }
        }
    }

    private func example(_ c: HoleCalibration) -> String {
        let raw = (23 - c.offsetMM) / c.scale
        return "Eksempel: telefonen målte Ø \(mm(raw, digits: 2)) på 23-hullet, rettet blir det Ø 23,0."
    }
}

func calibrationSummary(_ c: HoleCalibration) -> String {
    let pct = (c.scale - 1) * 100
    let sign = c.offsetMM >= 0 ? "+" : "−"
    return "Størrelse \(pct >= 0 ? "+" : "−")\(mm(abs(pct), digits: 1)) %, kant \(sign)\(mm(abs(c.offsetMM), digits: 2)) mm · \(c.samples) hull, ± \(mm(c.rmsMM, digits: 2)) mm"
}

/// Two clear edges were seen round the locked hole: let the user say which one is the hole.
struct EdgeChoiceView: View {
    @ObservedObject var model: MeasureModel

    var body: some View {
        if let e = model.edgeChoices {
            VStack(alignment: .leading, spacing: 8) {
                Label("To kanter rundt hullet", systemImage: "circle.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
                Text("Den ytre kan være skygge, fas eller en knust kant. Velg kanten der hullet faktisk begynner – mål gjerne med linjal.")
                    .font(.footnote).opacity(0.8)
                HStack(spacing: 8) {
                    Button("Indre Ø \(mm(e.inner))") { if !e.usingInner { model.useOtherEdge() } }
                        .buttonStyle(ChipStyle(on: e.usingInner))
                    Button("Ytre Ø \(mm(e.outer))") { if e.usingInner { model.useOtherEdge() } }
                        .buttonStyle(ChipStyle(on: !e.usingInner))
                }
                .disabled(model.working)
            }
        }
    }
}

/// Settings: calibrate the phone with the plate, see and remove the calibration.
struct CalibrationSection: View {
    @ObservedObject var model: MeasureModel

    var body: some View {
        Section {
            if let c = model.calibration {
                LabeledContent("Kalibrert", value: c.date.formatted(date: .abbreviated, time: .omitted))
                Text(calibrationSummary(c)).font(.footnote).monospacedDigit()
                Button("Fjern kalibreringen", role: .destructive) { model.removeCalibration() }
            } else {
                Text("Ikke kalibrert. Hullmål bruker kameraets egne verdier.").font(.footnote)
            }
            Button {
                model.startCalibration()
            } label: {
                Label(model.calibration == nil ? "Kalibrer med kalibreringsplaten" : "Kalibrer på nytt", systemImage: "scope")
            }
        } header: {
            Text("Kalibrering")
        } footer: {
            Text("Lag «Kalibreringsplate for telefonen» i CadSHAPE (Ctrl+K), print den (ca. 15 min) og mål de fem hullene. Appen lærer hvor mye den måler for stort eller smått og hvor kanten havner, og retter hullmålene etterpå. Mål helst platen med skyvelære: printede hull blir ofte 0,1–0,2 mm mindre enn tegnet.")
        }
    }
}

/// «CadSHAPE Mål 1.1 (2)».
var appVersionText: String {
    let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    return "Versjon \(v) (\(b))"
}
