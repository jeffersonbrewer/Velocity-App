import Charts
import SwiftUI
import VelocityCore

/// Strength profile for one exercise: load-velocity line and estimated 1RM from tagged
/// Profile test and Max single sets only, today's readiness, and a retest reminder.
struct ProfileView: View {
    let exerciseID: String
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.unit) private var unitRaw = WeightUnit.lb.rawValue
    @State private var editingMvt = false
    @State private var testing = false

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .lb }
    private var exercise: Exercise? { ExerciseCatalog.exercise(id: exerciseID) }

    var body: some View {
        let p = model.profile(for: exerciseID)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let reason = p.retestReason() { retestCard(reason, hasTest: p.lastTestDate != nil) }
                lineCard(p)
                if let r = model.readinessToday(for: exerciseID) { readinessCard(r) }
                if exercise?.allowsOneRm != false {
                    Card {
                        CardLabel(text: "1RM tested outside the app")
                        KnownOneRmField(exerciseID: exerciseID, unit: unit, explicitSave: true)
                        Text("Lets the Program use this lift before its first profile test. Whichever is newer, this or your last profile test, sets the program's loads. Type it and tap Save. Set it to 0 and Save to remove it.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                if !p.testSets.isEmpty { testSetsCard(p) }
                howToCard
            }
            .padding()
        }
        .background(Theme.background)
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneButton()
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("Profile").font(.headline)
                    Text(exercise?.name ?? "").font(.caption).foregroundStyle(Theme.muted)
                }
            }
        }
        .sheet(isPresented: $editingMvt) { MvtSheet(exerciseID: exerciseID) }
        .sheet(isPresented: $testing) { ProfileTestSetupView(exerciseID: exerciseID) }
    }

    // MARK: Cards

    private func retestCard(_ reason: String, hasTest: Bool) -> some View {
        Card {
            HStack {
                Text(hasTest ? "Time to retest" : "No profile yet").font(.headline)
                Spacer()
                if hasTest { Pill(text: "4 weeks", color: Theme.warn) }
            }
            Text(hasTest ? "\(reason) A new one at the start of your next session keeps your loads and 1RM estimate current."
                         : "Record a profile test to see your load-velocity line and estimated 1RM.")
                .font(.subheadline).foregroundStyle(Theme.muted)
            Button {
                testing = true
            } label: {
                Text("Start a guided profile test").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.warn.opacity(hasTest ? 0.5 : 0)))
    }

    private func lineCard(_ p: StrengthProfile) -> some View {
        Card {
            HStack {
                CardLabel(text: "Load–velocity profile")
                Spacer()
                if let d = p.testDate {
                    Text("\(d.formatted(.dateTime.month(.abbreviated).day())) test").font(.caption).foregroundStyle(Theme.muted)
                }
            }
            if let line = p.line {
                chart(p, line: line)
                if exercise?.allowsOneRm == false {
                    Text("No 1RM is estimated for Olympic lifts: their velocity at a true max varies too much to rely on.")
                        .font(.footnote).foregroundStyle(Theme.muted)
                } else {
                    row("Estimated 1RM", p.oneRmKg.map { "\(unit.format(kg: unit.roundedToStep(kg: $0))) \(unit.rawValue)" } ?? "–", bold: true)
                }
                row("Line", String(format: "MV = %.2f %@ %.4f × load (%@)", line.intercept, line.slope < 0 ? "−" : "+",
                                   abs(line.slope) / unit.fromKg(1), unit.rawValue))
                row("Fit", String(format: "R² %.2f · %d loads", line.r2, line.loadCount))
            } else {
                Text(p.lineProblem ?? "No profile test yet.").font(.subheadline).foregroundStyle(Theme.muted)
            }
            if exercise?.allowsOneRm != false { mvtRow(p) }
            ForEach(p.notes, id: \.self) { n in
                Label(n, systemImage: "info.circle").font(.footnote).foregroundStyle(Theme.warn)
            }
            Text("Only sets you tag as Profile test or Max single change this page.")
                .font(.caption).foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder
    private func mvtRow(_ p: StrengthProfile) -> some View {
        HStack {
            Text("Your 1RM velocity").foregroundStyle(Theme.muted)
            Spacer()
            Text(p.mvt.map { "\(Fmt.velocity($0)) m/s" } ?? "–").monospacedDigit().fontWeight(.semibold)
            Button("Edit") { editingMvt = true }.font(.subheadline)
        }
        .font(.subheadline)
        Text(mvtSourceText(p)).font(.caption).foregroundStyle(Theme.muted)
    }

    private func mvtSourceText(_ p: StrengthProfile) -> String {
        let def = exercise?.defaultMvt.map { "group default \(Fmt.velocity($0)) m/s" }
        switch p.mvtSource {
        case .measured(let d):
            return "From your slowest Max single on \(d.formatted(.dateTime.month(.abbreviated).day()))" + (def.map { " (\($0))." } ?? ".")
        case .edited:
            return "Your own value" + (def.map { " (\($0))" } ?? "") + ". A Max single replaces it."
        case .groupDefault:
            return "Group average: \(exercise?.mvtSource ?? ""). Record a Max single to use your own."
        case nil:
            return "No published 1RM velocity for this exercise. Record a Max single, or set one with Edit."
        }
    }

    private func chart(_ p: StrengthProfile, line: LoadVelocityLine) -> some View {
        let lo = line.minLoadKg * 0.9
        let hi = max(line.maxLoadKg, p.oneRmKg ?? line.maxLoadKg) * 1.03
        return Chart {
            ForEach([lo, hi], id: \.self) { kg in
                LineMark(x: .value("Load", unit.fromKg(kg)), y: .value("m/s", line.velocity(atLoad: kg)))
                    .foregroundStyle(Theme.accent.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
            if let mvt = p.mvt {
                RuleMark(y: .value("1RM velocity", mvt))
                    .foregroundStyle(Theme.warn.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            ForEach(Array(p.testSets.enumerated()), id: \.offset) { _, s in
                PointMark(x: .value("Load", unit.fromKg(s.loadKg)), y: .value("m/s", s.bestMeanVelocity))
                    .foregroundStyle(s.isMaxSingle ? Theme.warn : Theme.accent)
            }
            if let orm = p.oneRmKg, let mvt = p.mvt {
                PointMark(x: .value("Load", unit.fromKg(orm)), y: .value("m/s", mvt))
                    .symbol(.diamond)
                    .symbolSize(90)
                    .foregroundStyle(Theme.good)
                    .annotation(position: .top, alignment: .trailing) {
                        Text("1RM").font(.caption2.weight(.semibold)).foregroundStyle(Theme.good)
                    }
            }
        }
        .chartXScale(domain: unit.fromKg(lo)...unit.fromKg(hi))
        .chartXAxisLabel(unit.rawValue)
        .chartYAxisLabel("m/s")
        .frame(height: 190)
        .accessibilityLabel(p.oneRmKg.map { "Mean velocity falls as load rises, projecting an estimated 1RM of \(unit.format(kg: $0)) \(unit.rawValue)" }
                            ?? "Mean velocity against load")
    }

    private func readinessCard(_ r: (set: AnalyzedSet, expected: Double, delta: Double, reading: Readiness)) -> some View {
        Card {
            CardLabel(text: "Readiness today")
            row("First set at \(unit.format(kg: r.set.analysis.input.loadKg)) \(unit.rawValue)",
                "\(Fmt.velocity(r.set.analysis.setMetrics?.bestMeanVelocity)) m/s")
            row("Profile says", "\(Fmt.velocity(r.expected)) m/s")
            HStack {
                Pill(text: "\(r.reading.rawValue) day", color: readinessColor(r.reading))
                Text(String(format: "%+.2f m/s", r.delta)).font(.subheadline).monospacedDigit().foregroundStyle(Theme.muted)
            }
        }
    }

    private func testSetsCard(_ p: StrengthProfile) -> some View {
        Card {
            CardLabel(text: "Sets in this test")
            ForEach(Array(p.testSets.enumerated()), id: \.offset) { _, s in
                row("\(unit.format(kg: s.loadKg)) \(unit.rawValue)\(s.isMaxSingle ? " · Max single" : "")",
                    "\(Fmt.velocity(s.bestMeanVelocity)) m/s")
            }
            Text("Each set counts by its fastest rep.").font(.caption).foregroundStyle(Theme.muted)
        }
    }

    private var howToCard: some View {
        Card {
            CardLabel(text: "How to test")
            Text("After your warm-up, do 1–3 fast reps at 4–6 loads rising from light to about 85–90% of your max, with full rest. Tag each one Profile test. Finish with a heavy single tagged Max single if you want your own 1RM velocity. Retest every 4 weeks or at the end of a training block.")
                .font(.subheadline).foregroundStyle(Theme.muted)
            Button { testing = true } label: {
                Label("Start a guided profile test", systemImage: "chart.line.downtrend.xyaxis").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Text("The guided test plans the loads and keeps the camera running from the first load to the last. You can also retag a set you already recorded with the tag button on its results.")
                .font(.caption).foregroundStyle(Theme.muted)
        }
    }

    // MARK: Helpers

    private func row(_ label: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.muted)
            Spacer()
            Text(value).monospacedDigit().fontWeight(bold ? .bold : .regular)
        }
        .font(bold ? .body : .subheadline)
    }
}

func readinessColor(_ r: Readiness) -> Color {
    switch r {
    case .veryGood, .good, .normal: return Theme.good
    case .slightlyDown, .down: return Theme.warn
    case .wellDown: return Theme.bad
    }
}

struct Pill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(color)
            .overlay(Capsule().stroke(color))
    }
}

/// Change the 1RM velocity used when no Max single has been recorded.
struct MvtSheet: View {
    let exerciseID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var value = 0.30

    private var exercise: Exercise? { ExerciseCatalog.exercise(id: exerciseID) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $value, in: 0.05...1.0, step: 0.01) {
                        HStack { Text("1RM velocity"); Spacer(); Text(String(format: "%.2f m/s", value)).monospacedDigit() }
                    }
                    if let d = exercise?.defaultMvt {
                        Button("Use group default (\(Fmt.velocity(d)) m/s)") {
                            var p = model.prefs(for: exerciseID); p.editedMvt = nil; model.prefs[exerciseID] = p
                            dismiss()
                        }
                    }
                } footer: {
                    Text("The mean velocity of a true 1RM. \(exercise?.mvtSource ?? "") Once you record a Max single, your measured value is used instead.")
                }
            }
            .navigationTitle(exercise?.name ?? "1RM velocity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var p = model.prefs(for: exerciseID); p.editedMvt = value; model.prefs[exerciseID] = p
                        dismiss()
                    }
                }
            }
            .onAppear { value = model.prefs(for: exerciseID).editedMvt ?? exercise?.defaultMvt ?? 0.30 }
        }
        .presentationDetents([.medium])
    }
}
