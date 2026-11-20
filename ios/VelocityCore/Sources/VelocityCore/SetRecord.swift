import Foundation

/// Everything needed to rebuild a set's analysis later, including the lifter's rep edits.
/// The plate track is stored rather than the video, so results can be recomputed (for example
/// with a different filter) without keeping large video files.
public struct SetRecord: Codable, Sendable {
    public var id: UUID
    public var date: Date
    public var setType: String
    public var clipName: String
    public var input: SetInput
    public var settings: AnalysisSettings
    public var track: Track
    public var reps: [EditableRep]
    public var warnings: [String]
    public var version = 1

    public init(id: UUID, date: Date, setType: String, clipName: String, analysis: SetAnalysis) {
        self.id = id; self.date = date; self.setType = setType; self.clipName = clipName
        input = analysis.input; settings = analysis.settings; track = analysis.track
        reps = analysis.reps; warnings = analysis.warnings
    }

    /// Recompute the kinematics from the stored track and reapply the saved reps and edits.
    public func analysis() throws -> SetAnalysis {
        let kin = try KinematicsBuilder.fromTrack(track, plateDiameterM: settings.plateDiameterM,
                                                  cutoffHz: settings.cutoffHz, positionScale: settings.tiltCorrection)
        // Keep only reps that still fit the recomputed signal.
        let valid = reps.filter { r in
            let c = r.adjustedConcentric ?? r.detected.concentric
            return c.start >= 0 && c.end < kin.v.count && c.start < c.end
        }
        return SetAnalysis(input: input, settings: settings, track: track, kinematics: kin, reps: valid, warnings: warnings)
    }

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

    public func encoded() throws -> Data { try SetRecord.encoder.encode(self) }
    public static func decode(_ data: Data) throws -> SetRecord { try decoder.decode(SetRecord.self, from: data) }
}

/// Stores one file per set in a folder.
public final class SetStore: @unchecked Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func url(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }

    public func save(_ record: SetRecord) throws {
        try record.encoded().write(to: url(record.id), options: .atomic)
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
    }

    /// All stored sets, newest first. Files that can't be read are skipped.
    public func loadAll() -> [SetRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? SetRecord.decode(Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }
}
