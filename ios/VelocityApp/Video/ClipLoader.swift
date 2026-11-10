import AVFoundation
import Photos
import UniformTypeIdentifiers

enum ClipLoaderError: LocalizedError {
    case noPhotoAccess
    case notFound
    case notAVideo
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .noPhotoAccess:
            return "Velocity needs access to your photo library to read the full-speed original of a slow-motion video. Turn it on in Settings › Velocity › Photos."
        case .notFound:
            return "Couldn't open that video. If you allowed access to only some photos, add this video in Settings › Velocity › Photos."
        case .notAVideo:
            return "That item isn't a video."
        case .copyFailed:
            return "Couldn't copy the video from Files."
        }
    }
}

/// A video ready to analyze.
struct Clip: Identifiable {
    let id = UUID()
    let asset: AVAsset
    let name: String
    /// When the video was filmed, if known; the set is filed under that day.
    var date: Date? = nil
}

enum ClipLoader {
    /// Load the unmodified original of a Photos video. For slow-motion clips this is the real
    /// 240 fps recording with its own frame times, not the slowed-down 30 fps version Photos plays.
    static func loadOriginal(localIdentifier: String) async throws -> Clip {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw ClipLoaderError.noPhotoAccess }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let phAsset = result.firstObject else { throw ClipLoaderError.notFound }
        guard phAsset.mediaType == .video else { throw ClipLoaderError.notAVideo }

        let options = PHVideoRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true  // originals kept in iCloud are downloaded

        let asset: AVAsset = try await withCheckedThrowingContinuation { cont in
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { avAsset, _, info in
                if let avAsset {
                    cont.resume(returning: avAsset)
                } else {
                    cont.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? ClipLoaderError.notFound)
                }
            }
        }
        let name = PHAssetResource.assetResources(for: phAsset).first?.originalFilename ?? "Video"
        return Clip(asset: asset, name: name, date: phAsset.creationDate)
    }

    /// Copy a video picked in Files (for example an original AirDropped from another phone)
    /// into the app's temporary folder and open it.
    static func loadFile(_ url: URL) throws -> Clip {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            throw ClipLoaderError.copyFailed
        }
        return Clip(asset: AVURLAsset(url: dest), name: url.lastPathComponent)
    }
}
