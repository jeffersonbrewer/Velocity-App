import SwiftUI
import VelocityCore

/// Edit one exercise's target mean-velocity zone and velocity-loss cutoff.
struct TargetsSheet: View {
    let exerciseID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.velocityLossCutoff) private var defaultCutoff = 20.0
    @State private var useZone = false
    @State private var low = 0.65
    @State private var high = 0.80
    @State private var useOwnCutoff = false
    @State private var cutoff = 20.0

    private var exercise: Exercise? { ExerciseCatalog.exercise(id: exerciseID) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Use a target zone", isOn: $useZone)
                    if useZone {
                        Stepper(value: $low, in: 0.1...(high - 0.05), step: 0.05) {
                            row("From", String(format: "%.2f m/s", low))
                        }
                        Stepper(value: $high, in: (low + 0.05)...2.0, step: 0.05) {
                            row("To", String(format: "%.2f m/s", high))
                        }
                    }
                } header: { Text("Mean velocity zone") } footer: {
                    Text("Reps outside the zone are flagged on the set results.")
                }

                Section {
                    Toggle("Own cutoff for this exercise", isOn: $useOwnCutoff)
                    if useOwnCutoff {
                        Stepper(value: $cutoff, in: 0...50, step: 5) {
                            row("Stop the set at", cutoff > 0 ? Fmt.percent(cutoff) + " loss" : "No cutoff")
                        }
                    } else {
                        row("Default from Settings", defaultCutoff > 0 ? Fmt.percent(defaultCutoff) : "Off")
                    }
                } header: { Text("Velocity-loss cutoff") }

                if let ex = exercise, ex.bodyMassFraction > 0 {
                    Section {
                        row("Body mass counted", "\(Int(ex.bodyMassFraction * 100))%")
                    } header: { Text("System power") }
                }
            }
            .navigationTitle(exercise?.name ?? "Targets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save(); dismiss() } }
            }
            .onAppear(perform: load)
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(Theme.muted).monospacedDigit() }
    }

    private func load() {
        let p = model.prefs(for: exerciseID)
        if let zone = p.targetZone { useZone = true; low = zone.lowerBound; high = zone.upperBound }
        if let c = p.lossCutoffPct { useOwnCutoff = true; cutoff = c } else { cutoff = defaultCutoff }
    }

    private func save() {
        var p = model.prefs(for: exerciseID)
        p.targetLow = useZone ? low : nil
        p.targetHigh = useZone ? high : nil
        p.lossCutoffPct = useOwnCutoff ? cutoff : nil
        model.prefs[exerciseID] = p
    }
}
