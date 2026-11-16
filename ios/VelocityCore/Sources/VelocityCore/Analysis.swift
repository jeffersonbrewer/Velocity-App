import Foundation

/// User-adjustable analysis settings.
public struct AnalysisSettings: Codable, Hashable, Sendable {
    /// Diameter of the plate facing the camera. Standard bumper and competition plates are 0.45 m.
    public var plateDiameterM: Double = standardPlateDiameterM
    /// Low-pass filter cutoff. 8 Hz matches the validated prototype; kept adjustable while the
    /// peak-velocity gap against GymAware is investigated.
    public var cutoffHz: Double = 8.0
    /// Correct for the plate looking smaller higher in the frame when the camera is tilted.
    public var tiltCorrection: Bool = true

    public init(plateDiameterM: Double = standardPlateDiameterM, cutoffHz: Double = 8.0, tiltCorrection: Bool = true) {
        self.plateDiameterM = plateDiameterM; self.cutoffHz = cutoffHz; self.tiltCorrection = tiltCorrection
    }
}

/// What the lifter tells the app about a set.
public struct SetInput: Codable, Hashable, Sendable {
    public var exercise: Exercise
    public var loadKg: Double
    public var bodyMassKg: Double?
    public var velocityLossThresholdPct: Double?
    public var targetMeanVelocity: ClosedRange<Double>?

    public init(exercise: Exercise, loadKg: Double, bodyMassKg: Double? = nil,
                velocityLossThresholdPct: Double? = nil, targetMeanVelocity: ClosedRange<Double>? = nil) {
        self.exercise = exercise; self.loadKg = loadKg; self.bodyMassKg = bodyMassKg
        self.velocityLossThresholdPct = velocityLossThresholdPct; self.targetMeanVelocity = targetMeanVelocity
    }
}

/// A rep as found by the app plus the lifter's edits.
public struct EditableRep: Codable, Hashable, Sendable, Identifiable {
    public var id: Int { detected.number }
    public var detected: Rep
    /// The lifter's adjusted concentric start and end; nil means as detected.
    public var adjustedConcentric: Phase?
    public var deleted: Bool = false
    /// Why screening questioned this rep (nil: looks normal). Partial reps are also left out.
    public var flag: String?

    public var effective: Rep {
        Rep(number: detected.number, concentric: adjustedConcentric ?? detected.concentric, eccentric: detected.eccentric)
    }
}

/// The full result of analyzing one recorded set.
public struct SetAnalysis: Sendable {
    public var input: SetInput
    public var settings: AnalysisSettings
    public var track: Track
    public var kinematics: Kinematics
    public var reps: [EditableRep]
    public var warnings: [String]

    public var systemMassKg: Double {
        input.loadKg + (input.bodyMassKg ?? 0) * input.exercise.bodyMassFraction
    }

    /// Metrics for the reps that are not deleted, numbered 1, 2, 3... in order.
    public var repMetrics: [RepMetrics] {
        let bodyMass = input.exercise.bodyMassFraction > 0 ? input.bodyMassKg : nil
        return reps.filter { !$0.deleted }.enumerated().map { i, r in
            MetricsCalculator.repMetrics(kinematics, rep: r.effective, number: i + 1, loadKg: input.loadKg,
                                         bodyMassKg: bodyMass, bodyMassFraction: input.exercise.bodyMassFraction)
        }
    }

    public var setMetrics: SetMetrics? {
        let kept = reps.filter { !$0.deleted }
        let bounces = Set(kept.enumerated().filter { $0.element.flag?.hasPrefix("Unusually fast") == true }.map { $0.offset + 1 })
        return MetricsCalculator.setSummary(loadKg: input.loadKg, systemMassKg: systemMassKg, reps: repMetrics,
                                            velocityLossThresholdPct: input.velocityLossThresholdPct,
                                            targetMeanVelocity: input.targetMeanVelocity, notReference: bounces)
    }
}

public enum SetAnalyzer {
    /// Turn a plate track into reps and metrics. Mirrors analyze.analyze_video in the prototype.
    public static func analyze(track: Track, input: SetInput, settings: AnalysisSettings = .init()) throws -> SetAnalysis {
        let kin = try KinematicsBuilder.fromTrack(track, plateDiameterM: settings.plateDiameterM,
                                                  cutoffHz: settings.cutoffHz, positionScale: settings.tiltCorrection)
        var found = RepSegmenter.segment(kin, concentricFirst: input.exercise.concentricFirst)
        var notes = warnings(for: track)
        if !kin.bridgedGaps.isEmpty {
            let before = found.count
            found = found.filter { rep in
                !kin.bridgedGaps.contains { $0.start <= rep.concentric.end && $0.end >= rep.concentric.start }
            }
            if found.count < before {
                notes.append("The plate was hidden during \(before - found.count) lift(s), so they were left out.")
            }
            found = found.enumerated().map { i, r in Rep(number: i + 1, concentric: r.concentric, eccentric: r.eccentric) }
        }
        var reps = found.map { EditableRep(detected: $0) }
        let screened = RepScreen.screen(&reps, kinematics: kin)
        if screened.excluded > 0 {
            notes.append("\(screened.excluded) movement(s) were much shorter than the other reps (a step back, settling or a partial), so they were left out. Restore them on the results if they were real reps.")
        }
        if screened.flagged > 0 {
            notes.append("\(screened.flagged) rep(s) look unusually fast or slow for this set (a bounce or a stall?). They're kept but marked: review them on the results.")
        }
        return SetAnalysis(input: input, settings: settings, track: track, kinematics: kin, reps: reps, warnings: notes)
    }

    public static func warnings(for track: Track) -> [String] {
        var out: [String] = []
        if track.fps < 100 {
            out.append("Frame rate is \(Int(track.fps.rounded())) fps. Film in 240 fps slow motion for accurate results.")
        }
        if track.roundness < 0.94 {
            out.append(String(format: "The plate looks oval (roundness %.2f). The camera may not be square to the bar, which distorts distances and velocities.", track.roundness))
        }
        if track.lostFraction > 0.05 {
            out.append("The plate was not found in \(Int((track.lostFraction * 100).rounded()))% of frames.")
        }
        return out
    }
}

/// Screens detected reps for things that aren't real reps or give misleading velocities.
///
/// - Partial range: a concentric phase under 70% of the set's typical distance (the median of
///   the reps), such as a step back after unracking, settling the bar, or an incomplete rep. These
///   are left out, and can be restored.
/// - Velocity outliers, among the remaining reps: a rep more than 25% faster than the median
///   (often a bounce), or one under 60% of the median that's followed by faster reps (a stall or
///   hitch, not fatigue). These are only marked, because they can be real.
public enum RepScreen {
    @discardableResult
    public static func screen(_ reps: inout [EditableRep], kinematics kin: Kinematics,
                              partialFraction: Double = 0.70) -> (excluded: Int, flagged: Int) {
        guard reps.count >= 2 else { return (0, 0) }
        func distance(_ r: EditableRep) -> Double {
            let c = r.effective.concentric
            return abs(kin.y[c.end] - kin.y[c.start])
        }
        func mv(_ r: EditableRep) -> Double {
            let c = r.effective.concentric
            let v = kin.v[c.start...c.end]
            return v.reduce(0, +) / Double(v.count)
        }
        let dists = reps.map(distance)
        let typical = Stats.median(dists)
        var excluded = 0
        for i in reps.indices where !reps[i].deleted && dists[i] < partialFraction * typical {
            reps[i].deleted = true
            reps[i].flag = String(format: "Partial range: %.0f cm vs %.0f cm typical", dists[i] * 100, typical * 100)
            excluded += 1
        }
        let kept = reps.indices.filter { !reps[$0].deleted }
        guard kept.count >= 3 else { return (excluded, 0) }
        let mvs = Dictionary(uniqueKeysWithValues: kept.map { ($0, mv(reps[$0])) })
        let med = Stats.median(kept.map { mvs[$0]! })
        var flagged = 0
        for (n, i) in kept.enumerated() {
            let v = mvs[i]!
            if v > 1.25 * med {
                reps[i].flag = String(format: "Unusually fast: %.2f vs %.2f m/s typical (bounce?)", v, med); flagged += 1
            } else if v < 0.60 * med, kept[(n + 1)...].contains(where: { mvs[$0]! > 0.8 * med }) {
                reps[i].flag = String(format: "Unusually slow: %.2f vs %.2f m/s typical (stall?)", v, med); flagged += 1
            }
        }
        return (excluded, flagged)
    }
}
