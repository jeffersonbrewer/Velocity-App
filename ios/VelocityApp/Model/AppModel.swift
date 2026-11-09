import Foundation
import Observation
import VelocityCore

/// Whether a set counts toward the strength profile.
enum SetType: String, CaseIterable, Identifiable, Codable {
    case working = "Working"
    case profileTest = "Profile test"
    case maxSingle = "Max single"
    var id: String { rawValue }
}

/// One analyzed set kept for this session. Saving sets between launches comes in milestone 3.
struct AnalyzedSet: Identifiable {
    let id = UUID()
    let date: Date
    let clipName: String
    let setType: SetType
    var analysis: SetAnalysis
}

@Observable
final class AppModel {
    var recentSets: [AnalyzedSet] = []

    func add(_ set: AnalyzedSet) { recentSets.insert(set, at: 0) }

    func update(_ set: AnalyzedSet) {
        if let i = recentSets.firstIndex(where: { $0.id == set.id }) { recentSets[i] = set }
    }
}

/// Keys and defaults for settings stored with @AppStorage.
enum SettingsKey {
    static let unit = "unit"                       // WeightUnit raw value
    static let bodyMassKg = "bodyMassKg"           // 0 = not set
    static let cutoffHz = "cutoffHz"
    static let plateDiameterCm = "plateDiameterCm"
    static let tiltCorrection = "tiltCorrection"
    static let velocityLossCutoff = "velocityLossCutoff"  // percent
    static let lastExercise = "lastExercise"
    static let lastLoadKg = "lastLoadKg"

    static func analysisSettings(_ d: UserDefaults = .standard) -> AnalysisSettings {
        let cutoff = d.object(forKey: cutoffHz) as? Double ?? 8.0
        let plateCm = d.object(forKey: plateDiameterCm) as? Double ?? 45.0
        let tilt = d.object(forKey: tiltCorrection) as? Bool ?? true
        return AnalysisSettings(plateDiameterM: plateCm / 100, cutoffHz: cutoff, tiltCorrection: tilt)
    }
}
