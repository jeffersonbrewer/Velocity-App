import AVFoundation
import Combine
import SwiftUI
import VelocityCore

/// Record a set: line up the camera with the live plate and level checks, record, and get results.
struct CameraSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraRecorder()
    @AppStorage(SettingsKey.unit) private var unitRaw = WeightUnit.lb.rawValue
    @AppStorage(SettingsKey.keepSetVideos) private var keepVideos = false
    @State private var setType: SetType = .working
    @State private var analyzing: VideoTracker.Progress?
    @State private var errorText: String?
    @State private var resultID: UUID?
    @State private var now = Date()

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .lb }
    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                preview
                controls
            }
            .background(Theme.background)
            .navigationTitle("Record a set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { camera.stop(); dismiss() }
                        .disabled(isRecording || analyzing != nil)
                }
            }
            .navigationDestination(item: $resultID) { id in SetResultsView(setID: id) }
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true  // keep the screen on between sets
                camera.start()
            }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            .onChange(of: resultID) { _, id in if id == nil { camera.start() } }
            .onReceive(ticker) { now = $0 }
        }
    }

    private var isRecording: Bool {
        if case .recording = camera.state { return true }
        return false
    }

    // MARK: Preview with the plate and level checks

    private var preview: some View {
        ZStack(alignment: .top) {
            ZStack {
                CameraPreview(session: camera.session)
                plateOverlay
            }
            .aspectRatio(1080.0 / 1920.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if analyzing == nil && !isRecording {
                HStack(spacing: 6) {
                    plateChip
                    levelChip
                    fpsChip
                }
                .padding(8)
            }
            if case .recording(let started) = camera.state {
                Text(timeString(now.timeIntervalSince(started)))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Theme.bad, in: Capsule())
                    .padding(8)
            }
            if let p = analyzing {
                VStack(spacing: 10) {
                    ProgressView(value: p.fraction).tint(Theme.accent)
                    Text("Analyzing the set…").font(.headline)
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(40)
                .frame(maxHeight: .infinity)
            }
            if case .denied = camera.state {
                message("Velocity needs the camera to record sets. Turn it on in Settings › Velocity › Camera.")
            }
            if case .failed(let why) = camera.state { message(why) }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }

    private var plateOverlay: some View {
        GeometryReader { geo in
            if let c = camera.plate, camera.imageSize.width > 0 {
                let s = geo.size.width / camera.imageSize.width
                Circle()
                    .stroke(plateOK ? Theme.good : Theme.warn, lineWidth: 3)
                    .frame(width: 2 * c.r * s, height: 2 * c.r * s)
                    .position(x: c.x * s, y: c.y * s)
                Circle()
                    .fill(plateOK ? Theme.good : Theme.warn)
                    .frame(width: 8, height: 8)
                    .position(x: c.x * s, y: c.y * s)
            }
        }
        .allowsHitTesting(false)
    }

    private var plateOK: Bool {
        guard let c = camera.plate else { return false }
        return c.roundness >= 0.94 && c.r >= 0.08 * camera.imageSize.width
    }

    private var plateChip: some View {
        let text: String
        if let c = camera.plate {
            if c.r < 0.08 * camera.imageSize.width { text = "Move closer" }
            else if c.roundness < 0.94 { text = "Face the plate square-on" }
            else { text = "Plate found" }
        } else {
            text = "Find the plate"
        }
        return chip(text, ok: plateOK)
    }

    private var levelChip: some View {
        let ok = abs(camera.roll) < 2 && abs(camera.pitch) < 4
        let text = ok ? "Level" : String(format: "Tilt %.0f°", max(abs(camera.roll), abs(camera.pitch)))
        return chip(text, ok: ok)
    }

    private var fpsChip: some View {
        chip(camera.frameRate > 0 ? "\(Int(camera.frameRate)) fps" : "Camera…", ok: camera.frameRate >= 240)
    }

    private func chip(_ text: String, ok: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .foregroundStyle(ok ? Theme.good : Theme.warn)
        .background(.black.opacity(0.6), in: Capsule())
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .padding()
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            .padding(30)
            .frame(maxHeight: .infinity)
    }

    // MARK: Set details and record button

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Picker("Exercise", selection: model.exerciseBinding) {
                    ForEach(ExerciseCatalog.all) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                Spacer()
                Picker("Set type", selection: $setType) {
                    ForEach(SetType.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
            }
            LoadField(loadKg: model.loadBinding(model.currentExerciseID), unit: unit)
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(Theme.bad)
            }
            recordButton
            if isRecording && camera.droppedFrames > 0 {
                Text("\(camera.droppedFrames) frames dropped").font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .padding()
        .disabled(analyzing != nil)
    }

    private var recordButton: some View {
        Button {
            if isRecording { stopAndAnalyze() } else { errorText = nil; camera.startRecording() }
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                if isRecording {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.bad).frame(width: 30, height: 30)
                } else {
                    Circle().fill(Theme.bad).frame(width: 58, height: 58)
                }
            }
        }
        .disabled(!(camera.state == .ready || isRecording))
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }

    private func stopAndAnalyze() {
        let id = model.currentExerciseID
        let input = model.setInput(exerciseID: id, loadKg: model.prefs(for: id).loadKg)
        let settings = SettingsKey.analysisSettings()
        let type = setType
        let keep = keepVideos
        camera.stopRecording { url in
            guard let url else { errorText = "Nothing was recorded. Try again."; return }
            camera.stop()  // free the processor for the analysis
            analyzing = VideoTracker.Progress(fraction: 0, plateFound: false)
            Task {
                do {
                    let analysis = try await Task.detached(priority: .userInitiated) {
                        let track = try await VideoTracker.track(AVURLAsset(url: url)) { p in
                            Task { @MainActor in analyzing = p }
                        }
                        return try SetAnalyzer.analyze(track: track, input: input, settings: settings)
                    }.value
                    let set = AnalyzedSet(date: Date(), clipName: "Recorded set", setType: type, analysis: analysis)
                    model.add(set)
                    analyzing = nil
                    resultID = set.id
                } catch {
                    analyzing = nil
                    errorText = error.localizedDescription
                    camera.start()
                }
                // Raw video is deleted after analysis unless the lifter keeps set videos.
                if keep { await CameraRecorder.saveToPhotos(url) }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

/// The live camera image, fitted (not cropped) so the overlay lines up with the analyzed frame.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        if let conn = v.previewLayer.connection, conn.isVideoRotationAngleSupported(90) {
            conn.videoRotationAngle = 90
        }
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if let conn = uiView.previewLayer.connection, conn.videoRotationAngle != 90, conn.isVideoRotationAngleSupported(90) {
            conn.videoRotationAngle = 90
        }
    }
}
