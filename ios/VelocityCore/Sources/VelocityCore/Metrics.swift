import Foundation

public let gravity = 9.81

/// How far a metric has been checked against a linear position transducer (GymAware).
public enum ValidationStatus: String, Codable, Sendable {
    case validated
    /// Shown with a "Beta" tag until it is validated.
    case beta
}

/// Which metrics the app shows as Beta. Mean velocity is validated on the trap bar deadlift
/// (bias -0.022 m/s, ICC 0.98 vs GymAware, 2026-11-09). Peak velocity reads 10-18% high and
/// peak power is not usable yet, so both stay Beta until new GymAware sets confirm them.
public enum MetricKind: String, CaseIterable, Codable, Sendable {
    case meanVelocity, meanPropulsiveVelocity, peakVelocity, meanPower, peakPower
    case concentricDistance, eccentricDistance, velocityLoss

    public var status: ValidationStatus {
        switch self {
        case .peakVelocity, .peakPower: return .beta
        default: return .validated
        }
    }
}

public struct RepMetrics: Codable, Hashable, Sendable {
    public var rep: Int
    public var meanVelocity: Double            // m/s, concentric
    public var meanPropulsiveVelocity: Double  // m/s, until the bar decelerates faster than gravity
    public var peakVelocity: Double            // m/s
    public var timeToPeakVelocity: Double      // s from concentric start
    public var meanPower: Double               // W, concentric, bar load only
    public var peakPower: Double               // W, bar load only
    public var concentricDistance: Double      // m
    public var concentricDuration: Double      // s
    public var eccentricDistance: Double?      // m
    public var eccentricDuration: Double?      // s
    public var eccentricMeanVelocity: Double?  // m/s, positive
    public var eccentricPeakVelocity: Double?  // m/s, positive
    public var horizontalDisplacement: Double  // m, largest left-right travel during the concentric
    /// Bar load plus the moving share of body mass. Nil when no body mass is given.
    public var systemMeanPower: Double?
    public var systemPeakPower: Double?
}

public struct SetMetrics: Codable, Hashable, Sendable {
    public var loadKg: Double
    public var systemMassKg: Double
    public var reps: [RepMetrics]
    public var repCount: Int
    public var meanVelocity: Double          // average of rep mean velocities
    public var bestMeanVelocity: Double
    public var firstRepMeanVelocity: Double
    public var lastRepMeanVelocity: Double
    public var velocityLossPct: Double       // (best - last) / best
    public var meanPeakVelocity: Double
    public var peakVelocity: Double          // highest rep peak velocity
    public var meanPower: Double
    public var bestMeanPower: Double
    public var meanPeakPower: Double
    public var peakPower: Double
    public var totalConcentricDistance: Double
    public var totalEccentricDistance: Double
    public var meanConcentricDistance: Double
    public var meanEccentricDistance: Double?
    public var volumeLoadKg: Double          // reps x load
    public var systemMeanPower: Double?
    public var systemPeakPower: Double?
    public var velocityLossThresholdPct: Double?
    public var thresholdReachedAtRep: Int?   // first rep whose loss passed the threshold
    public var outsideTargetReps: [Int]
}

public enum MetricsCalculator {
    /// One rep's metrics. Bar power uses loadKg alone; system power adds bodyMassFraction of body mass.
    public static func repMetrics(_ kin: Kinematics, rep: Rep, number: Int? = nil, loadKg: Double,
                                  bodyMassKg: Double?, bodyMassFraction: Double) -> RepMetrics {
        let c = rep.concentric.start...rep.concentric.end
        let v = Array(kin.v[c]), a = Array(kin.a[c])
        let dt = 1.0 / kin.fps
        let power = zip(a, v).map { loadKg * ($0 + gravity) * $1 }
        var systemPower: [Double]? = nil
        if let bm = bodyMassKg, bm != 0 {
            let m = loadKg + bm * bodyMassFraction
            systemPower = zip(a, v).map { m * ($0 + gravity) * $1 }
        }
        let iPeak = v.indices.max(by: { v[$0] < v[$1] || (v[$0] == v[$1] && $0 > $1) }) ?? 0

        // Propulsive phase ends the first time after peak velocity that the bar decelerates faster than g.
        let propEnd = (iPeak..<a.count).first(where: { a[$0] < -gravity }) ?? v.count
        let mpv = Stats.mean(v[0..<max(propEnd, 1)])

        var eccDist: Double? = nil, eccDur: Double? = nil, eccMean: Double? = nil, eccPeak: Double? = nil
        if let ecc = rep.eccentric {
            let ev = kin.v[ecc.start...ecc.end].map { -$0 }
            eccDist = kin.y[ecc.start] - kin.y[ecc.end]
            eccDur = Double(ecc.end - ecc.start) * dt
            eccMean = Stats.mean(ev)
            eccPeak = ev.max()
        }
        let xs = kin.x[c]
        return RepMetrics(
            rep: number ?? rep.number,
            meanVelocity: Stats.mean(v),
            meanPropulsiveVelocity: mpv,
            peakVelocity: v[iPeak],
            timeToPeakVelocity: Double(iPeak) * dt,
            meanPower: Stats.mean(power),
            peakPower: power.max() ?? .nan,
            concentricDistance: kin.y[rep.concentric.end] - kin.y[rep.concentric.start],
            concentricDuration: Double(rep.concentric.end - rep.concentric.start) * dt,
            eccentricDistance: eccDist, eccentricDuration: eccDur,
            eccentricMeanVelocity: eccMean, eccentricPeakVelocity: eccPeak,
            horizontalDisplacement: (xs.max() ?? 0) - (xs.min() ?? 0),
            systemMeanPower: systemPower.map { Stats.mean($0) },
            systemPeakPower: systemPower.flatMap { $0.max() }
        )
    }

    public static func setSummary(loadKg: Double, systemMassKg: Double, reps: [RepMetrics],
                                  velocityLossThresholdPct: Double? = nil,
                                  targetMeanVelocity: ClosedRange<Double>? = nil) -> SetMetrics? {
        guard !reps.isEmpty else { return nil }
        let mv = reps.map(\.meanVelocity), pv = reps.map(\.peakVelocity)
        let mp = reps.map(\.meanPower), pp = reps.map(\.peakPower)
        let cd = reps.map(\.concentricDistance)
        let ed = reps.compactMap(\.eccentricDistance)
        let best = mv.max()!

        var reached: Int? = nil
        if let thr = velocityLossThresholdPct {
            var runningBest = -Double.infinity
            for (i, m) in mv.enumerated() {
                runningBest = max(runningBest, m)
                if (runningBest - m) / runningBest * 100 >= thr { reached = reps[i].rep; break }
            }
        }
        let outside = targetMeanVelocity.map { zone in reps.filter { !zone.contains($0.meanVelocity) }.map(\.rep) } ?? []
        let hasSystem = reps[0].systemMeanPower != nil
        return SetMetrics(
            loadKg: loadKg, systemMassKg: systemMassKg, reps: reps, repCount: reps.count,
            meanVelocity: Stats.mean(mv), bestMeanVelocity: best,
            firstRepMeanVelocity: mv[0], lastRepMeanVelocity: mv[mv.count - 1],
            velocityLossPct: (best - mv[mv.count - 1]) / best * 100,
            meanPeakVelocity: Stats.mean(pv), peakVelocity: pv.max()!,
            meanPower: Stats.mean(mp), bestMeanPower: mp.max()!,
            meanPeakPower: Stats.mean(pp), peakPower: pp.max()!,
            totalConcentricDistance: cd.reduce(0, +),
            totalEccentricDistance: ed.reduce(0, +),
            meanConcentricDistance: Stats.mean(cd),
            meanEccentricDistance: ed.isEmpty ? nil : Stats.mean(ed),
            volumeLoadKg: loadKg * Double(reps.count),
            systemMeanPower: hasSystem ? Stats.mean(reps.compactMap(\.systemMeanPower)) : nil,
            systemPeakPower: hasSystem ? reps.compactMap(\.systemPeakPower).max() : nil,
            velocityLossThresholdPct: velocityLossThresholdPct,
            thresholdReachedAtRep: reached,
            outsideTargetReps: outside
        )
    }
}
