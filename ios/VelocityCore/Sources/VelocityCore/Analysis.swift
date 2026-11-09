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
        MetricsCalculator.setSummary(loadKg: input.loadKg, systemMassKg: systemMassKg, reps: repMetrics,
                                     velocityLossThresholdPct: input.velocityLossThresholdPct,
                                     targetMeanVelocity: input.targetMeanVelocity)
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
        return SetAnalysis(input: input, settings: settings, track: track, kinematics: kin,
                           reps: found.map { EditableRep(detected: $0) }, warnings: notes)
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
