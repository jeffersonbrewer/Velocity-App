import Foundation
import VelocityCore

/// What a finished program session looked like, saved when the lifter taps Finish session.
struct SessionDebrief: Codable, Hashable, Identifiable {
    var id = UUID()
    var date: Date
    var dayName: String
    var exerciseID: String
    var goal: TrainingGoal
    var week: Int
    var weeks: Int
    var deload: Bool
    var readiness: Readiness?
    var readinessDelta: Double?
    var readinessLoadKg: Double?
    var plannedLoadKg: Double       // the week's load before readiness
    var startLoadKg: Double         // after readiness
    var topLoadKg: Double?
    var loadSteps: Int              // top load vs plan, in load steps
    var setIDs: [UUID]
    var setsPlanned: Int
    var reps: Int
    var repCap: Int
    var repsPerSet: [Int]
    var bestMV: Double?
    var bestMVLoadKg: Double?
    var compareMV: Double?          // best rep at about the same load on an earlier day
    var compareDate: Date?
    var avgLossPct: Double?
    var lossCutoffPct: Double
    var oneRmKg: Double
    var drift: Double?              // implied 1RM change from recent working sets, when large
    var accessoriesLogged: Int
    var nextKey: String?
    var nextDayName: String?
    var nextExerciseID: String?
    var nextGoal: TrainingGoal?
    var nextLoadKg: Double?
    var nextZoneLow: Double?
    var nextZoneHigh: Double?
    var nextDeload: Bool?
    var nextWeek: Int?
    var event: String?

    var liftName: String { ExerciseCatalog.exercise(id: exerciseID)?.name ?? exerciseID }
    var bestMVChange: Double? { bestMV.flatMap { b in compareMV.map { b - $0 } } }
}

enum DebriefStore {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("debriefs.json")
    }
    static func load() -> [SessionDebrief] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SessionDebrief].self, from: data)) ?? []
    }
    static func save(_ d: [SessionDebrief]) {
        guard let data = try? JSONEncoder().encode(d) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

extension AppModel {
    /// Snapshot today's main lift before the block moves on.
    func makeDebrief(_ plan: SessionPlan, accessoryLog: [UUID: [AccessorySet]]) -> SessionDebrief {
        let p = plan.prescription
        let u = unit
        let metrics = plan.setsDone.compactMap(\.analysis.setMetrics)
        let top = plan.setsDone.map(\.analysis.input.loadKg).max()
        let steps = top.map { Int((u.fromKg($0 - p.plannedLoadKg) / u.step).rounded()) } ?? 0
        let best = plan.setsDone.max { ($0.analysis.setMetrics?.bestMeanVelocity ?? 0) < ($1.analysis.setMetrics?.bestMeanVelocity ?? 0) }
        let bestMV = best?.analysis.setMetrics?.bestMeanVelocity
        let bestLoad = best?.analysis.input.loadKg

        // Same lift at about the same load (±2.5%) on an earlier day, at least 5 days back.
        var compareMV: Double?, compareDate: Date?
        if let bestLoad {
            let cutoff = Calendar.current.date(byAdding: .day, value: -5, to: Date())!
            let earlier = sets.filter { s in
                s.exerciseID == plan.day.mainExerciseID && s.date < cutoff && s.setType == .working
                    && abs(s.analysis.input.loadKg - bestLoad) <= 0.025 * bestLoad && (s.analysis.setMetrics?.repCount ?? 0) > 0
            }
            if let day = earlier.first.map({ Calendar.current.startOfDay(for: $0.date) }) {
                let thatDay = earlier.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
                compareMV = thatDay.compactMap { $0.analysis.setMetrics?.bestMeanVelocity }.max()
                compareDate = day
            }
        }

        let losses = metrics.filter { $0.repCount >= 2 }.map(\.velocityLossPct)
        return SessionDebrief(
            date: Date(), dayName: plan.day.name, exerciseID: plan.day.mainExerciseID, goal: plan.day.goal,
            week: program?.progress.week ?? 1, weeks: program?.weeks ?? 6, deload: plan.week.isDeload,
            readiness: plan.readiness, readinessDelta: plan.readinessDelta,
            readinessLoadKg: plan.readinessSet?.analysis.input.loadKg,
            plannedLoadKg: p.plannedLoadKg, startLoadKg: p.loadKg, topLoadKg: top, loadSteps: steps,
            setIDs: plan.setsDone.map(\.id), setsPlanned: p.sets, reps: metrics.map(\.repCount).reduce(0, +),
            repCap: p.sessionRepCap, repsPerSet: metrics.map(\.repCount),
            bestMV: bestMV, bestMVLoadKg: bestLoad, compareMV: compareMV, compareDate: compareDate,
            avgLossPct: losses.isEmpty ? nil : losses.reduce(0, +) / Double(losses.count), lossCutoffPct: p.lossCutoffPct,
            oneRmKg: plan.oneRmKg, drift: profileDrift(plan.day.mainExerciseID),
            accessoriesLogged: accessoryLog.values.filter { sets in sets.contains { $0.reps > 0 } }.count)
    }

    /// Fill in the next session once the block has moved on.
    func addNext(to d: inout SessionDebrief) {
        guard let program, let next = program.nextSession, let pv = preview(next) else { return }
        let day = pv.day, p = pv.prescription
        d.nextKey = next.key
        d.nextDayName = day.name
        d.nextExerciseID = day.mainExerciseID
        d.nextGoal = day.goal
        d.nextLoadKg = p.loadKg
        d.nextZoneLow = p.zoneLow
        d.nextZoneHigh = p.zoneHigh
        d.nextDeload = p.week.isDeload
        d.nextWeek = next.week
        d.event = program.progress.lastEvent
    }

    /// Estimated 1RMs this lift was trained from, oldest first, for the trend line.
    func oneRmTrend(_ exerciseID: String) -> [(date: Date, kg: Double)] {
        debriefs.filter { $0.exerciseID == exerciseID }.reversed().map { (date: $0.date, kg: $0.oneRmKg) }
    }
}

/// The plain-words parts of a debrief.
enum DebriefText {
    static func verdict(_ d: SessionDebrief) -> String {
        if d.setIDs.isEmpty { return "Main lift not recorded today" }
        if d.deload { return "Deload session done" }
        switch d.readiness {
        case .wellDown?, .down?: return "Tough day, and you adjusted well"
        case .slightlyDown?: return "A bit flat, work still done"
        case .veryGood?, .good?: return d.loadSteps > 0 ? "Strong session, load went up" : "Strong session, moving well"
        default:
            if d.setIDs.count < d.setsPlanned && d.reps < d.repCap { return "Shorter session than planned" }
            return d.loadSteps > 0 ? "Solid session, load went up" : "Solid session, right on plan"
        }
    }

    static func loadLabel(_ d: SessionDebrief) -> String {
        switch d.loadSteps {
        case 0: return "Load on plan"
        case let n where n > 0: return "Load +\(n) step\(n == 1 ? "" : "s")"
        case let n: return "Load −\(-n) step\(n == -1 ? "" : "s")"
        }
    }

    static func howItWent(_ d: SessionDebrief, unit u: WeightUnit) -> String {
        var s: [String] = []
        if let r = d.readiness, let delta = d.readinessDelta {
            let speed = String(format: "%.2f m/s %@ than your profile", abs(delta), delta >= 0 ? "faster" : "slower")
            let warm = d.readinessLoadKg.map { "Your \(u.format(kg: $0)) \(u.rawValue) warm-up" } ?? "Your warm-up"
            let diff = d.startLoadKg - d.plannedLoadKg
            let effect = abs(u.fromKg(diff)) < u.step / 2 ? "so today ran at the planned load"
                : "so today started \(u.format(kg: abs(diff))) \(u.rawValue) \(diff > 0 ? "heavier" : "lighter") than planned"
            s.append("\(warm) moved \(speed) (\(r.rawValue.lowercased())), \(effect).")
        } else {
            s.append("No readiness reading today, so the session ran at the planned load.")
        }
        if d.setIDs.isEmpty {
            s.append("No working sets were recorded for \(d.liftName.lowercased()).")
        } else {
            let lo = d.repsPerSet.min() ?? 0, hi = d.repsPerSet.max() ?? 0
            let reps = lo == hi ? "\(lo) reps each" : "\(lo) to \(hi) reps"
            let load = d.topLoadKg.map { " up to \(u.format(kg: $0)) \(u.rawValue)" } ?? ""
            s.append("You did \(d.setIDs.count) of \(d.setsPlanned) working sets\(load), \(reps), \(d.reps) reps in all.")
            if let loss = d.avgLossPct {
                let near = loss >= d.lossCutoffPct - 3
                s.append(String(format: "Sets averaged %.0f%% velocity loss against a %.0f%% cutoff%@.", loss, d.lossCutoffPct,
                                near ? ", so they stopped where they should" : ", so you kept plenty in reserve"))
            }
        }
        if d.accessoriesLogged > 0 { s.append("\(d.accessoriesLogged) accessor\(d.accessoriesLogged == 1 ? "y" : "ies") logged; their next loads are set.") }
        return s.joined(separator: " ")
    }

    static func whatItMeans(_ d: SessionDebrief, unit u: WeightUnit) -> String {
        if d.setIDs.isEmpty {
            return "With no \(d.liftName.lowercased()) sets recorded there's nothing to judge today, so your 1RM (\(u.format(kg: d.oneRmKg)) \(u.rawValue)) and next loads stay as they were. The block has moved on to the next session."
        }
        var s: [String] = []
        if let change = d.bestMVChange, let load = d.bestMVLoadKg, let when = d.compareDate {
            let dir = abs(change) < 0.015 ? "the same as" : (change > 0 ? String(format: "up %.2f m/s on", change) : String(format: "down %.2f m/s on", -change))
            s.append("Your best rep at \(u.format(kg: load)) \(u.rawValue) was \(dir) \(when.formatted(.dateTime.month(.abbreviated).day())).")
        } else if d.bestMV != nil {
            s.append("This is the first time at this load, so there's nothing to compare yet.")
        }
        let orm = "\(u.format(kg: d.oneRmKg)) \(u.rawValue)"
        if let drift = d.drift {
            s.append(String(format: "Recent sets suggest your 1RM is about %.0f%% %@ than the %@ the plan uses. A profile test would confirm it.",
                            abs(drift) * 100, drift > 0 ? "higher" : "lower", orm))
        } else {
            s.append("Your estimated 1RM is holding at \(orm), on track for week \(d.week) of \(d.weeks).")
        }
        return s.joined(separator: " ")
    }

    static func recovery(_ d: SessionDebrief) -> String {
        if d.setIDs.isEmpty { return "Usual sleep and protein." }
        switch d.readiness {
        case .down?, .wellDown?:
            return "Readiness was down today. Put sleep and food first, and keep any extra hard training light until the next session."
        case .slightlyDown?:
            return "A little flat today. Usual sleep and protein, and go easy on extra conditioning before the next session."
        default:
            if d.deload { return "Deload week: keep the rest of your training easy too, so you go into the retest fresh." }
            return "Usual sleep and protein. Leave a day or more before training \(d.liftName.lowercased()) hard again."
        }
    }

    static func blockNote(_ d: SessionDebrief) -> String {
        if d.week >= d.weeks { return "This is the deload week. The block ends with a profile test." }
        if d.week == d.weeks - 1 { return "Next week is the deload, then a profile test." }
        return "Week \(d.weeks) is a deload, then a profile test."
    }
}
