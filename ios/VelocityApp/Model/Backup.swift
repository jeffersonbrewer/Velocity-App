import Foundation
import VelocityCore

/// Everything the app keeps, in one file: sets (with their plate tracks and rep edits), the program,
/// debriefs, hand-logged sets, each exercise's settings and the app settings. Videos aren't included.
struct BackupFile: Codable {
    var version = 1
    var created: Date
    var appVersion: String
    var sets: [SetRecord]
    var program: Program?
    var debriefs: [SessionDebrief]
    var manualSets: [ManualSet]
    var prefs: [String: ExercisePrefs]
    var settings: BackupSettings
}

/// The app settings worth keeping across a reinstall.
struct BackupSettings: Codable {
    var strings: [String: String] = [:]
    var doubles: [String: Double] = [:]
    var bools: [String: Bool] = [:]

    static let stringKeys = [SettingsKey.unit, SettingsKey.lastExercise]
    static let doubleKeys = [SettingsKey.bodyMassKg, SettingsKey.cutoffHz, SettingsKey.plateDiameterCm,
                             SettingsKey.velocityLossCutoff, SettingsKey.autoStopSeconds]
    static let boolKeys = [SettingsKey.tiltCorrection, SettingsKey.keepSetVideos, SettingsKey.liveCues,
                           SettingsKey.speakReps, SettingsKey.dimWhileRecording, SettingsKey.autoStop]

    static func current(_ d: UserDefaults = .standard) -> BackupSettings {
        var s = BackupSettings()
        for k in stringKeys { if let v = d.string(forKey: k) { s.strings[k] = v } }
        for k in doubleKeys { if let v = d.object(forKey: k) as? Double { s.doubles[k] = v } }
        for k in boolKeys { if let v = d.object(forKey: k) as? Bool { s.bools[k] = v } }
        return s
    }

    func apply(_ d: UserDefaults = .standard) {
        for (k, v) in strings { d.set(v, forKey: k) }
        for (k, v) in doubles { d.set(v, forKey: k) }
        for (k, v) in bools { d.set(v, forKey: k) }
    }
}

/// Writes and reads backup files: automatic copies in the app's Documents folder (visible in Files
/// and in Finder), and in a folder the lifter picks, such as iCloud Drive, which survives deleting the app.
enum BackupStore {
    static let keepLocal = 7
    static let keepInFolder = 5
    private static let folderBookmarkKey = "backupFolderBookmark"
    static let lastBackupKey = "lastBackupDate"
    static let lastFolderErrorKey = "backupFolderError"

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static var localFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Backups", isDirectory: true)
    }

    static func fileName(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return "velocity-backup-\(f.string(from: date)).json"
    }

    // MARK: The chosen folder

    static func setFolder(_ url: URL?) {
        guard let url else {
            UserDefaults.standard.removeObject(forKey: folderBookmarkKey)
            return
        }
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData() { UserDefaults.standard.set(data, forKey: folderBookmarkKey) }
    }

    static func folder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: folderBookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: folderBookmarkKey) }
        return url
    }

    static var folderName: String? { folder()?.lastPathComponent }

    // MARK: Writing

    /// Write one backup to Documents and, if set, the chosen folder. Returns the local file.
    @discardableResult
    static func write(_ data: Data, date: Date) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: localFolder, withIntermediateDirectories: true)
        let local = localFolder.appendingPathComponent(fileName(date))
        try data.write(to: local, options: .atomic)
        prune(localFolder, keep: keepLocal)

        if let folder = folder() {
            let ok = folder.startAccessingSecurityScopedResource()
            defer { if ok { folder.stopAccessingSecurityScopedResource() } }
            var coordError: NSError?
            var writeError: Error?
            let target = folder.appendingPathComponent(fileName(date))
            NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordError) { url in
                do { try data.write(to: url, options: .atomic) } catch { writeError = error }
            }
            if let e = coordError ?? writeError {
                UserDefaults.standard.set(e.localizedDescription, forKey: lastFolderErrorKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastFolderErrorKey)
                prune(folder, keep: keepInFolder)
            }
        }
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: lastBackupKey)
        return local
    }

    /// Keep the newest `keep` backup files in a folder.
    private static func prune(_ folder: URL, keep: Int) {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("velocity-backup-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for f in files.dropFirst(keep) { try? fm.removeItem(at: f) }
    }

    // MARK: Reading

    static func read(_ url: URL) throws -> BackupFile {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        var coordError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            result = Result { try Data(contentsOf: u) }
        }
        if let coordError { throw coordError }
        return try decoder.decode(BackupFile.self, from: result.get())
    }
}

extension AppModel {
    /// A snapshot of everything, taken on the main thread so it matches what's on screen.
    @MainActor
    func backupSnapshot() -> BackupFile {
        BackupFile(created: Date(),
                   appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                   sets: sets.map(\.record), program: program, debriefs: debriefs, manualSets: manualSets,
                   prefs: prefs, settings: .current())
    }

    /// Back up now. Encoding and writing happen off the main thread.
    @MainActor
    @discardableResult
    func backUp() async throws -> URL {
        let snap = backupSnapshot()
        return try await Task.detached(priority: .utility) {
            let data = try BackupStore.encoder.encode(snap)
            return try BackupStore.write(data, date: snap.created)
        }.value
    }

    /// Back up when there's data and the last backup is older than `minInterval`.
    @MainActor
    func autoBackup(minInterval: TimeInterval = 15 * 60) {
        guard loaded, !(sets.isEmpty && program == nil && debriefs.isEmpty) else { return }
        let last = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: BackupStore.lastBackupKey))
        guard Date().timeIntervalSince(last) >= minInterval else { return }
        Task { try? await backUp() }
    }

    /// Replace everything on this phone with a backup. The current data is backed up first.
    @MainActor
    func restore(_ b: BackupFile) async throws {
        if !(sets.isEmpty && program == nil && debriefs.isEmpty) { try await backUp() }
        let records = b.sets
        let store = self.store
        let restored: [AnalyzedSet] = try await Task.detached(priority: .userInitiated) {
            for old in store.loadAll() { store.delete(old.id) }
            for r in records { try store.save(r) }
            return records.compactMap(AnalyzedSet.init(record:)).sorted { $0.date > $1.date }
        }.value
        b.settings.apply()
        sets = restored
        prefs = b.prefs
        program = b.program
        debriefs = b.debriefs
        manualSets = b.manualSets
        if let id = b.settings.strings[SettingsKey.lastExercise] { currentExerciseID = id }
    }
}
