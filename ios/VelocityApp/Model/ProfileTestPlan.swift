import Foundation
import VelocityCore

/// One load in a guided profile test.
struct ProfileTestStep: Identifiable, Hashable {
    var id = UUID()
    var loadKg: Double
    var reps: Int
    var isMaxSingle = false
    /// The saved set once this load is recorded.
    var setID: UUID?
    var bestMeanVelocity: Double?
    var skipped = false

    var done: Bool { setID != nil || skipped }
}

/// A ramp of loads from light to heavy, recorded in one camera session.
struct ProfileTestPlan: Identifiable, Hashable {
    var id = UUID()
    var exerciseID: String
    var steps: [ProfileTestStep]

    /// Evenly spaced loads from 40% to 90% of the estimated 1RM, rounded to the plate step, with
    /// 3 reps when light, 2 in the middle and 1 when heavy. Optionally a heavy single at 95%.
    static func make(exerciseID: String, oneRmKg: Double, loads: Int, maxSingle: Bool, unit: WeightUnit) -> ProfileTestPlan {
        var steps: [ProfileTestStep] = []
        let n = max(2, loads)
        for i in 0..<n {
            let pct = 0.40 + 0.50 * Double(i) / Double(n - 1)
            let kg = unit.roundedToStep(kg: oneRmKg * pct)
            if let last = steps.last, kg <= last.loadKg + 0.01 { continue }
            steps.append(ProfileTestStep(loadKg: kg, reps: reps(forPercent: pct)))
        }
        if maxSingle {
            steps.append(ProfileTestStep(loadKg: unit.roundedToStep(kg: oneRmKg * 0.95), reps: 1, isMaxSingle: true))
        }
        return ProfileTestPlan(exerciseID: exerciseID, steps: steps)
    }

    static func reps(forPercent pct: Double) -> Int { pct < 0.6 ? 3 : (pct < 0.8 ? 2 : 1) }

    var currentIndex: Int? { steps.firstIndex { !$0.done } }
    var finished: Bool { currentIndex == nil }
    var recordedCount: Int { steps.filter { $0.setID != nil }.count }
}
