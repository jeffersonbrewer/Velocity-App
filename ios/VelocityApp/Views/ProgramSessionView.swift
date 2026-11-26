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
    @State private var logging: ManualSetDraft?

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .lb }

    var body: some View {
        Group {
            if let finished {
                DebriefView(debriefID: finished)
            } else if let day = model.program?.currentDay, !model.sessionPlans().isEmpty {
                content(day, model.sessionPlans())
            } else {
                ContentUnavailableView("No session today", systemImage: "calendar",
                                       description: Text("The block is finished, or the main lift needs a profile test first."))
            }
        }
        .background(Theme.background)
        .keyboardDoneButton()
        .navigationTitle(finished == nil ? "Today's session" : "Session debrief")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showCamera, onDismiss: { model.endCameraSession() }) { CameraSetupView() }
        .sheet(item: $logging) { draft in
            ManualSetSheet(draft: draft, unit: unit) { d in
                model.manualSets.append(ManualSet(date: Date(), exerciseID: d.exerciseID, loadKg: d.loadKg, reps: d.reps, rir: d.rir))
            }
        }
    }

    private func content(_ day: ProgramDay, _ plans: [SessionPlan]) -> some View {
        let readiness = model.sessionReadiness(plans)
        let blocked = day.lifts.filter { l in !plans.contains { $0.lift.id == l.id } }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(day.name) · \(plans.count > 1 ? day.liftNames : "\(plans[0].lift.name) · \(plans[0].prescription.goal.rawValue)")\(plans[0].week.isDeload ? " · deload" : "")")
                    .foregroundStyle(Theme.muted)

                ForEach(plans, id: \.lift.id) { plan in
                    liftSection(plan, count: day.lifts.count)
                }
                ForEach(blocked) { l in
                    Card {
                        CardLabel(text: l.name)
                        Text(model.programBlocker(l.exerciseID) ?? "This lift isn't ready yet.").font(.subheadline).foregroundStyle(Theme.warn)
                        Text("Add it from Program › Edit block, or skip it today.").font(.caption).foregroundStyle(Theme.muted)
                    }
                }

                // Accessories
                let accessories = day.accessories.filter { $0.sets(for: readiness) > 0 }
                if !day.accessories.isEmpty {
                    Card {
                        CardLabel(text: "Accessories")
                        if accessories.isEmpty {
                            Text("Skipped today: readiness is well down.").font(.subheadline).foregroundStyle(Theme.muted)
                        }
                        ForEach(accessories) { a in
                            AccessorySessionRow(accessory: a, sets: a.sets(for: readiness), unit: unit,
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
                        finished = model.finishSession(plans, accessoryLog: accessoryLog, loadsUsed: accessoryLoad)?.id
                        if finished == nil { dismiss() }
                    }
                } message: {
                    let missing = plans.filter { $0.setCount == 0 }.map { $0.lift.name.lowercased() }
                    if !missing.isEmpty {
                        Text("No \(missing.joined(separator: " or ")) working sets are recorded yet. If you finish now, the program still moves to the next session and those loads stay as they are.")
                    } else {
                        Text("The program moves to the next session, each accessory's next load is set from today's reps and RIR, and you get a debrief of the session.")
                    }
                }
            }
            .padding()
        }
    }

    /// One main lift: its warm-up and readiness check, the working sets, and the sets done.
    @ViewBuilder
    private func liftSection(_ plan: SessionPlan, count: Int) -> some View {
        let p = plan.prescription
        let liftName = plan.lift.name
        if count > 1 {
            Text("Lift \(plan.liftIndex + 1) of \(count) · \(liftName) · \(p.goal.rawValue)")
                .font(.headline).padding(.top, plan.liftIndex > 0 ? 8 : 0)
        }
                // 1. Warm-up and readiness
                Card {
                    CardLabel(text: count > 1 ? "\(liftName) warm-up and readiness" : "Warm-up and readiness check")
                    if let r = plan.readiness, let d = plan.readinessDelta {
                        HStack {
                            Pill(text: r.rawValue, color: readinessColor(r))
                            Text(String(format: "%+.2f m/s vs profile at %@ %@", d, unit.format(kg: plan.readinessSet?.analysis.input.loadKg ?? 0), unit.rawValue))
                                .font(.subheadline).foregroundStyle(Theme.muted)
                        }
                        ForEach(p.notes, id: \.self) { Text($0).font(.subheadline) }
                        Text(loadChange(p)).font(.subheadline.weight(.semibold))
                    } else if let w = plan.readinessSet {
                        Label("60% set recorded at \(unit.format(kg: w.analysis.input.loadKg)) \(unit.rawValue). Readiness starts next session, once your velocity targets are learned from today's sets.", systemImage: "checkmark.circle")
                            .font(.subheadline).foregroundStyle(Theme.muted)
                        Text(loadChange(p)).font(.subheadline.weight(.semibold))
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
                        CardLabel(text: "\(liftName) · set \(min(plan.setCount + 1, p.sets)) of \(p.sets)")
                        Spacer()
                        Text("Week \(model.program?.progress.week ?? 1)").font(.caption).foregroundStyle(Theme.muted)
                    }
                    if model.rest != nil {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in RestTimerBar(now: ctx.date) }
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
                        row("Session rep cap", "\(plan.repCount) of \(p.sessionRepCap)")
                        Button {
                            model.prepareMainSet(plan, loadKg: plan.nextLoadKg)
                            showCamera = true
                        } label: {
                            Label("Record set \(plan.setCount + 1)", systemImage: "video.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        Button { logging = ManualSetDraft(exerciseID: plan.lift.exerciseID, loadKg: plan.nextLoadKg) } label: {
                            Label("Log a set by hand", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        Text("If the camera can't track the plate, log the set's load, reps and RIR here. It counts toward today's sets, but has no velocity.")
                            .font(.caption).foregroundStyle(Theme.muted)
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
                ForEach(plan.manualDone) { m in
                    Card {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(unit.format(kg: m.loadKg)) \(unit.rawValue) × \(m.reps)").font(.headline).monospacedDigit()
                                Text("Logged by hand\(m.rir.map { " · RIR \($0)" } ?? "") · no velocity").font(.caption).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Button(role: .destructive) { model.manualSets.removeAll { $0.id == m.id } } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("Delete set logged by hand")
                        }
                    }
                }

    }

    /// What the warm-up did to today's load.
    private func loadChange(_ p: MainLiftPrescription) -> String {
        let diff = p.loadKg - p.plannedLoadKg
        let lb = { (kg: Double) in "\(unit.format(kg: kg)) \(unit.rawValue)" }
        if abs(unit.fromKg(diff)) < unit.step / 2 { return "Today's load stays at \(lb(p.loadKg)), as planned." }
        return diff < 0 ? "Today's load drops \(lb(-diff)) to \(lb(p.loadKg))." : "Today's load goes up \(lb(diff)) to \(lb(p.loadKg))."
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
            if takesLoad && accessory.loadKg <= 0 {
                Text("First time: pick a load you'd get about \(accessory.targetReps) reps with \(accessory.rir) in reserve, and enter it here.")
                    .font(.caption).foregroundStyle(Theme.accent)
            }
            LoadField(loadKg: $loadKg, unit: unit, label: loadLabel(e))
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

struct ManualSetDraft: Identifiable {
    let id = UUID()
    var exerciseID: String
    var loadKg: Double
    var reps = 5
    var rir = 2
}

/// Log one main-lift set by hand: load, reps and reps in reserve.
struct ManualSetSheet: View {
    @State var draft: ManualSetDraft
    let unit: WeightUnit
    let onSave: (ManualSetDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LoadField(loadKg: $draft.loadKg, unit: unit)
                    Stepper("\(draft.reps) reps", value: $draft.reps, in: 1...50).monospacedDigit()
                    Picker("Reps in reserve", selection: $draft.rir) {
                        ForEach(0...5, id: \.self) { Text("RIR \($0)").tag($0) }
                    }
                } footer: {
                    Text("Counts toward today's sets and rep cap. Sets logged by hand have no velocity, so they don't change readiness, loads between sets or your 1RM.")
                }
            }
            .navigationTitle("Log a set by hand")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(draft); dismiss() }.fontWeight(.semibold).disabled(draft.loadKg <= 0)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
