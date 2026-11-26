import AVFoundation
import CoreMedia
import CoreVideo
import VelocityCore

enum VideoTrackerError: LocalizedError {
    case noVideoTrack
    case cannotRead(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "This file has no video."
        case .cannotRead(let why): return "Couldn't read the video: \(why)"
        }
    }
}

/// Reads every frame of a video in order and follows the plate through it.
enum VideoTracker {
    struct Progress: Sendable {
        var fraction: Double
        var plateFound: Bool
    }

    /// Track the plate frame by frame, at most `maxRate` frames a second (nil: every frame). Uses
    /// each frame's own timestamp, because iPhone slow-motion originals have a variable frame rate
    /// (240 fps capture with dropped frames). 120 fps halves the work; mean velocity matched 240 fps
    /// in the Nov 9 trap bar check.
    static func track(_ asset: AVAsset, hint: CGPoint? = nil, maxRate: Double? = SettingsKey.analysisMaxRate(),
                      progress: @escaping @Sendable (Progress) -> Void) async throws -> Track {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoTrackerError.noVideoTrack
        }
        let transform = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration).seconds
        let rotation = rotationClockwise(transform)

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw VideoTrackerError.cannotRead(error.localizedDescription) }
        // Full-range 4:2:0; the first plane is the luma (grayscale) image the tracker needs.
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw VideoTrackerError.cannotRead(reader.error?.localizedDescription ?? "unknown error")
        }

        let tracker = PlateTracker(hint: hint.map { (Double($0.x), Double($0.y)) })
        var firstTime: Double? = nil
        var lastUsed = -Double.infinity
        // A little under the frame spacing, so 240 fps jitter doesn't skip two frames in a row.
        let minGap = maxRate.map { 0.75 / $0 } ?? 0
        var lastReport = -1.0
        while reader.status == .reading {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            let more: Bool = autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { return false }
                guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return true }
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if firstTime == nil { firstTime = time }
                if time - lastUsed < minGap { return true }   // skipped before any copying
                lastUsed = time

                CVPixelBufferLockBaseAddress(pixels, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return true }
                let image = GrayImage(
                    plane: UnsafePointer(base.assumingMemoryBound(to: UInt8.self)),
                    width: CVPixelBufferGetWidthOfPlane(pixels, 0),
                    height: CVPixelBufferGetHeightOfPlane(pixels, 0),
                    bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0),
                    rotationCW: rotation)
                let found = tracker.add(image, time: time)

                let elapsed = time - (firstTime ?? 0)
                if elapsed - lastReport >= 0.1 {
                    lastReport = elapsed
                    progress(Progress(fraction: duration > 0 ? min(elapsed / duration, 1) : 0, plateFound: found != nil))
                }
                return true
            }
            if !more { break }
        }
        if reader.status == .failed {
            throw VideoTrackerError.cannotRead(reader.error?.localizedDescription ?? "unknown error")
        }
        progress(Progress(fraction: 1, plateFound: tracker.current != nil))
        return tracker.finish()
    }

    /// How far the stored frames must be turned clockwise to appear upright (0, 90, 180 or 270).
    static func rotationClockwise(_ t: CGAffineTransform) -> Int {
        let degrees = atan2(Double(t.b), Double(t.a)) * 180 / Double.pi
        let snapped = Int((degrees / 90).rounded()) * 90
        return (snapped % 360 + 360) % 360
    }
}
