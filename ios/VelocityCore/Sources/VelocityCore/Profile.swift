import Foundation

/// Load-velocity profiles, estimated 1RM, readiness and retest timing (ported from prototype/vbt/profile.py).
///
/// Mean velocity falls roughly in a straight line as load rises. Fitting that line from a ramp of
/// sets and reading off the load at the 1RM velocity (minimum velocity threshold, MVT) estimates
/// the 1RM. Only sets the lifter tags as Profile test or Max single are used, never working sets.

/// One tagged set as the profile sees it.
public struct ProfileSet: Hashable, Sendable {
    public var date: Date
    public var loadKg: Double
    /// Mean velocity of the set's fastest rep: the best the lifter could move this load.
    public var bestMeanVelocity: Double
    /// Mean velocity of the slowest rep: for a max single, the lifter's 1RM velocity.
    public var slowestMeanVelocity: Double
    public var isMaxSingle: Bool

    public init(date: Date, loadKg: Double, bestMeanVelocity: Double, slowestMeanVelocity: Double, isMaxSingle: Bool) {
        self.date = date; self.loadKg = loadKg; self.bestMeanVelocity = bestMeanVelocity
        self.slowestMeanVelocity = slowestMeanVelocity; self.isMaxSingle = isMaxSingle
    }
}

/// Straight line of mean velocity against load.
public struct LoadVelocityLine: Hashable, Sendable {
    public var slope: Double       // m/s per kg (negative)
    public var intercept: Double   // m/s at 0 kg
    public var r2: Double
    public var loadCount: Int
    public var minLoadKg: Double
    public var maxLoadKg: Double

    public func velocity(atLoad kg: Double) -> Double { intercept + slope * kg }
    public func load(atVelocity v: Double) -> Double { (v - intercept) / slope }

    public enum FitError: Error, LocalizedError, Equatable {
        case needTwoLoads, velocityDoesNotFall
        public var errorDescription: String? {
            switch self {
            case .needTwoLoads: return "Needs sets at two or more different loads."
            case .velocityDoesNotFall: return "Velocity doesn't fall as the load rises, so no line can be drawn. Check the loads entered for these sets."
            }
        }
    }

    /// Least-squares fit, as numpy.polyfit(x, y, 1).
    public static func fit(loadsKg x: [Double], meanVelocities y: [Double]) throws -> LoadVelocityLine {
        precondition(x.count == y.count)
        let distinct = Set(x.map { ($0 * 100).rounded() })
        guard distinct.count >= 2 else { throw FitError.needTwoLoads }
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for i in x.indices { sxy += (x[i] - mx) * (y[i] - my); sxx += (x[i] - mx) * (x[i] - mx) }
        let slope = sxy / sxx
        guard slope < 0 else { throw FitError.velocityDoesNotFall }
        let intercept = my - slope * mx
        var ssRes = 0.0, ssTot = 0.0
        for i in x.indices {
            let e = y[i] - (intercept + slope * x[i]); ssRes += e * e
            ssTot += (y[i] - my) * (y[i] - my)
        }
        return LoadVelocityLine(slope: slope, intercept: intercept, r2: ssTot > 0 ? 1 - ssRes / ssTot : 1,
                                loadCount: distinct.count, minLoadKg: x.min()!, maxLoadKg: x.max()!)
    }
}

/// Where the 1RM velocity came from.
public enum MvtSource: Hashable, Sendable {
    case measured(Date)   // the lifter's own max single
    case edited           // the lifter changed the group default
    case groupDefault
}

/// Readiness from today's first set compared with what the profile predicts at that load.
/// Bands are the draft values from the programming spec.
public enum Readiness: String, CaseIterable, Sendable {
    case veryGood = "Very good", good = "Good", normal = "Normal", slightlyDown = "Slightly down",
         down = "Down", wellDown = "Well down"

    public init(deltaMetersPerSecond d: Double) {
        if d >= 0.06 { self = .veryGood }
        else if d >= 0.03 { self = .good }
        else if d > -0.03 { self = .normal }
        else if d > -0.06 { self = .slightlyDown }
        else if d > -0.10 { self = .down }
        else { self = .wellDown }
    }
}

public struct StrengthProfile: Sendable {
    /// Sets of the profile test the line is drawn from (the latest day with two or more loads).
    public var testSets: [ProfileSet]
    public var testDate: Date?
    public var line: LoadVelocityLine?
    /// Why there's no line, when there isn't one.
    public var lineProblem: String?
    public var mvt: Double?
    public var mvtSource: MvtSource?
    public var oneRmKg: Double?
    public var notes: [String]
    /// Date of the most recent tagged set of either kind.
    public var lastTestDate: Date?

    public static let retestIntervalDays = 28

    /// Build the profile from every tagged set of one exercise.
    /// - Parameters:
    ///   - defaultMvt: the group-average 1RM velocity, nil when the exercise has none.
    ///   - editedMvt: the lifter's own replacement for the default, if set.
    ///   - allowsOneRm: false for lifts with no dependable 1RM velocity (Olympic lifts).
    public static func build(sets: [ProfileSet], defaultMvt: Double?, editedMvt: Double? = nil,
                             allowsOneRm: Bool = true, calendar: Calendar = .current) -> StrengthProfile {
        let byDay = Dictionary(grouping: sets) { calendar.startOfDay(for: $0.date) }
        let days = byDay.keys.sorted(by: >)
        var p = StrengthProfile(testSets: [], testDate: nil, line: nil, lineProblem: nil, mvt: nil, mvtSource: nil,
                                oneRmKg: nil, notes: [], lastTestDate: sets.map(\.date).max())

        // The line comes from the latest day with sets at two or more loads.
        if let day = days.first(where: { d in Set(byDay[d]!.map { ($0.loadKg * 100).rounded() }).count >= 2 }) {
            let s = byDay[day]!.sorted { $0.loadKg < $1.loadKg }
            p.testSets = s
            p.testDate = day
            do {
                p.line = try LoadVelocityLine.fit(loadsKg: s.map(\.loadKg), meanVelocities: s.map(\.bestMeanVelocity))
            } catch {
                p.lineProblem = error.localizedDescription
            }
        } else if !sets.isEmpty {
            p.lineProblem = "A profile test needs sets at two or more loads on the same day."
        }

        // 1RM velocity: the slowest max single from the latest day that has one, else the
        // (possibly edited) group default.
        if let day = days.first(where: { d in byDay[d]!.contains(where: \.isMaxSingle) }) {
            p.mvt = byDay[day]!.filter(\.isMaxSingle).map(\.slowestMeanVelocity).min()
            p.mvtSource = .measured(day)
        } else if let e = editedMvt {
            p.mvt = e; p.mvtSource = .edited
        } else if let d = defaultMvt {
            p.mvt = d; p.mvtSource = .groupDefault
        }
        guard allowsOneRm else { p.mvt = nil; p.mvtSource = nil; return p }

        if let line = p.line, let mvt = p.mvt {
            let est = line.load(atVelocity: mvt)
            if est > line.minLoadKg {
                p.oneRmKg = est
                if line.loadCount < 4 {
                    p.notes.append("Only \(line.loadCount) loads. Four or more, spread from light to heavy, give a steadier line.")
                }
                if line.r2 < 0.9 {
                    p.notes.append(String(format: "The points fit a line loosely (R² %.2f), so the estimate is less reliable.", line.r2))
                }
                if line.maxLoadKg < 0.8 * est {
                    p.notes.append("The heaviest set is under about 80% of the estimate, so the line is extended a long way.")
                }
            } else {
                p.notes.append("The line reaches the 1RM velocity below the loads tested, so no 1RM is estimated. Check the loads and the 1RM velocity.")
            }
        }
        return p
    }

    /// Why a new profile test is suggested, or nil. The app only suggests; it never tests on its own.
    public func retestReason(today: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let last = lastTestDate else { return "No profile test yet for this exercise." }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: last),
                                           to: calendar.startOfDay(for: today)).day ?? 0
        return days >= Self.retestIntervalDays ? "Your last profile test was \(days) days ago." : nil
    }

    /// Readiness from a set's best mean velocity at a load, compared with the line.
    public func readiness(loadKg: Double, bestMeanVelocity: Double) -> (expected: Double, delta: Double, reading: Readiness)? {
        guard let line else { return nil }
        let expected = line.velocity(atLoad: loadKg)
        let d = bestMeanVelocity - expected
        return (expected, d, Readiness(deltaMetersPerSecond: d))
    }
}

/// Adjusts a profile-test ramp to how the lifter is actually moving.
public enum ProfileRamp {
    /// The 1RM to plan the remaining loads from, after the loads recorded so far.
    ///
    /// The guess is only trusted until the bar says otherwise. From two recorded loads a line is
    /// fitted and read at the 1RM velocity. A lower estimate is taken at once, so an overestimated
    /// guess never puts too much on the bar. A higher one is taken cautiously, because a line from
    /// light loads extends a long way: halfway from the guess with two loads, in full from three,
    /// and never more than 10% above the current plan in one step.
    /// - Parameters:
    ///   - currentKg: the 1RM the remaining loads are planned from now.
    ///   - done: (load, best mean velocity) for each load recorded in this test.
    ///   - mvt: the 1RM velocity, m/s.
    public static func revisedOneRm(currentKg: Double, done: [(loadKg: Double, mv: Double)], mvt: Double) -> Double {
        guard done.count >= 2,
              let line = try? LoadVelocityLine.fit(loadsKg: done.map(\.loadKg), meanVelocities: done.map(\.mv)) else {
            return currentKg
        }
        let fitted = line.load(atVelocity: mvt)
        guard fitted.isFinite, fitted > (done.map(\.loadKg).max() ?? 0) else { return currentKg }
        if fitted <= currentKg { return fitted }
        let toward = done.count == 2 ? (currentKg + fitted) / 2 : fitted
        return min(toward, currentKg * 1.10)
    }
}
