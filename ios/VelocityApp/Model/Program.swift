import Foundation
import VelocityCore

/// One session of the week: a main lift with its goal, plus accessories.
struct ProgramDay: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var mainExerciseID: String
    var goal: TrainingGoal
    var accessories: [AccessoryPlan] = []
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

    var currentDay: ProgramDay? { progress.finished || days.isEmpty ? nil : days[min(progress.day, days.count - 1)] }

    func weekPlans(for day: ProgramDay) -> [WeekPlan] {
        BlockPlanner.weeks(for: .default(day.goal), count: weeks)
    }

    /// This session's week plan: the block week, or deload values during a responsive deload.
    func weekPlan(for day: ProgramDay) -> WeekPlan {
        if progress.inResponsiveDeload { return BlockPlanner.deload(for: .default(day.goal)) }
        let plans = weekPlans(for: day)
        return plans[min(max(progress.week - 1, 0), plans.count - 1)]
    }

    /// A starting block for a goal: up to 3 days with that goal and its accessory slots, named but empty.
    static func starter(goal: TrainingGoal, exerciseID: String, daysPerWeek: Int, unit: WeightUnit) -> Program {
        let t = GoalTemplate.default(goal)
        let names = ["Day A", "Day B", "Day C", "Day D"]
        _ = t
        let days = (0..<daysPerWeek).map { i in
            ProgramDay(name: names[i], mainExerciseID: exerciseID, goal: goal,
                       accessories: AccessoryLibrary.defaults(for: exerciseID, goal: goal, unit: unit))
        }
        return Program(days: days)
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

/// Related but more general accessory work for each main lift, used to fill a day's accessory slots.
enum AccessoryLibrary {
    static func options(for mainLiftID: String) -> [String] {
        switch mainLiftID {
        case "trap_bar_deadlift", "deadlift", "sumo_deadlift":
            return ["Romanian deadlift", "Bulgarian split squat", "Back extension", "Hamstring curl", "Barbell row", "Plank"]
        case "back_squat", "front_squat", "box_squat":
            return ["Bulgarian split squat", "Romanian deadlift", "Leg press", "Walking lunge", "Hamstring curl", "Plank"]
        case "bench_press":
            return ["Dumbbell bench press", "Barbell row", "Weighted dip", "Triceps extension", "Face pull"]
        case "overhead_press":
            return ["Dumbbell shoulder press", "Pull-up", "Lateral raise", "Triceps extension", "Face pull"]
        case "hip_thrust":
            return ["Romanian deadlift", "Bulgarian split squat", "Hamstring curl", "Back extension"]
        case "prone_bench_pull", "pendlay_row", "pull_up":
            return ["Dumbbell row", "Lat pulldown", "Face pull", "Biceps curl", "Barbell row"]
        case "dip":
            return ["Dumbbell bench press", "Triceps extension", "Push-up", "Dumbbell row"]
        case "power_clean":
            return ["Romanian deadlift", "Front squat", "Push press", "Box jump"]
        default:
            return ["Romanian deadlift", "Bulgarian split squat", "Dumbbell row", "Plank"]
        }
    }

    /// Jumps and throws that go first on power days.
    static func powerOptions(for mainLiftID: String) -> [String] {
        switch mainLiftID {
        case "bench_press", "overhead_press", "dip": return ["Medicine ball chest pass"]
        case "prone_bench_pull", "pendlay_row", "pull_up": return ["Medicine ball slam"]
        default: return ["Box jump"]
        }
    }

    static func plan(_ name: String, goal: TrainingGoal, unit: WeightUnit) -> AccessoryPlan {
        let t = GoalTemplate.default(goal)
        return AccessoryPlan(name: name, sets: t.accessorySets, repLow: t.accessoryRepLow, repHigh: t.accessoryRepHigh,
                             loadKg: 0, stepKg: unit.toKg(unit.step))
    }

    /// The goal's number of slots, filled from the main lift's list (power: a jump or throw first).
    static func defaults(for mainLiftID: String, goal: TrainingGoal, unit: WeightUnit) -> [AccessoryPlan] {
        let slots = GoalTemplate.default(goal).accessorySlots
        var names = options(for: mainLiftID)
        if goal == .power { names = powerOptions(for: mainLiftID) + names }
        return names.prefix(slots).map { n in
            var a = plan(n, goal: goal, unit: unit)
            if powerOptions(for: mainLiftID).contains(n) { a.repLow = 3; a.repHigh = 5 }
            return a
        }
    }
}
