import SwiftUI
import VelocityCore

/// Today's session from the program: readiness from the warm-up, the main lift set by set, then accessories.
struct ProgramSessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.unit) private var unitRaw = WeightUnit.lb.rawValue
    @State private var showCamera = false
    @State private var accessoryReps: [UUID: [Int]] = [:]
    @State private var confirmFinish = false

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .lb }

    var body: some View {
        Group {
            if let plan = model.sessionPlan() {
                content(plan)
            } else {
                ContentUnavailableView("No session today", systemImage: "calendar",
                                       description: Text("The block is finished, or the main lift needs a profile test first."))
            }
        }
        .background(Theme.background)
        .navigationTitle("Today's session")
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
                if p.zoneLow != nil {
                    Card {
                        CardLabel(text: "Warm-up and readiness check")
                        if let r = plan.readiness, let d = plan.readinessDelta {
                            HStack {
                                Pill(text: r.rawValue, color: readinessColor(r))
                                Text(String(format: "%+.2f m/s vs profile at %@ %@", d, unit.format(kg: plan.readinessSet?.analysis.input.loadKg ?? 0), unit.rawValue))
                                    .font(.subheadline).foregroundStyle(Theme.muted)
                            }
                            ForEach(p.notes, id: \.self) { Text($0).font(.subheadline) }
                        } else {
                            Text("Build up with 1–2 lighter sets, then record 2–3 fast reps at \(unit.format(kg: plan.readinessLoadKg)) \(unit.rawValue) (60% 1RM). Today's load adjusts from it.")
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
                            Text("Loads come from your entered 1RM. Velocity targets, readiness and set-to-set load changes start once you record a profile test for this lift.")
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
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(a.name) · \(a.sets(for: plan.readiness)) × \(a.repLow)–\(a.repHigh)\(a.loadKg > 0 ? " @ \(unit.format(kg: a.loadKg)) \(unit.rawValue)" : "")")
                                    .font(.subheadline.weight(.semibold))
                                ForEach(0..<a.sets(for: plan.readiness), id: \.self) { i in
                                    Stepper(value: repsBinding(a, i), in: 0...40) {
                                        Text("Set \(i + 1): \(accessoryReps[a.id]?[safe: i] ?? 0) reps").font(.subheadline).monospacedDigit()
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Button { confirmFinish = true } label: {
                    Text("Finish session").frame(maxWidth: .infinity).fontWeight(.semibold)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .confirmationDialog("Finish today's session?", isPresented: $confirmFinish, titleVisibility: .visible) {
                    Button("Finish session") {
                        model.finishSession(plan, accessoryReps: accessoryReps)
                        dismiss()
                    }
                } message: {
                    Text("The program moves to the next session. Accessories where every set reached the top of the range go up one load step.")
                }
            }
            .padding()
        }
    }

    private func repsBinding(_ a: AccessoryPlan, _ i: Int) -> Binding<Int> {
        Binding(get: { accessoryReps[a.id]?[safe: i] ?? 0 },
                set: { v in
                    var reps = accessoryReps[a.id] ?? Array(repeating: 0, count: a.sets)
                    while reps.count <= i { reps.append(0) }
                    reps[i] = v
                    accessoryReps[a.id] = reps
                })
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(Theme.muted); Spacer(); Text(value).monospacedDigit() }.font(.subheadline)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
