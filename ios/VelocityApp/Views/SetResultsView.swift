import Charts
import SwiftUI
import VelocityCore

/// Results for one set: headline numbers, velocity by rep, velocity loss and a table of reps.
/// Peak values carry a Beta tag until they are validated against GymAware.
struct SetResultsView: View {
    let setID: UUID
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.unit) private var unitRaw = WeightUnit.lb.rawValue
    @State private var showPeak = false
    @State private var systemPower = false
    @State private var editingRep: EditableRep?

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .lb }

    var body: some View {
        if let set = model.recentSets.first(where: { $0.id == setID }) {
            content(set)
        } else {
            ContentUnavailableView("Set not found", systemImage: "questionmark")
        }
    }

    @ViewBuilder
    private func content(_ set: AnalyzedSet) -> some View {
        let a = set.analysis
        let m = a.setMetrics
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(a.input.exercise.name) · \(unit.format(kg: a.input.loadKg)) \(unit.rawValue) × \(m?.repCount ?? 0)")
                    .foregroundStyle(Theme.muted)

                ForEach(a.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.warn)
                }

                if let m {
                    tiles(m)
                    byRepCard(m)
                    if let cutoff = m.velocityLossThresholdPct { lossCard(m, cutoff: cutoff) }
                    repTable(set, m)
                    BetaNote()
                    detailsCard(a)
                } else {
                    Card {
                        Text("No reps were found.").font(.headline)
                        Text("Check that the whole plate is visible from the side for the full set, and that the exercise is right.")
                            .font(.subheadline).foregroundStyle(Theme.muted)
                    }
                    if !a.reps.isEmpty { repTable(set, nil) }
                }
            }
            .padding()
        }
        .background(Theme.background)
        .navigationTitle(set.setType == .working ? "Set results" : set.setType.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: CSVExport.csv(for: set, unit: unit),
                          preview: SharePreview("\(a.input.exercise.name) reps.csv")) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Export reps as CSV")
            }
        }
        .sheet(item: $editingRep) { rep in
            RepEditSheet(analysis: a, rep: rep) { updated in
                var s = set
                if let i = s.analysis.reps.firstIndex(where: { $0.id == updated.id }) { s.analysis.reps[i] = updated }
                model.update(s)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func tiles(_ m: SetMetrics) -> some View {
        HStack(spacing: 12) {
            Card {
                CardLabel(text: "Mean velocity")
                BigNumber(value: Fmt.velocity(m.meanVelocity), unit: "m/s")
            }
            Card {
                HStack(spacing: 6) { CardLabel(text: "Best peak"); BetaBadge() }
                BigNumber(value: Fmt.velocity(m.peakVelocity), unit: "m/s")
            }
        }
    }

    private func byRepCard(_ m: SetMetrics) -> some View {
        Card {
            HStack {
                CardLabel(text: showPeak ? "Peak by rep" : "Mean by rep")
                if showPeak { BetaBadge() }
                Spacer()
                Picker("Velocity shown", selection: $showPeak) {
                    Text("Mean").tag(false)
                    Text("Peak").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
            }
            Chart(m.reps, id: \.rep) { r in
                BarMark(x: .value("Rep", String(r.rep)),
                        y: .value("m/s", showPeak ? r.peakVelocity : r.meanVelocity))
                    .foregroundStyle(showPeak ? Theme.warn.opacity(0.8) : Theme.accent)
                    .annotation(position: .top) {
                        Text(Fmt.velocity(showPeak ? r.peakVelocity : r.meanVelocity))
                            .font(.caption2.monospacedDigit()).foregroundStyle(Theme.muted)
                    }
            }
            .chartYAxisLabel("m/s")
            .frame(height: 160)
        }
    }

    private func lossCard(_ m: SetMetrics, cutoff: Double) -> some View {
        let loss = max(m.velocityLossPct, 0)
        let color = loss >= cutoff ? Theme.bad : (loss >= cutoff * 0.75 ? Theme.warn : Theme.good)
        return Card {
            HStack {
                CardLabel(text: "Velocity loss")
                Spacer()
                Text(Fmt.percent(loss)).fontWeight(.bold).monospacedDigit()
                Text("of \(Fmt.percent(cutoff)) cutoff").foregroundStyle(Theme.muted)
            }
            GeometryReader { geo in
                let scale = max(cutoff * 1.25, loss)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line)
                    Capsule().fill(color).frame(width: geo.size.width * min(loss / scale, 1))
                    Rectangle().fill(.white).frame(width: 2).offset(x: geo.size.width * cutoff / scale - 1)
                }
            }
            .frame(height: 8)
            if let rep = m.thresholdReachedAtRep {
                Text("Cutoff reached at rep \(rep).").font(.footnote).foregroundStyle(Theme.muted)
            }
        }
    }

    private func repTable(_ set: AnalyzedSet, _ m: SetMetrics?) -> some View {
        let a = set.analysis
        let metricsByID = Dictionary(uniqueKeysWithValues: zip(a.reps.filter { !$0.deleted }.map(\.id), m?.reps ?? []))
        let hasSystem = m?.systemMeanPower != nil
        return Card {
            HStack {
                CardLabel(text: "Each rep")
                Spacer()
                if hasSystem {
                    Picker("Power shown", selection: $systemPower) {
                        Text("Bar").tag(false)
                        Text("System").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }
            }
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Rep").gridColumnAlignment(.leading)
                    Text("MV")
                    HStack(spacing: 2) { Text("PV"); Text("β").foregroundStyle(Theme.warn) }
                    Text("MP W")
                    HStack(spacing: 2) { Text("PP W"); Text("β").foregroundStyle(Theme.warn) }
                    Text("Up m")
                    Text("Down m")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.muted)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(a.reps) { rep in
                    let r = metricsByID[rep.id]
                    GridRow {
                        Text(r.map { "\($0.rep)" } ?? "–").gridColumnAlignment(.leading)
                        Text(Fmt.velocity(r?.meanVelocity)).fontWeight(.semibold)
                        Text(Fmt.velocity(r?.peakVelocity))
                        Text(Fmt.watts(systemPower ? r?.systemMeanPower : r?.meanPower))
                        Text(Fmt.watts(systemPower ? r?.systemPeakPower : r?.peakPower))
                        Text(Fmt.meters(r?.concentricDistance))
                        Text(Fmt.meters(r?.eccentricDistance))
                    }
                    .font(.footnote.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .strikethrough(rep.deleted)
                    .foregroundStyle(rep.deleted ? Theme.muted : .primary)
                    .contentShape(Rectangle())
                    .onTapGesture { editingRep = rep }
                }
            }
            Text("Tap a rep to adjust where it starts and ends, or to delete or restore it.")
                .font(.caption).foregroundStyle(Theme.muted)
        }
    }

    private func detailsCard(_ a: SetAnalysis) -> some View {
        Card {
            CardLabel(text: "Analysis details")
            detail("Frame rate", String(format: "%.0f fps average (analyzed on a %.0f Hz grid)", a.track.fps, a.kinematics.fps))
            detail("Plate radius", String(format: "%.0f px, roundness %.2f", a.track.radiusPx, a.track.roundness))
            detail("Scale", String(format: "%.3f mm per pixel", a.kinematics.metersPerPixel * 1000))
            detail("Plate lost", String(format: "%.1f%% of frames", a.track.lostFraction * 100))
            detail("Filter", String(format: "%.1f Hz low-pass", a.settings.cutoffHz))
            detail("Tilt correction", a.settings.tiltCorrection ? "On" : "Off")
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(Theme.muted)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.footnote)
    }
}

struct BigNumber: View {
    let value: String
    let unit: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
            Text(unit).font(.subheadline).foregroundStyle(Theme.muted)
        }
    }
}

/// Per-rep numbers as CSV, for checking against GymAware in a spreadsheet.
enum CSVExport {
    static func csv(for set: AnalyzedSet, unit: WeightUnit) -> String {
        let a = set.analysis
        var lines = ["exercise,load_\(unit.rawValue),set_type,rep,mean_velocity,mean_propulsive_velocity,peak_velocity_beta,mean_power_w,peak_power_w_beta,system_mean_power_w,system_peak_power_w_beta,concentric_m,eccentric_m,concentric_s"]
        for r in a.setMetrics?.reps ?? [] {
            func f(_ v: Double?, _ fmt: String = "%.3f") -> String { v.map { String(format: fmt, $0) } ?? "" }
            lines.append([a.input.exercise.name, unit.format(kg: a.input.loadKg), set.setType.rawValue, "\(r.rep)",
                          f(r.meanVelocity), f(r.meanPropulsiveVelocity), f(r.peakVelocity),
                          f(r.meanPower, "%.0f"), f(r.peakPower, "%.0f"), f(r.systemMeanPower, "%.0f"), f(r.systemPeakPower, "%.0f"),
                          f(r.concentricDistance), f(r.eccentricDistance), f(r.concentricDuration)].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
