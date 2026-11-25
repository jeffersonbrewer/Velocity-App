import Foundation

// Accessory work organized by movement pattern rather than muscle group. Each exercise is tagged
// with every pattern it trains, so combos (for example an overhead press to reverse lunge) count
// toward several patterns. Days are filled with one slot that supports the main lift's pattern and
// the rest from patterns the week covers least.

public enum MovementPattern: String, Codable, CaseIterable, Identifiable, Sendable {
    case squat = "Squat"
    case lunge = "Lunge / single leg"
    case hinge = "Hinge"
    case horizontalPush = "Horizontal push"
    case verticalPush = "Vertical push"
    case horizontalPull = "Horizontal pull"
    case verticalPull = "Vertical pull"
    case carry = "Carry"
    case antiExtension = "Core: anti-extension"
    case antiRotation = "Core: anti-rotation"
    case arms = "Arms"
    case jumpThrow = "Jump / throw"

    public var id: String { rawValue }

    /// Patterns that count as the same family for weekly balance.
    public var family: String {
        switch self {
        case .squat, .lunge: return "Squat / lunge"
        case .hinge: return "Hinge"
        case .horizontalPush, .verticalPush: return "Push"
        case .horizontalPull, .verticalPull: return "Pull"
        case .carry, .antiExtension, .antiRotation: return "Core / carry"
        case .arms: return "Arms"
        case .jumpThrow: return "Jump / throw"
        }
    }
}

public enum Equipment: String, Codable, CaseIterable, Sendable {
    case barbell = "Barbell", dumbbell = "Dumbbell", kettlebell = "Kettlebell", bodyweight = "Bodyweight",
         cable = "Cable / machine", medicineBall = "Medicine ball"
}

public struct AccessoryExercise: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var patterns: [MovementPattern]
    public var equipment: Equipment
    /// Two or more movements done back to back as one rep.
    public var isCombo: Bool
    /// Fast or skill work that progresses by reps and quality, not load.
    public var ballistic: Bool

    public init(_ id: String, _ name: String, _ patterns: [MovementPattern], _ equipment: Equipment,
                combo: Bool = false, ballistic: Bool = false) {
        self.id = id; self.name = name; self.patterns = patterns; self.equipment = equipment
        self.isCombo = combo; self.ballistic = ballistic
    }

    /// Loaded with a weight the lifter chooses (dumbbell loads are per hand).
    /// Any implement takes a load, ballistic ones too (a dynamic curl or a swing still uses a weight).
    public var takesLoad: Bool { equipment != .bodyweight }
}

public enum AccessoryLibraryData {
    public static let all: [AccessoryExercise] = [
        // Squat / lunge
        AccessoryExercise("goblet_squat", "Goblet squat", [.squat, .antiExtension], .kettlebell),
        AccessoryExercise("db_front_squat", "Dumbbell front squat", [.squat], .dumbbell),
        AccessoryExercise("leg_press", "Leg press", [.squat], .cable),
        AccessoryExercise("bulgarian_split_squat", "Bulgarian split squat", [.lunge], .dumbbell),
        AccessoryExercise("reverse_lunge", "Dumbbell reverse lunge", [.lunge], .dumbbell),
        AccessoryExercise("walking_lunge", "Walking lunge", [.lunge, .carry], .dumbbell),
        AccessoryExercise("step_up", "Dumbbell step-up", [.lunge], .dumbbell),
        AccessoryExercise("lateral_lunge", "Lateral lunge", [.lunge], .dumbbell),
        AccessoryExercise("front_rack_reverse_lunge", "KB front-rack reverse lunge", [.lunge, .antiExtension], .kettlebell),
        // Hinge
        AccessoryExercise("rdl", "Romanian deadlift", [.hinge], .barbell),
        AccessoryExercise("db_rdl", "Dumbbell Romanian deadlift", [.hinge], .dumbbell),
        AccessoryExercise("sa_kb_deadlift", "Single-arm kettlebell deadlift", [.hinge, .antiRotation], .kettlebell),
        AccessoryExercise("sl_rdl", "Single-leg RDL", [.hinge, .lunge, .antiRotation], .dumbbell),
        AccessoryExercise("kb_swing", "Kettlebell swing", [.hinge, .jumpThrow], .kettlebell, ballistic: true),
        AccessoryExercise("back_extension", "Back extension", [.hinge], .bodyweight),
        AccessoryExercise("hamstring_curl", "Hamstring curl", [.hinge], .cable),
        AccessoryExercise("glute_bridge", "Single-leg glute bridge", [.hinge], .bodyweight),
        // Horizontal push
        AccessoryExercise("db_bench", "Dumbbell bench press", [.horizontalPush], .dumbbell),
        AccessoryExercise("sa_db_bench", "Single-arm dumbbell bench press", [.horizontalPush, .antiRotation], .dumbbell),
        AccessoryExercise("db_incline", "Incline dumbbell press", [.horizontalPush, .verticalPush], .dumbbell),
        AccessoryExercise("push_up", "Push-up", [.horizontalPush, .antiExtension], .bodyweight),
        AccessoryExercise("weighted_dip", "Weighted dip", [.verticalPush, .arms], .bodyweight),
        // Vertical push
        AccessoryExercise("db_ohp", "Dumbbell overhead press", [.verticalPush], .dumbbell),
        AccessoryExercise("half_kneeling_press", "Half-kneeling single-arm press", [.verticalPush, .antiRotation], .kettlebell),
        AccessoryExercise("landmine_press", "Landmine press", [.verticalPush, .horizontalPush, .antiRotation], .barbell),
        AccessoryExercise("push_press", "Push press", [.verticalPush, .jumpThrow], .barbell),
        // Horizontal pull
        AccessoryExercise("db_row", "Single-arm dumbbell row", [.horizontalPull, .antiRotation], .dumbbell),
        AccessoryExercise("barbell_row", "Barbell row", [.horizontalPull, .hinge], .barbell),
        AccessoryExercise("chest_supported_row", "Chest-supported dumbbell row", [.horizontalPull], .dumbbell),
        AccessoryExercise("inverted_row", "Inverted row", [.horizontalPull, .antiExtension], .bodyweight),
        AccessoryExercise("face_pull", "Face pull", [.horizontalPull], .cable),
        AccessoryExercise("renegade_row", "Renegade row", [.horizontalPull, .antiRotation, .antiExtension], .dumbbell),
        // Vertical pull
        AccessoryExercise("pull_up_acc", "Pull-up", [.verticalPull], .bodyweight),
        AccessoryExercise("chin_up", "Chin-up", [.verticalPull, .arms], .bodyweight),
        AccessoryExercise("lat_pulldown", "Lat pulldown", [.verticalPull], .cable),
        AccessoryExercise("sa_pulldown", "Single-arm cable pulldown", [.verticalPull, .antiRotation], .cable),
        // Carry and core
        AccessoryExercise("farmer_carry", "Farmer carry", [.carry], .kettlebell),
        AccessoryExercise("suitcase_carry", "Suitcase carry", [.carry, .antiRotation], .kettlebell),
        AccessoryExercise("front_rack_carry", "Front-rack carry", [.carry, .antiExtension], .kettlebell),
        AccessoryExercise("pallof_press", "Pallof press", [.antiRotation], .cable),
        AccessoryExercise("dead_bug", "Dead bug", [.antiExtension], .bodyweight),
        AccessoryExercise("ab_wheel", "Ab wheel rollout", [.antiExtension], .bodyweight),
        AccessoryExercise("toes_to_bar", "Toes-to-bar", [.antiExtension, .verticalPull], .bodyweight, ballistic: true),
        AccessoryExercise("side_plank", "Side plank", [.antiRotation], .bodyweight),
        AccessoryExercise("landmine_rotation", "Landmine rotation", [.antiRotation, .jumpThrow], .barbell, ballistic: true),
        // Arms
        AccessoryExercise("hammer_curl", "Hammer curl", [.arms], .dumbbell),
        AccessoryExercise("dynamic_hammer_curl", "Dynamic hammer curl", [.arms], .dumbbell, ballistic: true),
        AccessoryExercise("db_curl", "Dumbbell curl", [.arms], .dumbbell),
        AccessoryExercise("triceps_extension", "Overhead triceps extension", [.arms], .dumbbell),
        AccessoryExercise("cable_pushdown", "Triceps pushdown", [.arms], .cable),
        // Jumps and throws
        AccessoryExercise("box_jump", "Box jump", [.jumpThrow, .squat], .bodyweight, ballistic: true),
        AccessoryExercise("broad_jump", "Broad jump", [.jumpThrow, .hinge], .bodyweight, ballistic: true),
        AccessoryExercise("mb_chest_pass", "Medicine ball chest pass", [.jumpThrow, .horizontalPush], .medicineBall, ballistic: true),
        AccessoryExercise("mb_slam", "Medicine ball slam", [.jumpThrow, .verticalPull], .medicineBall, ballistic: true),
        AccessoryExercise("mb_rotational_throw", "Rotational medicine ball throw", [.jumpThrow, .antiRotation], .medicineBall, ballistic: true),
        // Combos
        AccessoryExercise("ohp_to_reverse_lunge", "DB overhead press to reverse lunge", [.verticalPush, .lunge, .antiExtension], .dumbbell, combo: true),
        AccessoryExercise("rdl_to_row", "DB RDL to bent-over row", [.hinge, .horizontalPull], .dumbbell, combo: true),
        AccessoryExercise("squat_to_press", "DB squat to press (thruster)", [.squat, .verticalPush], .dumbbell, combo: true),
        AccessoryExercise("lunge_to_curl", "Reverse lunge to hammer curl", [.lunge, .arms], .dumbbell, combo: true),
        AccessoryExercise("swing_to_squat", "KB swing to goblet squat", [.hinge, .squat, .jumpThrow], .kettlebell, combo: true),
        AccessoryExercise("deadlift_to_carry", "Single-arm KB deadlift to suitcase carry", [.hinge, .carry, .antiRotation], .kettlebell, combo: true),
        AccessoryExercise("pushup_to_row", "Push-up to renegade row", [.horizontalPush, .horizontalPull, .antiRotation], .dumbbell, combo: true),
        AccessoryExercise("step_up_to_press", "Step-up to single-arm press", [.lunge, .verticalPush, .antiRotation], .dumbbell, combo: true),
    ]

    public static func exercise(id: String) -> AccessoryExercise? { all.first { $0.id == id } }

    /// The pattern a main lift trains.
    public static func pattern(ofMainLift id: String) -> MovementPattern {
        switch id {
        case "back_squat", "front_squat", "box_squat": return .squat
        case "bench_press": return .horizontalPush
        case "overhead_press", "dip", "push_jerk", "split_jerk": return .verticalPush
        case "prone_bench_pull", "pendlay_row": return .horizontalPull
        case "pull_up": return .verticalPull
        default: return .hinge   // deadlifts, hip thrust, power clean
        }
    }

    /// Patterns in the order they're used to complement a day, most general first.
    static let complementOrder: [MovementPattern] = [.hinge, .lunge, .horizontalPull, .verticalPush, .verticalPull,
                                                     .horizontalPush, .squat, .antiRotation, .carry, .antiExtension, .arms]

    /// Fill a day's accessory slots.
    /// - Slot 1 supports the main lift's pattern (a general variation, not the lift itself).
    /// - The rest take the patterns the week covers least, preferring a combo when it covers two
    ///   uncovered patterns, and exercises not already used elsewhere in the week.
    /// - Power days start with a jump or throw.
    public static func fill(mainLiftID: String, goal: TrainingGoal, otherDays: [[MovementPattern]],
                            usedElsewhere: Set<String>) -> [AccessoryExercise] {
        let slots = GoalTemplate.default(goal).accessorySlots
        let main = pattern(ofMainLift: mainLiftID)
        var picked: [AccessoryExercise] = []
        var counts: [MovementPattern: Int] = [:]
        for p in otherDays.flatMap({ $0 }) + [main] { counts[p, default: 0] += 1 }
        func fresh(_ e: AccessoryExercise) -> Bool { !picked.contains(e) && !usedElsewhere.contains(e.id) }
        func add(_ e: AccessoryExercise) { picked.append(e); for p in e.patterns { counts[p, default: 0] += 1 } }

        if goal == .power, let jump = all.first(where: { $0.ballistic && $0.patterns.first == .jumpThrow && $0.patterns.contains(main) })
            ?? all.first(where: { $0.patterns == [.jumpThrow, .squat] }) {
            add(jump)
        }
        // Focus slot: same pattern as the main lift, straight sets.
        if picked.count < slots, let focus = all.first(where: { $0.patterns.first == main && !$0.isCombo && !$0.ballistic && fresh($0) })
            ?? all.first(where: { $0.patterns.contains(main) && !$0.ballistic && fresh($0) }) {
            add(focus)
        }
        while picked.count < slots {
            let need = complementOrder.filter { $0 != main }.sorted { (counts[$0] ?? 0) < (counts[$1] ?? 0) }
            guard let first = need.first else { break }
            let uncovered = Set(need.filter { (counts[$0] ?? 0) == (counts[first] ?? 0) })
            // A combo that hits two of the least-covered patterns, else a straight exercise for the first.
            let combo = all.first { $0.isCombo && fresh($0) && $0.patterns.filter(uncovered.contains).count >= 2 && !$0.patterns.contains(main) }
            let single = all.first { $0.patterns.first == first && !$0.ballistic && fresh($0) }
                ?? all.first { $0.patterns.contains(first) && fresh($0) }
            guard let e = (picked.contains(where: \.isCombo) ? nil : combo) ?? single ?? combo else { break }
            add(e)
        }
        return picked
    }
}

/// Weekly balance across a program's days.
public enum PatternBalance {
    /// Each day: the main lift's pattern and the accessories' patterns.
    public struct Day: Sendable {
        public var name: String
        public var main: MovementPattern
        public var accessories: [MovementPattern]
        public init(name: String, main: MovementPattern, accessories: [MovementPattern]) {
            self.name = name; self.main = main; self.accessories = accessories
        }
        var all: [MovementPattern] { [main] + accessories }
    }

    /// Times each family is trained in a week.
    public static func counts(_ days: [Day]) -> [String: Int] {
        var c: [String: Int] = [:]
        for d in days { for p in d.all { c[p.family, default: 0] += 1 } }
        return c
    }

    /// Gaps and overlaps worth a look. Never blocking: the coach decides.
    public static func flags(_ days: [Day]) -> [String] {
        let c = counts(days)
        var out: [String] = []
        for f in ["Squat / lunge", "Hinge", "Push", "Pull", "Core / carry"] where (c[f] ?? 0) == 0 {
            out.append("No \(f.lowercased()) work this week.")
        }
        let push = c["Push"] ?? 0, pull = c["Pull"] ?? 0
        if push >= pull + 2 { out.append("Pushing outweighs pulling (\(push) to \(pull)).") }
        if pull >= push + 2 { out.append("Pulling outweighs pushing (\(pull) to \(push)).") }
        // A hinge accessory the session before a hinge main lift (sessions in order, wrapping round).
        if days.count > 1 {
            for i in days.indices {
                let next = days[(i + 1) % days.count]
                if next.main == .hinge && days[i].accessories.contains(.hinge) && i != (i + 1) % days.count {
                    out.append("\(days[i].name) has hinge accessories right before \(next.name)'s hinge main lift.")
                }
            }
        }
        return out
    }
}
