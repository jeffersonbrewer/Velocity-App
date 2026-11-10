import SwiftUI
import VelocityCore

/// Tell the app what was lifted, then analyze the clip.
struct SetDetailsView: View {
    let clip: Clip
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.unit) private var unitRaw = WeightUnit.lb.rawValue
    @AppStorage(SettingsKey.bodyMassKg) private var bodyMassKg = 0.0
    @State private var setType: SetType = .working
    @State private var job: Task<Void, Never>?
    @State private var progress: VideoTracker.Progress?
    @State private var errorText: String?
    @State private var resultID: UUID?

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .lb }
    private var exercise: Exercise { ExerciseCatalog.exercise(id: model.currentExerciseID) ?? ExerciseCatalog.all[0] }

    var body: some View {
        Form {
            Section {
                Text(clip.name).foregroundStyle(Theme.muted)
            } header: { Text("Video") }

            Section {
                Picker("Exercise", selection: model.exerciseBinding) {
                    ForEach(ExerciseCatalog.all) { Text($0.name).tag($0.id) }
                }
                LoadField(loadKg: model.loadBinding(model.currentExerciseID), unit: unit)
                Picker("Set type", selection: $setType) {
                    ForEach(SetType.allCases) { Text($0.rawValue).tag($0) }
                }
            } header: { Text("Set") } footer: {
                Text("Load is everything on the bar, including the bar itself. Only Profile test and Max single sets will be used for your strength profile.")
            }

            if exercise.bodyMassFraction > 0 {
                Section {
                    BodyMassField(bodyMassKg: $bodyMassKg, unit: unit)
                } header: { Text("Body mass") } footer: {
                    Text("Used for system power (bar plus \(Int(exercise.bodyMassFraction * 100))% of body mass). Leave at 0 to show bar power only.")
                }
            }

            Section {
                if let progress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress.fraction)
                        HStack(spacing: 6) {
                            Circle().fill(progress.plateFound ? Theme.good : Theme.warn).frame(width: 8, height: 8)
                            Text(progress.plateFound ? "Tracking the plate…" : "Looking for the plate…")
                                .font(.footnote).foregroundStyle(Theme.muted)
                        }
                    }
                    Button("Cancel", role: .cancel) { job?.cancel() }
                } else {
                    Button {
                        start()
                    } label: {
                        Text("Analyze set").frame(maxWidth: .infinity).fontWeight(.semibold)
                    }
                }
                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(Theme.bad)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Set details")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $resultID) { id in SetResultsView(setID: id) }
        .onDisappear { job?.cancel() }
    }

    private func start() {
        errorText = nil
        progress = VideoTracker.Progress(fraction: 0, plateFound: false)
        let id = model.currentExerciseID
        let input = model.setInput(exerciseID: id, loadKg: model.prefs(for: id).loadKg)
        let settings = SettingsKey.analysisSettings()
        let asset = clip.asset
        let type = setType, name = clip.name, filmed = clip.date ?? Date()
        job = Task {
            do {
                let analysis = try await Task.detached(priority: .userInitiated) {
                    let track = try await VideoTracker.track(asset) { p in
                        Task { @MainActor in progress = p }
                    }
                    return try SetAnalyzer.analyze(track: track, input: input, settings: settings)
                }.value
                let set = AnalyzedSet(date: filmed, clipName: name, setType: type, analysis: analysis)
                model.add(set)
                progress = nil
                resultID = set.id
            } catch is CancellationError {
                progress = nil
            } catch {
                progress = nil
                errorText = error.localizedDescription
            }
        }
    }
}

/// Load entry: type it or step it by 2.5 kg / 5 lb. The field grows with its text so decimals
/// such as 102.5 are never cut off.
struct LoadField: View {
    @Binding var loadKg: Double
    let unit: WeightUnit

    var body: some View {
        let shown = Binding<Double>(
            get: { (unit.fromKg(loadKg) * 100).rounded() / 100 },
            set: { loadKg = unit.toKg($0) })
        HStack {
            Text("Load")
            Spacer()
            Button { loadKg = max(0, unit.toKg(shown.wrappedValue - unit.step)) } label: { Image(systemName: "minus") }
                .buttonStyle(.bordered)
                .accessibilityLabel("Decrease load")
            TextField("Load", value: shown, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .font(.title3.weight(.semibold).monospacedDigit())
                .fixedSize()
                .frame(minWidth: 44)
            Text(unit.rawValue).foregroundStyle(Theme.muted)
            Button { loadKg = unit.toKg(shown.wrappedValue + unit.step) } label: { Image(systemName: "plus") }
                .buttonStyle(.bordered)
                .accessibilityLabel("Increase load")
        }
    }
}

struct BodyMassField: View {
    @Binding var bodyMassKg: Double
    let unit: WeightUnit

    var body: some View {
        let shown = Binding<Double>(
            get: { (unit.fromKg(bodyMassKg) * 10).rounded() / 10 },
            set: { bodyMassKg = unit.toKg($0) })
        HStack {
            Text("Body mass")
            Spacer()
            TextField("0", value: shown, format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .fixedSize()
                .frame(minWidth: 44)
            Text(unit.rawValue).foregroundStyle(Theme.muted)
        }
    }
}
