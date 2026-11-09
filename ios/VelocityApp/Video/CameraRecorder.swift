import AVFoundation
import CoreMotion
import Photos
import UIKit
import VelocityCore

/// Runs the back camera at 240 fps (120 in poor light or on formats without 240), shows a live
/// plate and level check, and records the set to a movie file with every frame's real timestamp.
final class CameraRecorder: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case denied
        case failed(String)
        case ready
        case recording(started: Date)
        case finishing
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var frameRate: Double = 0
    /// Latest plate found by the plate check, in upright image pixels.
    @Published private(set) var plate: PlateCircle?
    @Published private(set) var imageSize: CGSize = .zero
    /// Phone tilt in degrees: forward/back (pitch) and sideways (roll). 0 and 0 is upright and level.
    @Published private(set) var pitch: Double = 0
    @Published private(set) var roll: Double = 0
    @Published private(set) var droppedFrames = 0

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let videoQueue = DispatchQueue(label: "camera.video", qos: .userInteractive)
    private let checkQueue = DispatchQueue(label: "camera.platecheck", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private let motion = CMMotionManager()

    // Accessed on videoQueue only.
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var writerStarted = false
    private var recordingURL: URL?
    private var stopCompletion: ((URL?) -> Void)?
    private var lastCheck: CFTimeInterval = 0
    private var checking = false
    private var dropped = 0

    // MARK: Session

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { self.configure() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                if ok { self.sessionQueue.async { self.configure() } } else { self.set(.denied) }
            }
        default:
            set(.denied)
        }
        startMotion()
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func configure() {
        if session.isRunning { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            set(.failed("No back camera found.")); return
        }
        session.beginConfiguration()
        session.sessionPreset = .inputPriority  // we choose the format ourselves
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CameraError.setup }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            set(.failed("Couldn't open the camera.")); return
        }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = false
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            set(.failed("Couldn't set up video capture.")); return
        }
        session.addOutput(output)
        if let conn = output.connection(with: .video), conn.isVideoStabilizationSupported {
            // Stabilization shifts and warps the image, which would corrupt bar positions.
            conn.preferredVideoStabilizationMode = .off
        }
        let fps = Self.selectHighFrameRateFormat(device)
        session.commitConfiguration()
        session.startRunning()
        DispatchQueue.main.async {
            self.frameRate = fps
            self.state = fps > 0 ? .ready : .failed("This camera can't film in slow motion.")
        }
    }

    /// Pick a 1080p format that runs at 240 fps (or 120 if 240 is not available) and lock it there.
    private static func selectHighFrameRateFormat(_ device: AVCaptureDevice) -> Double {
        for target in [240.0, 120.0] {
            let candidates = device.formats.filter { f in
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                return d.width == 1920 && d.height == 1080
                    && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= target }
            }
            // Prefer full-range formats, as the camera app does.
            let best = candidates.first {
                CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            } ?? candidates.first
            guard let format = best else { continue }
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                let duration = CMTime(value: 1, timescale: CMTimeScale(target))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                device.unlockForConfiguration()
                return target
            } catch {
                continue
            }
        }
        return 0
    }

    // MARK: Recording

    func startRecording() {
        guard state == .ready else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("set-\(UUID().uuidString).mov")
        let settings = output.recommendedVideoSettings(forVideoCodecType: .hevc, assetWriterOutputFileType: .mov)
            ?? output.recommendedVideoSettingsForAssetWriter(writingTo: .mov)
        videoQueue.async {
            do {
                let w = try AVAssetWriter(outputURL: url, fileType: .mov)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                input.expectsMediaDataInRealTime = true
                // Frames arrive sideways from the sensor; store them upright like the Camera app does.
                input.transform = CGAffineTransform(rotationAngle: .pi / 2)
                guard w.canAdd(input) else { throw CameraError.setup }
                w.add(input)
                guard w.startWriting() else { throw w.error ?? CameraError.setup }
                self.writer = w
                self.writerInput = input
                self.writerStarted = false
                self.recordingURL = url
                self.dropped = 0
                DispatchQueue.main.async { self.droppedFrames = 0; self.state = .recording(started: Date()) }
            } catch {
                DispatchQueue.main.async { self.state = .failed("Couldn't start recording: \(error.localizedDescription)") }
            }
        }
    }

    /// Stop recording. The completion gets the movie file, or nil if nothing was recorded.
    func stopRecording(_ completion: @escaping (URL?) -> Void) {
        set(.finishing)
        videoQueue.async {
            guard let w = self.writer, let input = self.writerInput else {
                DispatchQueue.main.async { self.state = .ready; completion(nil) }
                return
            }
            self.writer = nil
            self.writerInput = nil
            let url = self.recordingURL
            guard self.writerStarted else {
                w.cancelWriting()
                DispatchQueue.main.async { self.state = .ready; completion(nil) }
                return
            }
            input.markAsFinished()
            w.finishWriting {
                let ok = w.status == .completed
                DispatchQueue.main.async {
                    self.state = .ready
                    completion(ok ? url : nil)
                }
            }
        }
    }

    // MARK: Level

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 15
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let g = data?.gravity else { return }
            // Upright portrait: gravity points down the screen (y = -1).
            self?.pitch = asin(max(-1, min(1, g.z))) * 180 / .pi
            self?.roll = atan2(g.x, -g.y) * 180 / .pi
        }
    }

    private func set(_ s: State) { DispatchQueue.main.async { self.state = s } }

    enum CameraError: Error { case setup }

    /// Save a recorded set to Photos (when the lifter keeps set videos).
    static func saveToPhotos(_ url: URL) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
        }
    }
}

extension CameraRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let w = writer, let input = writerInput {
            if !writerStarted {
                w.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                writerStarted = true
            }
            if input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            } else {
                dropped += 1
                let d = dropped
                DispatchQueue.main.async { self.droppedFrames = d }
            }
            return  // no plate check while recording, so every frame gets written
        }
        plateCheck(sampleBuffer)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard writer != nil else { return }
        dropped += 1
        let d = dropped
        DispatchQueue.main.async { self.droppedFrames = d }
    }

    /// About three times a second, look for the plate in the current frame.
    private func plateCheck(_ sampleBuffer: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        guard !checking, now - lastCheck > 0.33, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastCheck = now
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return }
        let image = GrayImage(
            plane: UnsafePointer(base.assumingMemoryBound(to: UInt8.self)),
            width: CVPixelBufferGetWidthOfPlane(pixels, 0),
            height: CVPixelBufferGetHeightOfPlane(pixels, 0),
            bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0),
            rotationCW: 90)
        checking = true
        checkQueue.async {
            let found = PlateDetector.detect(image)
            DispatchQueue.main.async {
                self.plate = found
                self.imageSize = CGSize(width: image.width, height: image.height)
            }
            self.videoQueue.async { self.checking = false }
        }
    }
}
