import Foundation
import VelocityCore

/// One session of the week: a main lift with its goal, plus accessories.
struct ProgramDay: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var mainExerciseID: String
    var goal: TrainingGoal
    var accessories: [AccessoryPlan] = []
    /// Main lifts after the first, each with its own goal, done in order. (Optional so older program files load.)
    var extraLifts: [MainLift]?

    var extras: [MainLift] {
        get { extraLifts ?? [] }
        set { extraLifts = newValue.isEmpty ? nil : newValue }
    }
    /// Every main lift of the day in order; the first is `mainExerciseID` and `goal`.
    var lifts: [MainLift] { [MainLift(id: id, exerciseID: mainExerciseID, goal: goal)] + extras }
    var liftNames: String { lifts.map { ExerciseCatalog.exercise(id: $0.exerciseID)?.name ?? $0.exerciseID }.joined(separator: " + ") }
}

/// One main lift in a day, with its goal.
struct MainLift: Codable, Hashable, Identifiable {
    var id = UUID()
    var exerciseID: String
    var goal: TrainingGoal

    var name: String { ExerciseCatalog.exercise(id: exerciseID)?.name ?? exerciseID }
    var template: GoalTemplate { .forLift(goal, exerciseID: exerciseID) }
}

/// A finished session, kept for the program's history.
struct ProgramSessionLog: Codable, Hashable, Identifiable {
    var id = UUID()
    var date: Date
    var week: Int
    var dayIndex: Int
    var deload: Bool
    var reading: Readiness?
}

/// A training block: weeks of sessions, each day with its own goal (undulating), the last week a deload.
struct Program: Codable, Hashable {
    var id = UUID()
    var startDate = Date()
    var weeks = 6
    var days: [ProgramDay]
    var progress = BlockProgress()
    var log: [ProgramSessionLog] = []
    /// Training days and times; nil until the lifter plans their week.
    var schedule: WeekSchedule?
    /// Sessions moved by hand and Calendar events, by planned-session key.
    /// (Optional so program files saved before v0.15 still load.)
    var calendarState: SessionCalendar?
    var calendar: SessionCalendar {
        get { calendarState ?? SessionCalendar() }
        set { calendarState = newValue }
    }

    var currentDay: ProgramDay? { progress.finished || days.isEmpty ? nil : days[min(progress.day, days.count - 1)] }

    func weekPlans(for day: ProgramDay) -> [WeekPlan] { weekPlans(for: day.lifts[0]) }

    func weekPlans(for lift: MainLift) -> [WeekPlan] {
        BlockPlanner.weeks(for: lift.template, count: weeks)
    }

    /// This session's week plan for a lift: the block week, or deload values during a responsive deload.
    func weekPlan(for lift: MainLift) -> WeekPlan {
        if progress.inResponsiveDeload { return BlockPlanner.deload(for: lift.template) }
        let plans = weekPlans(for: lift)
        return plans[min(max(progress.week - 1, 0), plans.count - 1)]
    }

    /// A starting block for a goal: up to 3 days with that goal and its accessory slots, named but empty.
    static func starter(goal: TrainingGoal, exerciseID: String, daysPerWeek: Int, unit: WeightUnit) -> Program {
        let t = GoalTemplate.default(goal)
        let names = ["Day A", "Day B", "Day C", "Day D"]
        _ = t
        let days = (0..<daysPerWeek).map { i in ProgramDay(name: names[i], mainExerciseID: exerciseID, goal: goal) }
        return Program(days: AccessoryLibrary.fillAll(days, unit: unit))
    }
}

/// Stores the program in one JSON file.
enum ProgramStore {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("program.json")
    }
    static func load() -> Program? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Program.self, from: data)
    }
    static func save(_ p: Program?) {
        if let p, let data = try? JSONEncoder().encode(p) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        } else if p == nil {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Builds accessory slots from the pattern-tagged library in VelocityCore.
enum AccessoryLibrary {
    /// Load step for an implement, in kg: dumbbells per hand by the usual step, kettlebells by bell size.
    static func stepKg(_ e: AccessoryExercise?, unit: WeightUnit) -> Double {
        if e?.equipment == .kettlebell { return unit == .kg ? 4 : unit.toKg(5) }
        return unit.toKg(unit.step)
    }

    static func plan(_ e: AccessoryExercise?, name: String? = nil, goal: TrainingGoal, unit: WeightUnit) -> AccessoryPlan {
        let t = GoalTemplate.default(goal)
        var a = AccessoryPlan(name: name ?? e?.name ?? "", sets: t.accessorySets, repLow: t.accessoryRepLow, repHigh: t.accessoryRepHigh,
                              loadKg: 0, stepKg: stepKg(e, unit: unit), exerciseID: e?.id, targetRIR: 2)
        if e?.ballistic == true { a.repLow = 3; a.repHigh = 6; a.targetRIR = 3 }
        return a
    }

    /// Patterns a day trains: its main lift and its accessories.
    static func patterns(of day: ProgramDay) -> [MovementPattern] {
        day.lifts.map { AccessoryLibraryData.pattern(ofMainLift: $0.exerciseID) } + day.accessories.flatMap { $0.exercise?.patterns ?? [] }
    }

    /// Fill a day's slots, complementing the rest of the week.
    static func fill(_ day: ProgramDay, in days: [ProgramDay], unit: WeightUnit) -> [AccessoryPlan] {
        let others = days.filter { $0.id != day.id }
        let used = Set(others.flatMap { $0.accessories.compactMap(\.exerciseID) })
        return AccessoryLibraryData.fill(mainLiftID: day.mainExerciseID, goal: day.goal, otherDays: others.map(patterns(of:)),
                                         usedElsewhere: used).map { plan($0, goal: day.goal, unit: unit) }
    }

    /// Fill every day in order, each complementing the days before it.
    static func fillAll(_ days: [ProgramDay], unit: WeightUnit) -> [ProgramDay] {
        var out = days
        for i in out.indices {
            out[i].accessories = []
        }
        for i in out.indices {
            out[i].accessories = fill(out[i], in: out, unit: unit)
        }
        return out
    }

    static func balance(_ days: [ProgramDay]) -> [PatternBalance.Day] {
        days.map { d in
            PatternBalance.Day(name: d.name, main: AccessoryLibraryData.pattern(ofMainLift: d.mainExerciseID),
                               accessories: d.accessories.flatMap { $0.exercise?.patterns ?? [] })
        }
    }
}
