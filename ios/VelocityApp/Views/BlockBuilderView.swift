import SwiftUI
import VelocityCore

/// Build or edit a block: length, and for each day the main lift, its goal and accessories.
struct BlockBuilderView: View {
    let existing: Program?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.unit) private var unitRaw = WeightUnit.lb.rawValue
    @State private var program = Program(days: [])

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .lb }
    private let programmable = ExerciseCatalog.all.filter { $0.allowsOneRm }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $program.weeks, in: 3...10) {
                        HStack { Text("Weeks"); Spacer(); Text("\(program.weeks)").monospacedDigit() }
                    }
                    Stepper(value: Binding(get: { program.days.count }, set: resizeDays), in: 1...4) {
                        HStack { Text("Sessions per week"); Spacer(); Text("\(program.days.count)").monospacedDigit() }
                    }
                } header: { Text("Block") } footer: {
                    Text("The last week is always a deload, followed by a profile test. Each day can have its own goal.")
                }

                balanceSection

                ForEach($program.days) { $day in
                    Section {
                        TextField("Name", text: $day.name)
                        Picker("Main lift", selection: $day.mainExerciseID) {
                            ForEach(programmable) { Text($0.name).tag($0.id) }
                        }
                        Picker("Goal", selection: $day.goal) {
                            ForEach(TrainingGoal.allCases) { Text($0.rawValue).tag($0) }
                        }
                        let t = GoalTemplate.default(day.goal)
                        Text("\(Int(t.pctLow * 100))–\(Int(t.pctHigh * 100))% 1RM · stop at \(Int(t.lossLow))–\(Int(t.lossHigh))% loss · \(t.setsLow)–\(t.setsHigh) sets")
                            .font(.caption).foregroundStyle(Theme.muted)
                        KnownOneRmField(exerciseID: day.mainExerciseID, unit: unit)
                        if let why = model.programBlocker(day.mainExerciseID) {
                            Text(why).font(.caption).foregroundStyle(Theme.warn)
                        } else if let orm = model.programOneRm(day.mainExerciseID) {
                            Text(orm.fromProfile ? "Using your profile's estimated 1RM (\(unit.format(kg: unit.roundedToStep(kg: orm.kg))) \(unit.rawValue)). An entered 1RM is used instead once it's newer than your last profile test."
                                                 : "Using the 1RM you entered. A new profile test replaces it.")
                                .font(.caption).foregroundStyle(Theme.muted)
                        }
                        ForEach($day.accessories) { $a in
                            AccessoryEditor(accessory: $a, goal: day.goal, unit: unit)
                        }
                        .onDelete { day.accessories.remove(atOffsets: $0) }
                        AccessoryPicker(title: "Add accessory", fullWidth: true) { e in
                            day.accessories.append(AccessoryLibrary.plan(e, goal: day.goal, unit: unit))
                        }
                        Button("Suggest accessories") {
                            day.accessories = AccessoryLibrary.fill(day, in: program.days, unit: unit)
                        }
                        .font(.subheadline)
                    } header: { Text(day.name.isEmpty ? "Day" : day.name) } footer: {
                        Text("Suggestions put one accessory on the main lift's pattern and fill the rest from the patterns your week covers least, including combos. Each set logs reps and RIR; the next load is set from them. Leave a start load at 0 to find it in the first session.")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .keyboardDoneButton()
            .navigationTitle(existing == nil ? "New block" : "Edit block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Start" : "Save") {
                        var p = program
                        for i in p.days.indices { p.days[i].accessories.removeAll { $0.name.trimmingCharacters(in: .whitespaces).isEmpty } }
                        model.program = p
                        dismiss()
                    }
                    .disabled(program.days.isEmpty)
                }
            }
            .onAppear {
                if let existing { program = existing }
                else {
                    let start = programmable.contains { $0.id == model.currentExerciseID } ? model.currentExerciseID : programmable[0].id
                    program = .starter(goal: .maxStrength, exerciseID: start, daysPerWeek: 2, unit: unit)
                }
            }
        }
    }

    private var balanceSection: some View {
        let days = AccessoryLibrary.balance(program.days)
        let counts = PatternBalance.counts(days)
        let flags = PatternBalance.flags(days)
        return Section {
            ForEach(["Squat / lunge", "Hinge", "Push", "Pull", "Core / carry", "Arms", "Jump / throw"], id: \.self) { f in
                let n = counts[f] ?? 0
                if n > 0 || !["Arms", "Jump / throw"].contains(f) {
                    HStack { Text(f); Spacer(); Text("\(n)×").monospacedDigit().foregroundStyle(n == 0 ? Theme.warn : Theme.muted) }
                        .font(.subheadline)
                }
            }
            ForEach(flags, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warn) }
        } header: { Text("Movement patterns this week") } footer: {
            Text("Main lifts and accessories together. A combo counts toward each pattern it trains.")
        }
    }

    private func resizeDays(_ n: Int) {
        let names = ["Day A", "Day B", "Day C", "Day D"]
        while program.days.count < n {
            let last = program.days.last
            let ex = last?.mainExerciseID ?? programmable[0].id, goal = last?.goal ?? .maxStrength
            var day = ProgramDay(name: names[program.days.count], mainExerciseID: ex, goal: goal)
            day.accessories = AccessoryLibrary.fill(day, in: program.days + [day], unit: unit)
            program.days.append(day)
        }
        while program.days.count > n { program.days.removeLast() }
        program.progress.day = min(program.progress.day, max(0, n - 1))
    }
}

struct AccessoryEditor: View {
    @Binding var accessory: AccessoryPlan
    let goal: TrainingGoal
    let unit: WeightUnit

    var body: some View {
        let e = accessory.exercise
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if e == nil {
                    TextField("Exercise", text: $accessory.name).fontWeight(.semibold)
                } else {
                    Text(accessory.name).fontWeight(.semibold)
                }
                Spacer()
                AccessoryPicker(title: "Change") { picked in
                    var next = AccessoryLibrary.plan(picked, goal: goal, unit: unit)
                    next.id = accessory.id
                    next.sets = accessory.sets
                    accessory = next
                }
                .font(.caption)
            }
            if let e {
                Text(e.patterns.map(\.rawValue).joined(separator: " · ") + (e.isCombo ? " · combo" : ""))
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            Stepper("\(accessory.sets) sets", value: $accessory.sets, in: 1...6)
            HStack {
                Stepper("\(accessory.repLow)–\(accessory.repHigh) reps", value: $accessory.repLow, in: 1...max(1, accessory.repHigh))
                Stepper("Top of rep range", value: $accessory.repHigh, in: accessory.repLow...30).labelsHidden()
            }
            Stepper("Stop at \(accessory.rir) RIR", value: Binding(get: { accessory.rir }, set: { accessory.targetRIR = $0 }), in: 0...5)
            if e?.takesLoad ?? true {
                LoadField(loadKg: $accessory.loadKg, unit: unit, label: e?.equipment == .dumbbell ? "Start load (each)" : "Start load")
            } else {
                Text(e?.ballistic == true ? "Fast reps: progress by reps and quality, not load." : "Bodyweight: add load once every set reaches the top of the range.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .font(.subheadline)
    }
}

/// Library menu grouped by movement pattern, with combos and a typed option.
struct AccessoryPicker: View {
    let title: String
    var fullWidth = false
    let onPick: (AccessoryExercise?) -> Void

    var body: some View {
        Menu {
            Menu("Combos") {
                ForEach(AccessoryLibraryData.all.filter(\.isCombo)) { e in Button(e.name) { onPick(e) } }
            }
            ForEach(MovementPattern.allCases) { p in
                let list = AccessoryLibraryData.all.filter { !$0.isCombo && $0.patterns.first == p }
                if !list.isEmpty {
                    Menu(p.rawValue) {
                        ForEach(list) { e in Button(e.name) { onPick(e) } }
                    }
                }
            }
            Button("Other (type a name)") { onPick(nil) }
        } label: {
            if fullWidth {
                Label(title, systemImage: "plus.circle").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            } else {
                Text(title)
            }
        }
    }
}

/// Enter a 1RM tested outside the app, so a lift can be programmed before its first profile test.
/// With `explicitSave` (the Profile screen) the value is kept only when Save is tapped, and a
/// short "Known 1RM updated" note confirms it; otherwise it saves as you type.
struct KnownOneRmField: View {
    let exerciseID: String
    let unit: WeightUnit
    var explicitSave = false
    @Environment(AppModel.self) private var model
    @State private var draftKg: Double?
    @State private var justSaved = false

    var body: some View {
        let p = model.prefs(for: exerciseID)
        let stored = p.knownOneRmKg ?? 0
        VStack(alignment: .leading, spacing: 6) {
            if explicitSave {
                LoadField(loadKg: Binding(get: { draftKg ?? stored }, set: { draftKg = $0; justSaved = false }),
                          unit: unit, label: "Known 1RM")
                let changed = abs((draftKg ?? stored) - stored) > 0.001
                HStack {
                    if justSaved {
                        Label("Known 1RM updated", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.good)
                            .transition(.opacity)
                    } else if let kg = p.knownOneRmKg, let d = p.knownOneRmDate {
                        Text("Saved: \(unit.format(kg: kg)) \(unit.rawValue), \(d.formatted(.dateTime.month(.abbreviated).day()))")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if changed {
                        Button("Cancel") { draftKg = nil }.font(.subheadline)
                    }
                    Button("Save") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        model.setKnownOneRm(exerciseID, kg: draftKg ?? stored)
                        draftKg = nil
                        withAnimation { justSaved = true }
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        Task { try? await Task.sleep(for: .seconds(4)); withAnimation { justSaved = false } }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!changed)
                }
            } else {
                LoadField(loadKg: Binding(get: { stored }, set: { model.setKnownOneRm(exerciseID, kg: $0) }),
                          unit: unit, label: "Known 1RM")
                if let kg = p.knownOneRmKg, let d = p.knownOneRmDate {
                    Label("Saved: \(unit.format(kg: kg)) \(unit.rawValue), \(d.formatted(.dateTime.month(.abbreviated).day()))",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(Theme.good)
                } else {
                    Text("Type it and tap Done: it saves on its own.").font(.caption).foregroundStyle(Theme.muted)
                }
            }
        }
        .onChange(of: exerciseID) { _, _ in draftKg = nil; justSaved = false }
    }
}
