import SwiftUI
import VelocityCore

/// The training block: where you are, today's session, the week-by-week plan, and prompts for
/// deloads and retests.
struct ProgramView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.unit) private var unitRaw = WeightUnit.lb.rawValue
    @State private var building = false
    @State private var testingExercise: String?
    @State private var confirmEnd = false

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .lb }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let program = model.program {
                        content(program)
                    } else {
                        empty
                    }
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle("Program")
            .toolbar {
                if model.program != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Edit block") { building = true }
                            Button("End block", role: .destructive) { confirmEnd = true }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .navigationDestination(for: String.self) { _ in ProgramSessionView() }
            .navigationDestination(for: UUID.self) { id in SetResultsView(setID: id) }
            .sheet(isPresented: $building) { BlockBuilderView(existing: model.program) }
            .sheet(item: Binding(get: { testingExercise.map(IdentifiedString.init) }, set: { testingExercise = $0?.value })) { item in
                ProfileTestSetupView(exerciseID: item.value)
            }
            .confirmationDialog("End this block?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("End block", role: .destructive) { model.program = nil }
            } message: {
                Text("Your recorded sets and profiles stay. Only the plan is removed.")
            }
        }
    }

    private var empty: some View {
        Card {
            Text("No program yet").font(.headline)
            Text("Build a block: pick each day's main lift and goal, and the app turns the plan's %1RM into loads and target velocities from your strength profile, adjusted to how you're moving each day.")
                .font(.subheadline).foregroundStyle(Theme.muted)
            Button { building = true } label: { Text("Build a block").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func content(_ program: Program) -> some View {
        let prog = program.progress

        if let event = prog.lastEvent {
            Card {
                Label(event, systemImage: prog.retestDue ? "flag.checkered" : "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(Theme.warn)
            }
        }

        if prog.retestDue {
            Card {
                Text("Block finished").font(.headline)
                Text("Retest each main lift now. The new estimated 1RM is used for the next block automatically.")
                    .font(.subheadline).foregroundStyle(Theme.muted)
                ForEach(mainLifts(program), id: \.self) { id in
                    Button { testingExercise = id } label: {
                        Label("Profile test: \(name(id))", systemImage: "chart.line.downtrend.xyaxis").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    var next = program
                    next.progress = BlockProgress()
                    next.startDate = Date()
                    next.log = []
                    model.program = next
                } label: { Text("Start the next block").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            todayCard(program)
        }

        ForEach(mainLifts(program), id: \.self) { id in
            if let change = model.profileDrift(id) {
                Card {
                    Text("Your \(name(id).lowercased()) profile may be out of date").font(.headline)
                    Text(String(format: "Recent working sets imply a 1RM about %.0f%% %@ than your estimate. An early profile test keeps loads right.",
                                abs(change) * 100, change > 0 ? "higher" : "lower"))
                        .font(.subheadline).foregroundStyle(Theme.muted)
                    Button { testingExercise = id } label: { Text("Profile test now").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                }
            }
        }

        weeksCard(program)
    }

    private func todayCard(_ program: Program) -> some View {
        let prog = program.progress
        return Card {
            HStack {
                CardLabel(text: "Week \(prog.week) of \(program.weeks)")
                Spacer()
                if prog.inResponsiveDeload { Pill(text: "Deload session", color: Theme.warn) }
                else if prog.week == program.weeks { Pill(text: "Deload week", color: Theme.warn) }
            }
            if let day = program.currentDay {
                Text("\(day.name): \(name(day.mainExerciseID))").font(.title3.weight(.bold))
                Text(day.goal.rawValue).foregroundStyle(Theme.muted)
                if let why = model.programBlocker(day.mainExerciseID) {
                    Text(why).font(.subheadline).foregroundStyle(Theme.warn)
                    Button { testingExercise = day.mainExerciseID } label: {
                        Text("Guided profile test").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    NavigationLink(value: "session") {
                        Text("Start today's session").frame(maxWidth: .infinity).fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func weeksCard(_ program: Program) -> some View {
        Card {
            CardLabel(text: "The block")
            ForEach(program.days) { day in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(day.name) · \(name(day.mainExerciseID)) · \(day.goal.rawValue)").font(.subheadline.weight(.semibold))
                    let plans = program.weekPlans(for: day)
                    ForEach(Array(plans.enumerated()), id: \.offset) { i, w in
                        HStack {
                            Text("Wk \(i + 1)").frame(width: 44, alignment: .leading)
                                .fontWeight(i + 1 == program.progress.week ? .bold : .regular)
                            Text("\(Int((w.pctLow * 100).rounded()))–\(Int((w.pctHigh * 100).rounded()))%")
                            Spacer()
                            Text("\(w.sets) sets · stop \(Int(w.lossCutoffPct))%")
                            if w.isDeload { Text("deload").foregroundStyle(Theme.warn) }
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(i + 1 == program.progress.week ? Color.primary : Theme.muted)
                    }
                    if !day.accessories.isEmpty {
                        Text("Accessories: " + day.accessories.map(\.name).joined(separator: ", "))
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func mainLifts(_ p: Program) -> [String] {
        var seen = Set<String>()
        return p.days.map(\.mainExerciseID).filter { seen.insert($0).inserted }
    }

    private func name(_ id: String) -> String { ExerciseCatalog.exercise(id: id)?.name ?? id }
}

struct IdentifiedString: Identifiable {
    let value: String
    var id: String { value }
}
