import Charts
import SwiftUI
import VelocityCore

/// Past training, by exercise or by session (day).
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.unit) private var unitRaw = WeightUnit.lb.rawValue
    @State private var bySession = false

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .lb }

    var body: some View {
        NavigationStack {
            List {
                Picker("Show", selection: $bySession) {
                    Text("Exercises").tag(false)
                    Text("Sessions").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if model.sets.isEmpty {
                    Text(model.loaded ? "No sets yet. Record one from Today." : "Loading…")
                        .foregroundStyle(Theme.muted)
                        .listRowBackground(Color.clear)
                } else if bySession {
                    ForEach(model.sessionDays, id: \.self) { day in
                        let sets = model.sets(on: day)
                        NavigationLink(value: HistoryRoute.session(day)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(day.formatted(date: .complete, time: .omitted)).font(.headline)
                                Text(sessionSummary(sets)).font(.subheadline).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                } else {
                    ForEach(model.usedExerciseIDs, id: \.self) { id in
                        let sets = model.sets.filter { $0.exerciseID == id }
                        NavigationLink(value: HistoryRoute.exercise(id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ExerciseCatalog.exercise(id: id)?.name ?? id).font(.headline)
                                Text("\(sets.count) sets · last \(sets.first.map { $0.date.formatted(date: .abbreviated, time: .omitted) } ?? "–")")
                                    .font(.subheadline).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("History")
            .navigationDestination(for: HistoryRoute.self) { route in
                switch route {
                case .exercise(let id): ExerciseHistoryView(exerciseID: id)
                case .session(let day): SessionView(day: day)
                case .profile(let id): ProfileView(exerciseID: id)
                }
            }
            .navigationDestination(for: UUID.self) { id in SetResultsView(setID: id) }
        }
    }

    private func sessionSummary(_ sets: [AnalyzedSet]) -> String {
        var seen = Set<String>()
        let names = sets.reversed().map(\.analysis.input.exercise.name).filter { seen.insert($0).inserted }
        let volume = sets.compactMap { $0.analysis.setMetrics?.volumeLoadKg }.reduce(0, +)
        return "\(sets.count) sets · \(names.joined(separator: ", ")) · \(unit.format(kg: volume)) \(unit.rawValue)"
    }
}

enum HistoryRoute: Hashable {
    case exercise(String)
    case session(Date)
    case profile(String)
}

/// All sets from one day.
struct SessionView: View {
    let day: Date
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.unit) private var unitRaw = WeightUnit.lb.rawValue
    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .lb }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.sets(on: day).reversed()) { set in
                    NavigationLink(value: set.id) { SetRow(set: set, unit: unit) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete set", role: .destructive) { model.delete(set.id) }
                        }
                }
            }
            .padding()
        }
        .background(Theme.background)
        .navigationTitle(day.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One exercise over time: mean-velocity trend at a chosen load, targets, and every set.
struct ExerciseHistoryView: View {
    let exerciseID: String
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.unit) private var unitRaw = WeightUnit.lb.rawValue
    @State private var chosenLoad: String?
    @State private var editingTargets = false

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .lb }
    private var sets: [AnalyzedSet] { model.sets.filter { $0.exerciseID == exerciseID } }

    /// Loads as shown in the lifter's unit, most used first.
    private var loads: [String] {
        var counts: [String: Int] = [:]
        for s in sets { counts[unit.format(kg: s.analysis.input.loadKg), default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : (Double($0.key) ?? 0) > (Double($1.key) ?? 0) }.map(\.key)
    }

    private struct Point: Identifiable {
        let day: Date
        let mv: Double
        var id: Date { day }
    }

    /// Best rep mean velocity per day at the chosen load.
    private func trend(_ load: String) -> [Point] {
        var best: [Date: Double] = [:]
        for s in sets where unit.format(kg: s.analysis.input.loadKg) == load {
            guard let mv = s.analysis.setMetrics?.bestMeanVelocity else { continue }
            let d = Calendar.current.startOfDay(for: s.date)
            best[d] = max(best[d] ?? 0, mv)
        }
        return best.map { Point(day: $0.key, mv: $0.value) }.sorted { $0.day < $1.day }
    }

    var body: some View {
        let load = chosenLoad ?? loads.first
        let points = load.map(trend) ?? []
        let p = model.prefs(for: exerciseID)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Card {
                    HStack {
                        CardLabel(text: "Best MV at")
                        Menu {
                            ForEach(loads, id: \.self) { l in Button("\(l) \(unit.rawValue)") { chosenLoad = l } }
                        } label: {
                            Text("\(load ?? "–") \(unit.rawValue)").font(.caption.weight(.semibold))
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                        Spacer()
                        if points.count >= 2 {
                            let change = points.last!.mv - points.first!.mv
                            Text(String(format: "%+.2f m/s", change))
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .foregroundStyle(change >= 0 ? Theme.good : Theme.warn)
                                .overlay(Capsule().stroke(change >= 0 ? Theme.good : Theme.warn))
                        }
                    }
                    if points.isEmpty {
                        Text("No sets at this load yet.").foregroundStyle(Theme.muted)
                    } else {
                        Chart {
                            if let zone = p.targetZone {
                                RuleMark(y: .value("Zone low", zone.lowerBound))
                                    .foregroundStyle(Theme.good.opacity(0.7))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                RuleMark(y: .value("Zone high", zone.upperBound))
                                    .foregroundStyle(Theme.good.opacity(0.7))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            }
                            ForEach(points) { pt in
                                LineMark(x: .value("Day", pt.day, unit: .day), y: .value("m/s", pt.mv))
                                    .foregroundStyle(Theme.accent)
                                PointMark(x: .value("Day", pt.day, unit: .day), y: .value("m/s", pt.mv))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .chartYAxisLabel("m/s")
                        .frame(height: 170)
                    }
                }

                Card {
                    HStack {
                        CardLabel(text: "Targets for this exercise")
                        Spacer()
                        Button("Edit") { editingTargets = true }.font(.subheadline)
                    }
                    detail("Velocity zone", p.targetZone.map { "\(Fmt.velocity($0.lowerBound))–\(Fmt.velocity($0.upperBound)) m/s" } ?? "None")
                    detail("Stop set at", model.lossCutoff(for: exerciseID).map { "\(Fmt.percent($0)) loss" } ?? "No cutoff")
                    if let ex = ExerciseCatalog.exercise(id: exerciseID), ex.bodyMassFraction > 0 {
                        detail("Body mass counted", "\(Int(ex.bodyMassFraction * 100))%")
                    }
                }

                profileCard

                CardLabel(text: "All sets").padding(.top, 4)
                ForEach(sets) { set in
                    NavigationLink(value: set.id) { SetRow(set: set, unit: unit) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete set", role: .destructive) { model.delete(set.id) }
                        }
                }
            }
            .padding()
        }
        .background(Theme.background)
        .navigationTitle(ExerciseCatalog.exercise(id: exerciseID)?.name ?? "Exercise")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editingTargets) { TargetsSheet(exerciseID: exerciseID) }
    }

    private var profileCard: some View {
        let prof = model.profile(for: exerciseID)
        return Card {
            HStack {
                CardLabel(text: "Strength profile")
                Spacer()
                if prof.lastTestDate != nil, prof.retestReason() != nil { Pill(text: "Retest suggested", color: Theme.warn) }
            }
            if let orm = prof.oneRmKg {
                detail("Estimated 1RM", "\(unit.format(kg: unit.roundedToStep(kg: orm))) \(unit.rawValue)")
            }
            if let last = prof.lastTestDate {
                let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: last),
                                                           to: Calendar.current.startOfDay(for: Date())).day ?? 0
                detail("Last profile test", "\(last.formatted(.dateTime.month(.abbreviated).day())) · \(days == 0 ? "today" : "\(days) days ago")")
            } else {
                Text("No profile test yet. Tag a ramp of sets as Profile test to estimate your 1RM.")
                    .font(.subheadline).foregroundStyle(Theme.muted)
            }
            NavigationLink(value: HistoryRoute.profile(exerciseID)) {
                Text("Open profile").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(Theme.muted); Spacer(); Text(value).monospacedDigit() }
            .font(.subheadline)
    }
}
