import SwiftUI
import VelocityCore

/// Plan a guided profile test: pick the exercise and a rough 1RM, check the loads, then record
/// the whole ramp without leaving the camera.
struct ProfileTestSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.unit) private var unitRaw = WeightUnit.lb.rawValue
    @State private var exerciseID: String
    @State private var oneRmKg = 100.0
    @State private var loadCount = 5
    @State private var maxSingle = false
    @State private var plan: ProfileTestPlan?
    @State private var running: ProfileTestPlan?

    init(exerciseID: String) { _exerciseID = State(initialValue: exerciseID) }

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .lb }
    private var exercise: Exercise? { ExerciseCatalog.exercise(id: exerciseID) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Exercise", selection: $exerciseID) {
                        ForEach(ExerciseCatalog.all) { Text($0.name).tag($0.id) }
                    }
                    LoadField(loadKg: $oneRmKg, unit: unit, label: "Rough 1RM")
                    Stepper(value: $loadCount, in: 4...6) {
                        HStack { Text("Loads"); Spacer(); Text("\(loadCount)").monospacedDigit() }
                    }
                    Toggle("Finish with a max single", isOn: $maxSingle)
                } footer: {
                    Text("A best guess at the 1RM is fine: it only sets the loads, and the test measures the real thing. The ramp runs from about 40% to 90%. A max single is an all-out heavy rep that gives your own 1RM velocity; skip it if you aren't ready for a true max.")
                }

                if let plan {
                    Section {
                        ForEach(Array(plan.steps.enumerated()), id: \.element.id) { i, step in
                            HStack {
                                Text("\(i + 1)").foregroundStyle(Theme.muted).frame(width: 18)
                                LoadField(loadKg: loadBinding(i), unit: unit,
                                          label: step.isMaxSingle ? "Max single" : "\(step.reps) rep\(step.reps == 1 ? "" : "s")")
                            }
                        }
                    } header: { Text("Plan") } footer: {
                        Text("Lift every rep as fast as you can, with 2–3 minutes rest between loads. Change any load to match the plates you have.")
                    }
                }

                Section {
                    Button {
                        running = plan
                    } label: {
                        Label("Set up camera and start", systemImage: "video.fill").frame(maxWidth: .infinity).fontWeight(.semibold)
                    }
                    .disabled(plan == nil)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .keyboardDoneButton()
            .navigationTitle("Profile test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { oneRmKg = startingOneRm(); rebuild() }
            .onChange(of: exerciseID) { _, _ in oneRmKg = startingOneRm(); rebuild() }
            .onChange(of: oneRmKg) { _, _ in rebuild() }
            .onChange(of: loadCount) { _, _ in rebuild() }
            .onChange(of: maxSingle) { _, _ in rebuild() }
            .onChange(of: unitRaw) { _, _ in rebuild() }
            .fullScreenCover(item: $running, onDismiss: { dismiss() }) { plan in
                CameraSetupView(test: plan)
            }
        }
    }

    private func loadBinding(_ i: Int) -> Binding<Double> {
        Binding(get: { plan?.steps[i].loadKg ?? 0 }, set: { plan?.steps[i].loadKg = $0 })
    }

    private func rebuild() {
        plan = ProfileTestPlan.make(exerciseID: exerciseID, oneRmKg: oneRmKg, loads: loadCount, maxSingle: maxSingle, unit: unit)
    }

    /// The last estimate, else the heaviest load lifted for this exercise treated as about 85%, else a guess from the next-set load.
    private func startingOneRm() -> Double {
        if let orm = model.profile(for: exerciseID).oneRmKg { return unit.roundedToStep(kg: orm) }
        if let heaviest = model.sets.filter({ $0.exerciseID == exerciseID }).map(\.analysis.input.loadKg).max(), heaviest > 0 {
            return unit.roundedToStep(kg: heaviest / 0.85)
        }
        return unit.roundedToStep(kg: max(40, model.prefs(for: exerciseID).loadKg / 0.7))
    }
}
