import SwiftUI
import VelocityCore

/// Today's session from the program: readiness from the warm-up, the main lift set by set, then accessories.
struct ProgramSessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.unit) private var unitRaw = WeightUnit.lb.rawValue
    @State private var showCamera = false
    @State private var accessoryLog: [UUID: [AccessorySet]] = [:]
    @State private var accessoryLoad: [UUID: Double] = [:]
    @State private var confirmFinish = false
    @State private var finished: UUID?

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .lb }

    var body: some View {
        Group {
            if let finished {
                DebriefView(debriefID: finished)
            } else if let plan = model.sessionPlan() {
                content(plan)
            } else {
                ContentUnavailableView("No session today", systemImage: "calendar",
                                       description: Text("The block is finished, or the main lift needs a profile test first."))
            }
        }
        .background(Theme.background)
        .keyboardDoneButton()
        .navigationTitle(finished == nil ? "Today's session" : "Session debrief")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showCamera) { CameraSetupView() }
    }

    private func content(_ plan: SessionPlan) -> some View {
        let p = plan.prescription
        let liftName = ExerciseCatalog.exercise(id: plan.day.mainExerciseID)?.name ?? ""
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(plan.day.name) · \(liftName) · \(p.goal.rawValue)\(plan.week.isDeload ? " · deload" : "")")
                    .foregroundStyle(Theme.muted)

                // 1. Warm-up and readiness
                Card {
                    CardLabel(text: "Warm-up and readiness check")
                    if let r = plan.readiness, let d = plan.readinessDelta {
                        HStack {
                            Pill(text: r.rawValue, color: readinessColor(r))
                            Text(String(format: "%+.2f m/s vs profile at %@ %@", d, unit.format(kg: plan.readinessSet?.analysis.input.loadKg ?? 0), unit.rawValue))
                                .font(.subheadline).foregroundStyle(Theme.muted)
                        }
                        ForEach(p.notes, id: \.self) { Text($0).font(.subheadline) }
                    } else if plan.readinessSet != nil {
                        Label("60% set recorded. Readiness checks start once your velocity targets are learned.", systemImage: "checkmark.circle")
                            .font(.subheadline).foregroundStyle(Theme.muted)
                    } else {
                        Text("Build up with 1–2 lighter sets, then record 2–3 fast reps at \(unit.format(kg: plan.readinessLoadKg)) \(unit.rawValue) (60% 1RM). \(p.zoneLow == nil ? "It's used to learn your velocity targets." : "Today's load adjusts from it.")")
                            .font(.subheadline).foregroundStyle(Theme.muted)
                        Button {
                            model.prepareMainSet(plan, loadKg: plan.readinessLoadKg)
                            showCamera = true
                        } label: {
                            Label("Record the 60% set", systemImage: "video.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                // 2. Main lift
                Card {
                    HStack {
                        CardLabel(text: "\(liftName) · set \(min(plan.setsDone.count + 1, p.sets)) of \(p.sets)")
                        Spacer()
                        Text("Week \(model.program?.progress.week ?? 1)").font(.caption).foregroundStyle(Theme.muted)
                    }
                    if let done = plan.doneReason {
                        Label(done, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good).font(.headline)
                    } else {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Load the bar to").foregroundStyle(Theme.muted)
                            Text("\(unit.format(kg: plan.nextLoadKg)) \(unit.rawValue)").font(.title2.weight(.bold)).monospacedDigit()
                        }
                        if let why = plan.nextLoadReason { Text(why).font(.caption).foregroundStyle(Theme.accent) }
                        if p.zoneLow != nil {
                            row("Target zone, first rep", "\(Fmt.velocity(p.zoneLow))–\(Fmt.velocity(p.zoneHigh)) m/s")
                        } else {
                            Text("Loads come from your entered 1RM. Record today's 60% warm-up and working sets: from your next session the app learns your velocity targets from them, then checks readiness and adjusts loads set to set. A profile test gives them right away.")
                                .font(.caption).foregroundStyle(Theme.muted)
                        }
                        row("Stop the set at", "\(Fmt.percent(p.lossCutoffPct)) loss or \(p.repCapPerSet) reps")
                        row("Rest", "\(Fmt.load(p.restLowMin))–\(Fmt.load(p.restHighMin)) min")
                        row("Session rep cap", "\(plan.setsDone.compactMap { $0.analysis.setMetrics?.repCount }.reduce(0, +)) of \(p.sessionRepCap)")
                        Button {
                            model.prepareMainSet(plan, loadKg: plan.nextLoadKg)
                            showCamera = true
                        } label: {
                            Label("Record set \(plan.setsDone.count + 1)", systemImage: "video.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    if plan.lineLearned && p.zoneLow != nil {
                        Text("Velocity targets are learned from your recent sessions. They never change your 1RM, but if your sets drift 5% or more from it, the app suggests a profile test.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    Text("The first rep of each set sets the next load: one step up if it's faster than the zone, one step down if slower, within 5% of the plan.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                ForEach(plan.setsDone) { set in
                    NavigationLink(value: set.id) { SetRow(set: set, unit: unit, showDate: false) }.buttonStyle(.plain)
                }

                // 3. Accessories
                let accessories = plan.day.accessories.filter { $0.sets(for: plan.readiness) > 0 }
                if !plan.day.accessories.isEmpty {
                    Card {
                        CardLabel(text: "Accessories")
                        if accessories.isEmpty {
                            Text("Skipped today: readiness is well down.").font(.subheadline).foregroundStyle(Theme.muted)
                        }
                        ForEach(accessories) { a in
                            AccessorySessionRow(accessory: a, sets: a.sets(for: plan.readiness), unit: unit,
                                                log: Binding(get: { accessoryLog[a.id] ?? [] }, set: { accessoryLog[a.id] = $0 }),
                                                loadKg: Binding(get: { accessoryLoad[a.id] ?? a.loadKg }, set: { accessoryLoad[a.id] = $0 }))
                        }
                        Text("Log reps and reps in reserve (RIR) for each set. The next session's load is set from them.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }

                Button { confirmFinish = true } label: {
                    Text("Finish session").frame(maxWidth: .infinity).fontWeight(.semibold)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .confirmationDialog("Finish today's session?", isPresented: $confirmFinish, titleVisibility: .visible) {
                    Button("Finish session") {
                        finished = model.finishSession(plan, accessoryLog: accessoryLog, loadsUsed: accessoryLoad)?.id
                        if finished == nil { dismiss() }
                    }
                } message: {
                    if plan.setsDone.isEmpty {
                        Text("No \(liftName.lowercased()) working sets are recorded yet. If you finish now, the program still moves to the next session and the main lift's loads stay as they are.")
                    } else {
                        Text("The program moves to the next session, each accessory's next load is set from today's reps and RIR, and you get a debrief of the session.")
                    }
                }
            }
            .padding()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(Theme.muted); Spacer(); Text(value).monospacedDigit() }.font(.subheadline)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// One accessory in today's session: the prescription, the load used, and reps and RIR per set.
struct AccessorySessionRow: View {
    let accessory: AccessoryPlan
    let sets: Int
    let unit: WeightUnit
    @Binding var log: [AccessorySet]
    @Binding var loadKg: Double

    var body: some View {
        let e = accessory.exercise
        let takesLoad = e?.takesLoad ?? (accessory.loadKg > 0)
        VStack(alignment: .leading, spacing: 6) {
            Text(accessory.name).font(.subheadline.weight(.semibold))
            Text("\(sets) × \(accessory.repLow)–\(accessory.repHigh), stop at \(accessory.rir) RIR")
                .font(.caption).foregroundStyle(Theme.muted)
            if takesLoad {
                if accessory.loadKg <= 0 {
                    Text("First time: pick a load you'd get about \(accessory.targetReps) reps with \(accessory.rir) in reserve, and enter it here.")
                        .font(.caption).foregroundStyle(Theme.accent)
                }
                LoadField(loadKg: $loadKg, unit: unit, label: e?.equipment == .dumbbell ? "Load (each)" : "Load")
            }
            ForEach(0..<sets, id: \.self) { i in
                HStack {
                    Text("Set \(i + 1)").foregroundStyle(Theme.muted)
                    Stepper("\(entry(i).reps) reps", value: repsBinding(i), in: 0...50)
                        .monospacedDigit()
                    Picker("RIR", selection: rirBinding(i)) {
                        ForEach(0...5, id: \.self) { Text("RIR \($0)").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .font(.subheadline)
            }
        }
        .padding(.vertical, 2)
    }

    private func entry(_ i: Int) -> AccessorySet { log[safe: i] ?? AccessorySet(reps: 0, rir: accessory.rir) }

    private func update(_ i: Int, _ change: (inout AccessorySet) -> Void) {
        var l = log
        while l.count <= i { l.append(AccessorySet(reps: 0, rir: accessory.rir)) }
        change(&l[i])
        log = l
    }

    private func repsBinding(_ i: Int) -> Binding<Int> {
        Binding(get: { entry(i).reps }, set: { v in update(i) { $0.reps = v } })
    }

    private func rirBinding(_ i: Int) -> Binding<Int> {
        Binding(get: { entry(i).rir ?? accessory.rir }, set: { v in update(i) { $0.rir = v } })
    }
}
