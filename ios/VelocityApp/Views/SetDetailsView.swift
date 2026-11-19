import SwiftUI
import VelocityCore

/// Tell the app what was lifted, then analyze the clip.
struct SetDetailsView: View {
    let clip: Clip
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.unit) private var unitRaw = WeightUnit.lb.rawValue
    @AppStorage(SettingsKey.bodyMassKg) private var bodyMassKg = 0.0
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
                Picker("Set type", selection: model.nextSetTypeBinding) {
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
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneButton()
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
        let type = model.nextSetType, name = clip.name, filmed = clip.date ?? Date()
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

/// A number typed on the decimal pad. It keeps its own text while you type (so a field can be
/// cleared, and "102." keeps its point) and passes each valid number on; it shows the value
/// formatted again once you leave it. A cleared field counts as 0.
struct NumberField: View {
    @Binding var value: Double
    var fractionDigits = 2
    var placeholder = "0"
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(.decimalPad)
            .focused($focused)
            .onAppear { text = Self.format(value, fractionDigits) }
            .onChange(of: value) { _, v in if !focused { text = Self.format(v, fractionDigits) } }
            .onChange(of: text) { _, t in
                guard focused, let v = Self.parse(t) else { return }
                if v != value { value = v }
            }
            .onChange(of: focused) { _, f in
                guard !f else { return }
                if text.trimmingCharacters(in: .whitespaces).isEmpty { value = 0 }
                text = Self.format(value, fractionDigits)
            }
    }

    static func format(_ v: Double, _ digits: Int) -> String {
        v.formatted(.number.precision(.fractionLength(0...digits)).grouping(.never))
    }

    static func parse(_ t: String) -> Double? {
        let sep = Locale.current.decimalSeparator ?? "."
        let s = t.replacingOccurrences(of: Locale.current.groupingSeparator ?? ",", with: sep == "," ? "," : "")
                 .replacingOccurrences(of: sep, with: ".")
                 .trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, let v = Double(s), v.isFinite, v >= 0 else { return nil }
        return v
    }
}

/// Load entry: type it or step it by 2.5 kg / 5 lb. The field grows with its text so decimals
/// such as 102.5 are never cut off.
struct LoadField: View {
    @Binding var loadKg: Double
    let unit: WeightUnit
    var label = "Load"

    var body: some View {
        let shown = Binding<Double>(
            get: { (unit.fromKg(loadKg) * 100).rounded() / 100 },
            set: { loadKg = unit.toKg($0) })
        HStack {
            Text(label)
            Spacer()
            Button { loadKg = max(0, unit.toKg(shown.wrappedValue - unit.step)) } label: { Image(systemName: "minus") }
                .buttonStyle(.bordered)
                .accessibilityLabel("Decrease load")
            NumberField(value: shown, fractionDigits: 2, placeholder: "Load")
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
            NumberField(value: shown, fractionDigits: 1)
                .multilineTextAlignment(.trailing)
                .fixedSize()
                .frame(minWidth: 44)
            Text(unit.rawValue).foregroundStyle(Theme.muted)
        }
    }
}
