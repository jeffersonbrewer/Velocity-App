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
        let days = (0..<daysPerWeek).map { i in
            ProgramDay(name: names[i], mainExerciseID: exerciseID, goal: goal,
                       accessories: (0..<t.accessorySlots).map { j in
                           AccessoryPlan(name: "Accessory \(j + 1)", sets: t.accessorySets, repLow: t.accessoryRepLow,
                                         repHigh: t.accessoryRepHigh, loadKg: 0, stepKg: unit.toKg(unit.step))
                       })
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
