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
                            AccessoryEditor(accessory: $a, unit: unit)
                        }
                        .onDelete { day.accessories.remove(atOffsets: $0) }
                        Menu("Add accessory") {
                            ForEach(AccessoryLibrary.options(for: day.mainExerciseID), id: \.self) { name in
                                Button(name) { day.accessories.append(AccessoryLibrary.plan(name, goal: day.goal, unit: unit)) }
                            }
                            Button("Other…") { day.accessories.append(AccessoryLibrary.plan("", goal: day.goal, unit: unit)) }
                        }
                        Button("Suggest accessories for this goal") {
                            day.accessories = AccessoryLibrary.defaults(for: day.mainExerciseID, goal: day.goal, unit: unit)
                        }
                        .font(.subheadline)
                    } header: { Text(day.name.isEmpty ? "Day" : day.name) } footer: {
                        Text("Accessories progress by double progression: when every set reaches the top of the rep range, the next session adds one load step.")
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

    private func resizeDays(_ n: Int) {
        let names = ["Day A", "Day B", "Day C", "Day D"]
        while program.days.count < n {
            let last = program.days.last
            let ex = last?.mainExerciseID ?? programmable[0].id, goal = last?.goal ?? .maxStrength
            program.days.append(ProgramDay(name: names[program.days.count], mainExerciseID: ex, goal: goal,
                                           accessories: AccessoryLibrary.defaults(for: ex, goal: goal, unit: unit)))
        }
        while program.days.count > n { program.days.removeLast() }
        program.progress.day = min(program.progress.day, max(0, n - 1))
    }
}

struct AccessoryEditor: View {
    @Binding var accessory: AccessoryPlan
    let unit: WeightUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Exercise (e.g. RDL, split squat)", text: $accessory.name)
                .fontWeight(.semibold)
            HStack {
                Stepper("\(accessory.sets) sets", value: $accessory.sets, in: 1...6)
            }
            HStack {
                Stepper("\(accessory.repLow)–\(accessory.repHigh) reps", value: $accessory.repLow, in: 1...max(1, accessory.repHigh))
                Stepper("", value: $accessory.repHigh, in: accessory.repLow...30).labelsHidden()
            }
            LoadField(loadKg: $accessory.loadKg, unit: unit)
        }
        .font(.subheadline)
    }
}

/// Enter a 1RM tested outside the app, so a lift can be programmed before its first profile test.
struct KnownOneRmField: View {
    let exerciseID: String
    let unit: WeightUnit
    @Environment(AppModel.self) private var model

    var body: some View {
        LoadField(loadKg: Binding(get: { model.prefs(for: exerciseID).knownOneRmKg ?? 0 },
                                  set: { model.setKnownOneRm(exerciseID, kg: $0) }),
                  unit: unit, label: "Known 1RM")
    }
}
