import Foundation
import Observation
import VelocityCore

enum AppTab: Hashable { case today, history, program, settings }

/// Whether a set counts toward the strength profile.
enum SetType: String, CaseIterable, Identifiable, Codable {
    case working = "Working"
    case profileTest = "Profile test"
    case maxSingle = "Max single"
    var id: String { rawValue }
}

/// One analyzed set.
struct AnalyzedSet: Identifiable {
    var id: UUID
    var date: Date
    var clipName: String
    var setType: SetType
    var analysis: SetAnalysis

    init(id: UUID = UUID(), date: Date, clipName: String, setType: SetType, analysis: SetAnalysis) {
        self.id = id; self.date = date; self.clipName = clipName; self.setType = setType; self.analysis = analysis
    }

    var exerciseID: String { analysis.input.exercise.id }
    var record: SetRecord { SetRecord(id: id, date: date, setType: setType.rawValue, clipName: clipName, analysis: analysis) }

    init?(record: SetRecord) {
        guard let a = try? record.analysis() else { return nil }
        self.init(id: record.id, date: record.date, clipName: record.clipName,
                  setType: SetType(rawValue: record.setType) ?? .working, analysis: a)
    }
}

/// What each exercise remembers: its last load, target zone and fatigue cutoff.
struct ExercisePrefs: Codable, Equatable {
    var loadKg: Double = 60
    var targetLow: Double?        // m/s
    var targetHigh: Double?       // m/s
    var lossCutoffPct: Double?    // nil: use the default in Settings
    var editedMvt: Double?        // lifter's replacement for the group-default 1RM velocity, m/s
    var knownOneRmKg: Double?     // a 1RM the lifter entered by hand (tested outside the app)
    var knownOneRmDate: Date?

    var targetZone: ClosedRange<Double>? {
        guard let lo = targetLow, let hi = targetHigh, lo < hi else { return nil }
        return lo...hi
    }
}

@Observable
final class AppModel {
    /// Every saved set, newest first.
    var sets: [AnalyzedSet] = []
    var prefs: [String: ExercisePrefs] = [:] { didSet { savePrefs() } }
    var currentExerciseID: String {
        didSet { UserDefaults.standard.set(currentExerciseID, forKey: SettingsKey.lastExercise) }
    }
    var loaded = false
    /// Type for the next set recorded or analyzed. Stays until changed, so a whole ramp can be tagged.
    var nextSetType: SetType = .working
    /// Rep cap for the next recorded set (from the program or a profile-test step), cued live.
    var nextSetRepCap: Int?
    var selectedTab: AppTab = .today
    /// The training block being followed, if any.
    var program: Program? = ProgramStore.load() { didSet { ProgramStore.save(program) } }

    private let store: SetStore

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = SetStore(folder: support.appendingPathComponent("Sets", isDirectory: true))
        currentExerciseID = UserDefaults.standard.string(forKey: SettingsKey.lastExercise) ?? "trap_bar_deadlift"
        if let data = UserDefaults.standard.data(forKey: SettingsKey.exercisePrefs),
           let p = try? JSONDecoder().decode([String: ExercisePrefs].self, from: data) {
            prefs = p
        }
        let store = self.store
        Task.detached(priority: .userInitiated) {
            let loaded = store.loadAll().compactMap(AnalyzedSet.init(record:))
            await MainActor.run {
                self.sets = loaded
                self.loaded = true
            }
        }
    }

    // MARK: Sets

    func add(_ set: AnalyzedSet) {
        sets.insert(set, at: 0)
        persist(set)
        var p = prefs(for: set.exerciseID)
        p.loadKg = set.analysis.input.loadKg
        prefs[set.exerciseID] = p
    }

    func update(_ set: AnalyzedSet) {
        if let i = sets.firstIndex(where: { $0.id == set.id }) { sets[i] = set }
        persist(set)
    }

    func delete(_ id: UUID) {
        sets.removeAll { $0.id == id }
        store.delete(id)
    }

    func set(_ id: UUID) -> AnalyzedSet? { sets.first { $0.id == id } }

    func changeType(of id: UUID, to type: SetType) {
        guard var s = set(id), s.setType != type else { return }
        s.setType = type
        update(s)
    }

    private func persist(_ set: AnalyzedSet) {
        let record = set.record
        let store = self.store
        Task.detached(priority: .utility) { try? store.save(record) }
    }

    // MARK: Sessions (one per day)

    func sets(on day: Date) -> [AnalyzedSet] {
        sets.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
    }

    /// Days that have sets, newest first.
    var sessionDays: [Date] {
        var seen = Set<Date>()
        var out: [Date] = []
        for s in sets {
            let d = Calendar.current.startOfDay(for: s.date)
            if seen.insert(d).inserted { out.append(d) }
        }
        return out
    }

    /// Exercises with saved sets, most recently used first.
    var usedExerciseIDs: [String] {
        var seen = Set<String>()
        return sets.map(\.exerciseID).filter { seen.insert($0).inserted }
    }

    /// Chips on the Today screen: the current exercise, then recently used ones.
    var quickExerciseIDs: [String] {
        var ids = usedExerciseIDs
        if !ids.contains(currentExerciseID) { ids.insert(currentExerciseID, at: 0) }
        return Array(ids.prefix(8))
    }

    // MARK: Strength profile

    /// The exercise's profile from its Profile test and Max single sets only.
    func profile(for id: String) -> StrengthProfile {
        let ex = ExerciseCatalog.exercise(id: id)
        let tagged: [ProfileSet] = sets.compactMap { s in
            guard s.exerciseID == id, s.setType != .working, let m = s.analysis.setMetrics, m.repCount > 0 else { return nil }
            return ProfileSet(date: s.date, loadKg: m.loadKg, bestMeanVelocity: m.bestMeanVelocity,
                              slowestMeanVelocity: m.reps.map(\.meanVelocity).min() ?? m.bestMeanVelocity,
                              isMaxSingle: s.setType == .maxSingle)
        }
        return StrengthProfile.build(sets: tagged, defaultMvt: ex?.defaultMvt, editedMvt: prefs(for: id).editedMvt,
                                     allowsOneRm: ex?.allowsOneRm ?? true)
    }

    /// Readiness from today's first set of the exercise, compared with its profile.
    func readinessToday(for id: String) -> (set: AnalyzedSet, expected: Double, delta: Double, reading: Readiness)? {
        guard let first = sets(on: Date()).last(where: { $0.exerciseID == id }),
              let m = first.analysis.setMetrics, m.repCount > 0 else { return nil }
        let p = profile(for: id)
        // A profile test done today is the reference itself, so it can't also be the check.
        if let d = p.testDate, Calendar.current.isDateInToday(d) { return nil }
        guard let r = p.readiness(loadKg: m.loadKg, bestMeanVelocity: m.bestMeanVelocity) else { return nil }
        return (first, r.expected, r.delta, r.reading)
    }

    // MARK: Per-exercise settings

    func prefs(for id: String) -> ExercisePrefs {
        if let p = prefs[id] { return p }
        // A new exercise starts from the last load used on any exercise.
        return ExercisePrefs(loadKg: sets.first?.analysis.input.loadKg ?? 60)
    }

    func lossCutoff(for id: String) -> Double? {
        let global = UserDefaults.standard.object(forKey: SettingsKey.velocityLossCutoff) as? Double ?? 20
        let v = prefs(for: id).lossCutoffPct ?? global
        return v > 0 ? v : nil
    }

    func setInput(exerciseID id: String, loadKg: Double) -> SetInput {
        let ex = ExerciseCatalog.exercise(id: id) ?? ExerciseCatalog.all[0]
        let bm = UserDefaults.standard.double(forKey: SettingsKey.bodyMassKg)
        return SetInput(exercise: ex, loadKg: loadKg, bodyMassKg: bm > 0 ? bm : nil,
                        velocityLossThresholdPct: lossCutoff(for: id), targetMeanVelocity: prefs(for: id).targetZone)
    }

    private func savePrefs() {
        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: SettingsKey.exercisePrefs)
        }
    }
}

/// Keys and defaults for settings stored with @AppStorage.
enum SettingsKey {
    static let unit = "unit"                       // WeightUnit raw value
    static let bodyMassKg = "bodyMassKg"           // 0 = not set
    static let cutoffHz = "cutoffHz"
    static let plateDiameterCm = "plateDiameterCm"
    static let tiltCorrection = "tiltCorrection"
    static let velocityLossCutoff = "velocityLossCutoff"  // percent, default for exercises without their own
    static let lastExercise = "lastExercise"
    static let keepSetVideos = "keepSetVideos"     // save recorded sets to Photos
    static let liveCues = "liveCues"               // tones during the set (default on)
    static let speakReps = "speakReps"             // say each rep's velocity (default off)
    static let exercisePrefs = "exercisePrefs"     // JSON [exercise id: ExercisePrefs]

    static func analysisSettings(_ d: UserDefaults = .standard) -> AnalysisSettings {
        let cutoff = d.object(forKey: cutoffHz) as? Double ?? 8.0
        let plateCm = d.object(forKey: plateDiameterCm) as? Double ?? 45.0
        let tilt = d.object(forKey: tiltCorrection) as? Bool ?? true
        return AnalysisSettings(plateDiameterM: plateCm / 100, cutoffHz: cutoff, tiltCorrection: tilt)
    }
}
