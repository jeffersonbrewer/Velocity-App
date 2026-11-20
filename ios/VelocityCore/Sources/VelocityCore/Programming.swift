import Foundation

// Velocity-based programming engine, following the "Velocity-Based Programming Spec" (Nov 2026).
// The lifter (coach) sets the rules in %1RM; the engine turns them into loads and target velocities
// from each lifter's strength profile, adjusts for today's readiness, and decides when to stop.
// All numbers here are the spec's draft values and are meant to be edited.

/// A training goal and its rules.
public enum TrainingGoal: String, Codable, CaseIterable, Identifiable, Sendable {
    case maxStrength = "Maximal strength"
    case peaking = "Peaking"
    case power = "Power"
    case strengthSpeed = "Strength-speed"
    case hypertrophy = "Hypertrophy"
    case endurance = "Muscular endurance"

    public var id: String { rawValue }

    /// The goal used on a Well down day.
    public var lighter: TrainingGoal {
        switch self {
        case .peaking: return .maxStrength
        case .maxStrength: return .strengthSpeed
        case .strengthSpeed: return .power
        case .hypertrophy: return .endurance
        case .power, .endurance: return self
        }
    }
}

/// The spec's goal templates table, plus the session rep caps.
public struct GoalTemplate: Codable, Hashable, Sendable {
    public var goal: TrainingGoal
    public var pctLow: Double, pctHigh: Double          // fraction of 1RM
    public var lossLow: Double, lossHigh: Double        // velocity-loss cutoff, %
    public var setsLow: Int, setsHigh: Int
    public var repCapPerSet: Int
    public var restLowMin: Double, restHighMin: Double
    public var sessionRepCapLow: Int, sessionRepCapHigh: Int
    public var accessorySlots: Int
    public var accessorySets: Int
    public var accessoryRepLow: Int, accessoryRepHigh: Int

    public static func `default`(_ g: TrainingGoal) -> GoalTemplate {
        switch g {
        case .maxStrength:
            return GoalTemplate(goal: g, pctLow: 0.80, pctHigh: 0.90, lossLow: 15, lossHigh: 20, setsLow: 3, setsHigh: 5, repCapPerSet: 6,
                                restLowMin: 3, restHighMin: 5, sessionRepCapLow: 15, sessionRepCapHigh: 25,
                                accessorySlots: 3, accessorySets: 3, accessoryRepLow: 6, accessoryRepHigh: 10)
        case .peaking:
            return GoalTemplate(goal: g, pctLow: 0.90, pctHigh: 1.00, lossLow: 5, lossHigh: 10, setsLow: 2, setsHigh: 4, repCapPerSet: 3,
                                restLowMin: 4, restHighMin: 6, sessionRepCapLow: 6, sessionRepCapHigh: 10,
                                accessorySlots: 2, accessorySets: 2, accessoryRepLow: 8, accessoryRepHigh: 12)
        case .power:
            return GoalTemplate(goal: g, pctLow: 0.30, pctHigh: 0.60, lossLow: 10, lossHigh: 10, setsLow: 3, setsHigh: 6, repCapPerSet: 6,
                                restLowMin: 2, restHighMin: 3, sessionRepCapLow: 18, sessionRepCapHigh: 30,
                                accessorySlots: 2, accessorySets: 3, accessoryRepLow: 3, accessoryRepHigh: 5)
        case .strengthSpeed:
            return GoalTemplate(goal: g, pctLow: 0.60, pctHigh: 0.75, lossLow: 10, lossHigh: 15, setsLow: 3, setsHigh: 5, repCapPerSet: 6,
                                restLowMin: 2, restHighMin: 4, sessionRepCapLow: 15, sessionRepCapHigh: 25,
                                accessorySlots: 2, accessorySets: 3, accessoryRepLow: 6, accessoryRepHigh: 10)
        case .hypertrophy:
            return GoalTemplate(goal: g, pctLow: 0.65, pctHigh: 0.80, lossLow: 25, lossHigh: 40, setsLow: 3, setsHigh: 5, repCapPerSet: 15,
                                restLowMin: 1.5, restHighMin: 3, sessionRepCapLow: 30, sessionRepCapHigh: 50,
                                accessorySlots: 4, accessorySets: 3, accessoryRepLow: 8, accessoryRepHigh: 15)
        case .endurance:
            return GoalTemplate(goal: g, pctLow: 0.40, pctHigh: 0.60, lossLow: 40, lossHigh: 50, setsLow: 2, setsHigh: 4, repCapPerSet: 25,
                                restLowMin: 1, restHighMin: 2, sessionRepCapLow: 50, sessionRepCapHigh: 80,
                                accessorySlots: 3, accessorySets: 2, accessoryRepLow: 12, accessoryRepHigh: 20)
        }
    }
}

/// What one week of a block asks for on a given goal.
public struct WeekPlan: Codable, Hashable, Sendable {
    public var pctLow: Double
    public var pctHigh: Double
    public var lossCutoffPct: Double
    public var sets: Int
    public var isDeload: Bool
    public var note: String?

    public var pctMid: Double { (pctLow + pctHigh) / 2 }
}

public enum BlockPlanner {
    /// The spec's 6-week maximal strength block for most lifters.
    static let maxStrength6: [WeekPlan] = [
        WeekPlan(pctLow: 0.74, pctHigh: 0.76, lossCutoffPct: 20, sets: 4, isDeload: false, note: "Introduce the block"),
        WeekPlan(pctLow: 0.77, pctHigh: 0.79, lossCutoffPct: 20, sets: 4, isDeload: false, note: nil),
        WeekPlan(pctLow: 0.80, pctHigh: 0.82, lossCutoffPct: 20, sets: 4, isDeload: false, note: nil),
        WeekPlan(pctLow: 0.83, pctHigh: 0.85, lossCutoffPct: 20, sets: 4, isDeload: false, note: nil),
        WeekPlan(pctLow: 0.86, pctHigh: 0.88, lossCutoffPct: 15, sets: 5, isDeload: false, note: "Highest stress"),
        WeekPlan(pctLow: 0.70, pctHigh: 0.75, lossCutoffPct: 10, sets: 3, isDeload: true, note: "Deload, then profile test at the end of the week"),
    ]

    /// Week-by-week plan for a goal. The last week is always a deload. Maximal strength over 6
    /// weeks uses the spec's table; other goals climb evenly through their intensity range, with
    /// the loss cutoff tightening from the top of its range to the bottom.
    public static func weeks(for t: GoalTemplate, count: Int) -> [WeekPlan] {
        let n = max(2, count)
        if t.goal == .maxStrength && n == 6 && t == .default(.maxStrength) { return maxStrength6 }
        var out: [WeekPlan] = []
        let loading = n - 1
        for w in 0..<loading {
            let f = loading == 1 ? 1 : Double(w) / Double(loading - 1)
            let mid = t.pctLow + (t.pctHigh - t.pctLow) * f
            let half = min(0.01, (t.pctHigh - t.pctLow) / 2)
            let loss = (t.lossHigh - (t.lossHigh - t.lossLow) * f).rounded()
            let sets = Int((Double(t.setsLow) + Double(t.setsHigh - t.setsLow) * f).rounded())
            out.append(WeekPlan(pctLow: max(t.pctLow, mid - half), pctHigh: min(t.pctHigh, mid + half), lossCutoffPct: loss,
                                sets: sets, isDeload: false, note: w == 0 ? "Introduce the block" : (w == loading - 1 ? "Highest stress" : nil)))
        }
        out.append(deload(for: t))
        return out
    }

    /// Deload week: lighter, fewer sets, a tight loss cutoff. Never heavier than the goal itself.
    public static func deload(for t: GoalTemplate) -> WeekPlan {
        let hi = min(0.75, t.pctLow + 0.05)
        let lo = min(0.70, hi - 0.05)
        return WeekPlan(pctLow: lo, pctHigh: hi, lossCutoffPct: min(10, t.lossLow), sets: max(2, t.setsLow - 1),
                        isDeload: true, note: "Deload, then profile test at the end of the week")
    }
}

/// Readiness adjustments from the spec's table: load change and set change.
public extension Readiness {
    var loadChange: Double {
        switch self {
        case .veryGood: return 0.05
        case .good: return 0.025
        case .normal: return 0
        case .slightlyDown: return -0.025
        case .down: return -0.05
        case .wellDown: return -0.10
        }
    }
    var setChange: Int { self == .down ? -1 : 0 }
    var isDown: Bool { self == .down || self == .wellDown }
    var isNormalOrBetter: Bool { self == .normal || self == .good || self == .veryGood }
}

/// Today's prescription for a main lift.
public struct MainLiftPrescription: Codable, Hashable, Sendable {
    public var goal: TrainingGoal
    public var week: WeekPlan
    public var plannedLoadKg: Double     // before readiness
    public var loadKg: Double            // after readiness, rounded
    // Nil when the 1RM was entered by hand and there's no load-velocity profile yet.
    public var targetVelocity: Double?   // profile's mean velocity at loadKg
    public var zoneLow: Double?          // velocity at the heavy end of the week's %1RM range
    public var zoneHigh: Double?         // velocity at the light end
    public var sets: Int
    public var repCapPerSet: Int
    public var sessionRepCap: Int
    public var lossCutoffPct: Double
    public var restLowMin: Double, restHighMin: Double
    /// Loads between sets stay within this range (±5% of plan).
    public var minLoadKg: Double, maxLoadKg: Double
    public var notes: [String]
}

public enum Prescriber {
    /// Convert a week's %1RM into a load and target velocity for this lifter, then adjust for readiness.
    /// - Parameter round: rounds a load in kg to the lifter's load step.
    public static func mainLift(goal: TrainingGoal, template: GoalTemplate, week: WeekPlan, oneRmKg: Double,
                                line: LoadVelocityLine?, readiness: Readiness?, round: (Double) -> Double) -> MainLiftPrescription {
        var goal = goal, template = template, week = week
        var notes: [String] = []
        if readiness == .wellDown && !week.isDeload && goal.lighter != goal {
            notes.append("Well down today: switched from \(goal.rawValue.lowercased()) to \(goal.lighter.rawValue.lowercased()).")
            goal = goal.lighter
            template = .default(goal)
            let mid = (template.pctLow + template.pctHigh) / 2
            week = WeekPlan(pctLow: mid - 0.01, pctHigh: mid + 0.01, lossCutoffPct: template.lossLow,
                            sets: template.setsLow, isDeload: false, note: nil)
        }
        let planned = round(week.pctMid * oneRmKg)
        let change = week.isDeload ? min(0, readiness?.loadChange ?? 0) : (readiness?.loadChange ?? 0)
        let load = round(planned * (1 + change))
        if let r = readiness, change != 0 {
            notes.append(String(format: "%@ day: load %+.1f%%.", r.rawValue, change * 100))
        }
        var sets = week.sets + (readiness?.setChange ?? 0)
        if readiness?.setChange ?? 0 != 0 { notes.append("Down day: one set fewer.") }
        sets = max(1, sets)
        let zoneLow = line?.velocity(atLoad: week.pctHigh * oneRmKg * (1 + change))
        let zoneHigh = line?.velocity(atLoad: week.pctLow * oneRmKg * (1 + change))
        let sessionCap = (template.sessionRepCapLow + template.sessionRepCapHigh) / 2
        return MainLiftPrescription(goal: goal, week: week, plannedLoadKg: planned, loadKg: load,
                                    targetVelocity: line?.velocity(atLoad: load), zoneLow: zoneLow, zoneHigh: zoneHigh,
                                    sets: sets, repCapPerSet: template.repCapPerSet, sessionRepCap: sessionCap,
                                    lossCutoffPct: week.lossCutoffPct, restLowMin: template.restLowMin, restHighMin: template.restHighMin,
                                    minLoadKg: planned * 0.95, maxLoadKg: planned * 1.05, notes: notes)
    }

    /// The next set's load from the first rep of the set just done: one load step up if it was
    /// faster than the zone, down if slower, kept within ±5% of the planned load.
    public static func nextLoad(after loadKg: Double, firstRepMV: Double, prescription p: MainLiftPrescription,
                                stepKg: Double) -> (loadKg: Double, reason: String?) {
        var next = loadKg
        var reason: String?
        guard let zoneLow = p.zoneLow, let zoneHigh = p.zoneHigh else { return (loadKg, nil) }
        if firstRepMV > zoneHigh {
            next = loadKg + stepKg; reason = "First rep was faster than the zone, so the load goes up."
        } else if firstRepMV < zoneLow {
            next = loadKg - stepKg; reason = "First rep was slower than the zone, so the load comes down."
        }
        if next > p.maxLoadKg + 1e-6 || next < p.minLoadKg - 1e-6 {
            next = loadKg
            reason = "The load stays: today's changes are capped at 5% of the plan."
        }
        return (next, reason)
    }

    /// Whether the main lift is finished for today.
    public static func liftDone(setsDone: Int, repsDone: Int, prescription p: MainLiftPrescription) -> String? {
        if setsDone >= p.sets { return "All \(p.sets) sets done." }
        if repsDone >= p.sessionRepCap { return "Session rep cap of \(p.sessionRepCap) reached." }
        return nil
    }
}

// MARK: Accessories

/// An accessory: sets × a rep range × a load, progressed by double progression.
public struct AccessoryPlan: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var sets: Int
    public var repLow: Int
    public var repHigh: Int
    public var loadKg: Double
    public var stepKg: Double
    /// The library exercise this slot uses (nil: typed by hand).
    public var exerciseID: String?
    /// Reps in reserve to stop each set at (nil: 2).
    public var targetRIR: Int?

    public init(name: String, sets: Int, repLow: Int, repHigh: Int, loadKg: Double, stepKg: Double,
                exerciseID: String? = nil, targetRIR: Int? = nil) {
        self.name = name; self.sets = sets; self.repLow = repLow; self.repHigh = repHigh; self.loadKg = loadKg; self.stepKg = stepKg
        self.exerciseID = exerciseID; self.targetRIR = targetRIR
    }

    public var rir: Int { targetRIR ?? 2 }
    public var exercise: AccessoryExercise? { exerciseID.flatMap(AccessoryLibraryData.exercise(id:)) }
    /// Reps the load is chosen for: the middle of the range.
    public var targetReps: Int { (repLow + repHigh) / 2 }

    /// Today's sets after readiness: one fewer on a Down day, none on a Well down day.
    public func sets(for readiness: Readiness?) -> Int {
        switch readiness {
        case .wellDown: return 0
        case .down: return max(1, sets - 1)
        default: return sets
        }
    }

    /// The next session's plan from today's sets.
    ///
    /// With reps in reserve logged, each set gives an estimated rep max (Epley with RIR:
    /// load × (1 + (reps + RIR) / 30)); the best one sets the load for the middle of the rep range
    /// at the target RIR, kept within ±15% per session and rounded by `round`. Without RIR, or for
    /// unloaded work, it falls back to double progression.
    public func next(after done: [AccessorySet], round: (Double) -> Double) -> (plan: AccessoryPlan, note: String?) {
        let valid = done.filter { $0.reps > 0 }
        guard !valid.isEmpty else { return (self, nil) }
        if loadKg <= 0 {
            if valid.count >= sets && valid.allSatisfy({ $0.reps >= repHigh && ($0.rir ?? rir) >= rir }) {
                return (self, "\(name): top of the range on every set. Add load or a harder variation.")
            }
            return (self, nil)
        }
        let withRIR = valid.filter { $0.rir != nil }
        guard withRIR.count == valid.count else {
            let p = progressed(repsPerSet: valid.map(\.reps))
            return (p, p.loadKg != loadKg ? "\(name): every set reached \(repHigh), so one step up." : nil)
        }
        let e = withRIR.map { AccessorySet.repMax(loadKg: loadKg, reps: $0.reps, rir: $0.rir!) }.max()!
        var target = round(e / (1 + Double(targetReps + rir) / 30))
        target = min(max(target, round(loadKg * 0.85)), round(loadKg * 1.15))
        var p = self
        p.loadKg = target
        return (p, target == loadKg ? nil : "\(name): next load set from your reps and RIR.")
    }

    /// Double progression: when every set reached the top of the range, add one load step.
    public func progressed(repsPerSet: [Int]) -> AccessoryPlan {
        guard !repsPerSet.isEmpty, repsPerSet.count >= sets, repsPerSet.allSatisfy({ $0 >= repHigh }) else { return self }
        var next = self
        next.loadKg += stepKg
        return next
    }
}

/// One logged accessory set.
public struct AccessorySet: Codable, Hashable, Sendable {
    public var reps: Int
    public var rir: Int?
    public init(reps: Int, rir: Int?) { self.reps = reps; self.rir = rir }

    /// Estimated 1-rep max from a set taken to `rir` reps in reserve (Epley).
    public static func repMax(loadKg: Double, reps: Int, rir: Int) -> Double { loadKg * (1 + Double(reps + rir) / 30) }

    /// The load to start with when a lifter knows a load they can do for some reps.
    public static func load(forReps reps: Int, rir: Int, repMaxKg: Double) -> Double { repMaxKg / (1 + Double(reps + rir) / 30) }
}

// MARK: Block progress, responsive deloads and retests

/// Where the lifter is in a block, advanced once per finished session.
public struct BlockProgress: Codable, Hashable, Sendable {
    public var week = 1                 // 1-based
    public var day = 0                  // index into the week's sessions
    public var deloadSessionsLeft = 0   // responsive deload sessions still to do
    public var deloadSessionsDone = 0
    public var recentReadings: [Readiness] = []
    public var finished = false
    public var retestDue = false
    public var lastEvent: String?

    public init() {}

    public var inResponsiveDeload: Bool { deloadSessionsLeft > 0 }

    /// Record a finished session and its main-lift readiness reading.
    public mutating func finishSession(reading: Readiness?, weeks: Int, daysPerWeek: Int) {
        lastEvent = nil
        if let r = reading { recentReadings = Array((recentReadings + [r]).suffix(2)) }

        if inResponsiveDeload {
            deloadSessionsDone += 1
            if let r = reading, r.isNormalOrBetter {
                // Recovered: skip ahead by the sessions spent deloading so the block keeps its length.
                deloadSessionsLeft = 0
                lastEvent = "Readiness is back to normal, so the block skips ahead to stay on schedule."
                for _ in 0..<deloadSessionsDone { step(weeks: weeks, daysPerWeek: daysPerWeek) }
                deloadSessionsDone = 0
                recentReadings = []
            } else {
                deloadSessionsLeft -= 1
                if deloadSessionsLeft == 0 {
                    lastEvent = "Deload done. The block resumes at the same week."
                    deloadSessionsDone = 0
                    recentReadings = []
                }
            }
            return
        }

        step(weeks: weeks, daysPerWeek: daysPerWeek)
        guard !finished else { return }

        // Two Down (or Well down) sessions in a row suggest a deload.
        if recentReadings.count == 2 && recentReadings.allSatisfy(\.isDown) && week < weeks {
            recentReadings = []
            if week >= weeks - 2 {
                week = weeks; day = 0
                lastEvent = "Two Down sessions in a row near the end of the block: the planned deload starts now."
            } else {
                deloadSessionsLeft = 2
                deloadSessionsDone = 0
                lastEvent = "Two Down sessions in a row: the next 2 sessions are deload sessions."
            }
        }
    }

    private mutating func step(weeks: Int, daysPerWeek: Int) {
        day += 1
        if day >= daysPerWeek {
            day = 0
            week += 1
            if week > weeks {
                week = weeks; finished = true; retestDue = true
                lastEvent = "Block finished. Time for a profile test."
            }
        }
    }
}

// MARK: Early-retest check

public enum ProfileDrift {
    /// A working set's first rep compared with the profile.
    public struct Check: Sendable {
        public var date: Date
        public var loadKg: Double
        public var firstRepMV: Double
        public init(date: Date, loadKg: Double, firstRepMV: Double) { self.date = date; self.loadKg = loadKg; self.firstRepMV = firstRepMV }
    }

    /// The 1RM a set implies: the profile's slope moved to pass through this set, read at the 1RM velocity.
    public static func impliedOneRm(loadKg: Double, mv: Double, line: LoadVelocityLine, mvt: Double) -> Double {
        loadKg + (mvt - mv) / line.slope
    }

    /// Suggest an early retest when the last 3 or more sessions' sets imply, on average, a 1RM at
    /// least 5% away from the estimate, all in the same direction. Returns the average change.
    public static func retestSuggested(_ checks: [Check], line: LoadVelocityLine, mvt: Double, oneRmKg: Double,
                                       sessions: Int = 3, threshold: Double = 0.05, calendar: Calendar = .current) -> Double? {
        let byDay = Dictionary(grouping: checks) { calendar.startOfDay(for: $0.date) }
        let days = byDay.keys.sorted(by: >).prefix(sessions)
        guard days.count >= sessions else { return nil }
        let changes = days.map { d -> Double in
            let implied = byDay[d]!.map { impliedOneRm(loadKg: $0.loadKg, mv: $0.firstRepMV, line: line, mvt: mvt) }
            return implied.reduce(0, +) / Double(implied.count) / oneRmKg - 1
        }
        let avg = changes.reduce(0, +) / Double(changes.count)
        guard abs(avg) >= threshold, changes.allSatisfy({ ($0 > 0) == (avg > 0) }) else { return nil }
        return avg
    }
}
