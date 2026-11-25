import AVFoundation
import Combine
import SwiftUI
import VelocityCore

/// Record a set: line up the camera with the live plate and level checks, record, and get results.
/// With a profile test plan, the camera stays on this screen for the whole ramp: each load is
/// analyzed and the next one is set up without opening the results.
struct CameraSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraRecorder()
    @AppStorage(SettingsKey.unit) private var unitRaw = WeightUnit.lb.rawValue
    @AppStorage(SettingsKey.keepSetVideos) private var keepVideos = false
    @State private var analyzing: VideoTracker.Progress?
    @State private var errorText: String?
    @State private var resultID: UUID?
    @State private var now = Date()
    @State private var test: ProfileTestPlan?
    @State private var lastSetEnd: Date?
    @State private var adjustNote: String?
    @State private var reviewSetID: UUID?
    @State private var showDetails = false
    @State private var dimmer = ScreenDimmer()
    @AppStorage(SettingsKey.dimWhileRecording) private var dimWhileRecording = true
    @State private var restCueKey: Date?
    @State private var restWarned = false
    @State private var restDoneSounded = false

    init(test: ProfileTestPlan? = nil) { _test = State(initialValue: test) }

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .lb }
    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                preview
                controls
            }
            .background(Theme.background)
            .keyboardDoneButton()
            .navigationTitle(test == nil ? "Record a set" : "Profile test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(test == nil ? "Close" : "End test") { camera.stop(); finishTest(); dismiss() }
                        .disabled(isRecording || analyzing != nil)
                }
            }
            .navigationDestination(item: $resultID) { id in
                SetResultsView(setID: id)
                    .safeAreaInset(edge: .bottom) { afterSetPanel(id) }
            }
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true  // keep the screen on between sets
                camera.start()
                applyCurrentStep()
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
                dimmer.restore()
                camera.cues.stop()
                model.nextSetRepCap = nil
                model.sessionTargets = nil
            }
            .onChange(of: resultID) { _, id in if id == nil { camera.start() } }
            .onReceive(ticker) { now = $0; restCues() }
            .onChange(of: camera.liveSettled) { _, done in
                if done && isRecording { stopAndAnalyze() }   // the bar has stayed still after the last rep
            }
            .onChange(of: isRecording) { _, rec in
                if rec && dimWhileRecording { dimmer.dim() } else { dimmer.restore() }
                if rec { model.rest = nil }   // the next set has started
            }
            .simultaneousGesture(TapGesture().onEnded { if dimmer.isDimmed { dimmer.peek() } })
            .sheet(isPresented: $showDetails, onDismiss: refreshTest) {
                if let id = reviewSetID {
                    NavigationStack {
                        SetResultsView(setID: id)
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showDetails = false } } }
                    }
                }
            }
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
                if !isRecording && analyzing == nil { plateTapCatcher }
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
            if test == nil && !isRecording && analyzing == nil && model.rest != nil {
                VStack {
                    Spacer()
                    RestTimerBar(now: now, detail: restDetail)
                }
                .padding(8)
            }
            if case .recording(let started) = camera.state {
                Text(timeString(now.timeIntervalSince(started)))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Theme.bad, in: Capsule())
                    .padding(8)
                liveOverlay
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

    /// Tap a plate to tell the app which one is on the bar.
    private var plateTapCatcher: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in
                    guard camera.imageSize.width > 0 else { return }
                    let s = geo.size.width / camera.imageSize.width
                    let x = p.x / s, y = p.y / s
                    if let hit = camera.plates.first(where: { hypot($0.x - x, $0.y - y) <= $0.r * 1.1 }) {
                        camera.plateHint = CGPoint(x: hit.x, y: hit.y)
                    }
                }
        }
        .accessibilityHidden(true)
    }

    private var plateOverlay: some View {
        GeometryReader { geo in
            if camera.imageSize.width > 0 {
                let s = geo.size.width / camera.imageSize.width
                // Other plates in view, dashed: tap the right one if the app picked the wrong plate.
                ForEach(Array(camera.plates.enumerated()), id: \.offset) { _, o in
                    if camera.plate.map({ hypot($0.x - o.x, $0.y - o.y) > 1 }) ?? true {
                        Circle()
                            .stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                            .frame(width: 2 * o.r * s, height: 2 * o.r * s)
                            .position(x: o.x * s, y: o.y * s)
                    }
                }
            }
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
        guard let c = camera.plate, camera.plates.count <= 1 || camera.plateHint != nil else { return false }
        return c.roundness >= 0.94 && c.r >= 0.08 * camera.imageSize.width
    }

    private var plateChip: some View {
        let text: String
        if camera.plates.count > 1 && camera.plateHint == nil {
            text = "Tap the plate on the bar"
        } else if let c = camera.plate {
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
            if test != nil {
                testPanel
            } else {
                setPickers
                LoadField(loadKg: model.loadBinding(model.currentExerciseID), unit: unit)
            }
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(Theme.bad)
            }
            if test?.finished == true {
                Button { finishTest(); camera.stop(); dismiss() } label: {
                    Text("Done").frame(maxWidth: .infinity).fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                recordButton
            }
            if isRecording && camera.droppedFrames > 0 {
                Text("\(camera.droppedFrames) frames dropped").font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .padding()
        .disabled(analyzing != nil)
    }

    private var setPickers: some View {
        HStack {
            Picker("Exercise", selection: model.exerciseBinding) {
                ForEach(ExerciseCatalog.all) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.menu)
            Spacer()
            Picker("Set type", selection: model.nextSetTypeBinding) {
                ForEach(SetType.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: Guided profile test

    @ViewBuilder
    private var testPanel: some View {
        if let plan = test {
            let profile = model.profile(for: plan.exerciseID)
            VStack(alignment: .leading, spacing: 8) {
                // Loads done so far, with each one's fastest rep.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(plan.steps.enumerated()), id: \.element.id) { i, step in
                            Button { if let id = step.setID { reviewSetID = id } } label: {
                                stepChip(step, current: i == plan.currentIndex)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.warn, lineWidth: step.setID != nil && step.setID == reviewSetID ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                            .disabled(step.setID == nil || isRecording)
                        }
                    }
                }
                if let id = reviewSetID, let set = model.set(id) {
                    RepReviewStrip(set: set, unit: unit, onToggle: { k in toggleRep(id, k) }, onDetails: { showDetails = true })
                }
                if let i = plan.currentIndex {
                    let step = plan.steps[i]
                    HStack {
                        Text(step.isMaxSingle ? "Max single" : "Load \(i + 1) of \(plan.steps.filter { !$0.isMaxSingle }.count)")
                            .font(.headline)
                        Text("· \(step.reps) fast rep\(step.reps == 1 ? "" : "s")").foregroundStyle(Theme.muted)
                        Spacer()
                        if let end = lastSetEnd, !isRecording {
                            Text("Rest \(timeString(now.timeIntervalSince(end)))")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(now.timeIntervalSince(end) >= restSeconds(step) ? Theme.good : Theme.muted)
                        }
                    }
                    Text("Load the bar to \(unit.format(kg: step.loadKg)) \(unit.rawValue)")
                        .font(.title3.weight(.bold))
                    LoadField(loadKg: stepLoadBinding(i), unit: unit, label: "Change load")
                    if let adjustNote {
                        Text(adjustNote).font(.caption).foregroundStyle(Theme.accent)
                    }
                    HStack {
                        if plan.recordedCount >= 2, let orm = profile.oneRmKg {
                            Text("1RM so far: \(unit.format(kg: unit.roundedToStep(kg: orm))) \(unit.rawValue)")
                                .font(.subheadline.weight(.semibold))
                        }
                        Spacer()
                        Button(step.isMaxSingle ? "Skip max single" : "Skip this load") { skip(i) }
                            .font(.subheadline)
                            .disabled(isRecording)
                    }
                    if nearMax(plan, profile) {
                        HStack {
                            Text("That last set was close to your 1RM velocity. You can stop here.")
                                .font(.caption).foregroundStyle(Theme.warn)
                            Button("Finish") { skipRemaining() }.font(.caption.weight(.semibold))
                        }
                    }
                } else {
                    Text("Test complete").font(.headline)
                    if let orm = profile.oneRmKg {
                        Text("Estimated 1RM \(unit.format(kg: unit.roundedToStep(kg: orm))) \(unit.rawValue) at \(Fmt.velocity(profile.mvt)) m/s")
                            .font(.subheadline)
                    } else if let why = profile.lineProblem {
                        Text(why).font(.subheadline).foregroundStyle(Theme.muted)
                    }
                    Text("The full line is on the exercise's profile.").font(.caption).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private func stepChip(_ step: ProfileTestStep, current: Bool) -> some View {
        VStack(spacing: 1) {
            Text("\(unit.format(kg: step.loadKg))").font(.caption.weight(.semibold)).monospacedDigit()
            Text(step.skipped ? "skip" : (step.bestMeanVelocity.map { Fmt.velocity($0) } ?? (step.isMaxSingle ? "max" : "–")))
                .font(.caption2).monospacedDigit()
                .foregroundStyle(step.bestMeanVelocity != nil ? Theme.good : Theme.muted)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(current ? Theme.accent.opacity(0.25) : Theme.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(current ? Theme.accent : Theme.line))
    }

    private func restSeconds(_ step: ProfileTestStep) -> TimeInterval { step.reps >= 2 ? 120 : 180 }

    private func stepLoadBinding(_ i: Int) -> Binding<Double> {
        Binding(get: { test?.steps[i].loadKg ?? 0 },
                set: { v in test?.steps[i].loadKg = max(0, v); test?.steps[i].edited = true; applyCurrentStep() })
    }

    /// The last recorded set's fastest rep was within 0.10 m/s of the 1RM velocity.
    private func nearMax(_ plan: ProfileTestPlan, _ profile: StrengthProfile) -> Bool {
        guard let mvt = profile.mvt ?? ExerciseCatalog.exercise(id: plan.exerciseID)?.defaultMvt,
              let last = plan.steps.last(where: { $0.bestMeanVelocity != nil })?.bestMeanVelocity else { return false }
        return last <= mvt + 0.10
    }

    private func skip(_ i: Int) {
        test?.steps[i].skipped = true
        applyCurrentStep()
    }

    private func skipRemaining() {
        guard var plan = test else { return }
        for i in plan.steps.indices where !plan.steps[i].done { plan.steps[i].skipped = true }
        test = plan
    }

    /// Point the exercise, load and set type at the current step of the test.
    private func applyCurrentStep() {
        guard let plan = test else { return }
        model.currentExerciseID = plan.exerciseID
        guard let i = plan.currentIndex else { return }
        let step = plan.steps[i]
        var p = model.prefs(for: plan.exerciseID)
        p.loadKg = step.loadKg
        model.prefs[plan.exerciseID] = p
        model.nextSetType = step.isMaxSingle ? .maxSingle : .profileTest
        model.nextSetRepCap = step.reps
    }

    /// Live counting settings for the set about to be recorded, or nil with sound cues and auto-stop off.
    private func liveSettings() -> CameraRecorder.LiveSettings? {
        let d = UserDefaults.standard
        let sounds = d.object(forKey: SettingsKey.liveCues) as? Bool ?? true
        let settle = SettingsKey.autoStopSeconds(d)
        guard sounds || settle != nil else { return nil }
        let a = SettingsKey.analysisSettings()
        // A profile test stops on its rep count, never on velocity loss.
        return CameraRecorder.LiveSettings(lossCutoffPct: test == nil ? model.lossCutoff(for: model.currentExerciseID) : nil,
                                           repCap: model.nextSetRepCap, plateDiameterM: a.plateDiameterM,
                                           cutoffHz: a.cutoffHz, speakReps: d.bool(forKey: SettingsKey.speakReps),
                                           sounds: sounds, settleSeconds: settle)
    }

    /// Live rep count while recording: big enough for a coach beside the phone to read.
    @ViewBuilder
    private var liveOverlay: some View {
        if isRecording {
            VStack(spacing: 6) {
                Spacer()
                if let last = camera.liveReps.last {
                    Text("Rep \(last.number)  \(Fmt.velocity(last.meanVelocity)) m/s")
                        .font(.title2.weight(.bold).monospacedDigit())
                    Text("Loss \(Fmt.percent(last.lossPct))\(last.likelyBounce ? " · bounce?" : "")")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(last.likelyBounce ? Theme.warn : .white)
                } else {
                    Text(camera.liveTracking ? "Tracking the plate" : "Looking for the plate…")
                        .font(.headline)
                }
                if let stop = camera.liveStop {
                    Text(stopText(stop)).font(.headline).padding(.horizontal, 12).padding(.vertical, 4)
                        .background(Theme.bad, in: Capsule())
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
            .allowsHitTesting(false)
        }
    }

    private func stopText(_ s: LiveRepCounter.StopReason) -> String {
        switch s {
        case .lossCutoff(let c): return "STOP: \(Fmt.percent(c)) velocity loss"
        case .repCap(let n): return "STOP: \(n) rep\(n == 1 ? "" : "s") done"
        }
    }

    /// Leave a rep out or bring it back, then update the test from the edited set.
    private func toggleRep(_ setID: UUID, _ index: Int) {
        guard var s = model.set(setID), s.analysis.reps.indices.contains(index) else { return }
        s.analysis.reps[index].deleted.toggle()
        model.update(s)
        refreshTest()
    }

    /// Re-read each recorded load's fastest rep after edits and re-plan the loads still to come.
    private func refreshTest() {
        guard var plan = test else { return }
        for i in plan.steps.indices {
            guard let id = plan.steps[i].setID else { continue }
            if let m = model.set(id)?.analysis.setMetrics, m.repCount > 0 {
                plan.steps[i].bestMeanVelocity = m.bestMeanVelocity
            } else {
                // Every rep was left out: record this load again.
                plan.steps[i].setID = nil
                plan.steps[i].bestMeanVelocity = nil
                plan.steps[i].skipped = false
            }
        }
        let ex = ExerciseCatalog.exercise(id: plan.exerciseID)
        let mvt = model.profile(for: plan.exerciseID).mvt ?? model.prefs(for: plan.exerciseID).editedMvt ?? ex?.defaultMvt
        plan.planKg = plan.guessKg
        _ = plan.adapt(mvt: (ex?.allowsOneRm ?? true) ? mvt : nil, unit: unit)
        test = plan
        applyCurrentStep()
    }

    private func finishTest() {
        guard test != nil else { return }
        model.nextSetType = .working
    }

    private var recordButton: some View {
        Button {
            if isRecording { stopAndAnalyze() } else { errorText = nil; camera.startRecording(live: liveSettings()) }
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
        let type = model.nextSetType
        let keep = keepVideos
        let hint = camera.recordedHint
        let liveCount = camera.liveReps.count
        let inProgram = model.sessionTargets != nil
        if test == nil { model.startRest() }
        camera.stopRecording { url in
            guard let url else { errorText = "Nothing was recorded. Try again."; return }
            camera.stop()  // free the processor for the analysis
            analyzing = VideoTracker.Progress(fraction: 0, plateFound: false)
            Task {
                // Keep analyzing if the lifter leaves the app; if iOS stops it anyway, try again
                // once the app is back in front.
                var bg = UIBackgroundTaskIdentifier.invalid
                bg = UIApplication.shared.beginBackgroundTask(withName: "Analyze set") {
                    UIApplication.shared.endBackgroundTask(bg); bg = .invalid
                }
                defer { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) } }
                do {
                    var result: SetAnalysis?
                    var lastError: Error?
                    for attempt in 0..<2 where result == nil {
                        if attempt > 0 {
                            while UIApplication.shared.applicationState != .active { try? await Task.sleep(for: .milliseconds(500)) }
                        }
                        do {
                            result = try await Task.detached(priority: .userInitiated) {
                                let track = try await VideoTracker.track(AVURLAsset(url: url), hint: hint) { p in
                                    Task { @MainActor in analyzing = p }
                                }
                                return try SetAnalyzer.analyze(track: track, input: input, settings: settings)
                            }.value
                        } catch {
                            lastError = error
                        }
                    }
                    guard let analysis = result else {
                        // Never lose the set: in a program session, keep the live rep count as a set logged by hand.
                        if inProgram && liveCount > 0 {
                            model.manualSets.append(ManualSet(date: Date(), exerciseID: id, loadKg: input.loadKg, reps: liveCount, rir: nil))
                            throw AnalysisFallback.savedLiveCount(liveCount)
                        }
                        throw lastError ?? AnalysisFallback.failed
                    }
                    let set = AnalyzedSet(date: Date(), clipName: "Recorded set", setType: type, analysis: analysis)
                    analyzing = nil
                    if var plan = test, let i = plan.currentIndex {
                        // In a profile test, stay on the camera and move to the next load.
                        if let m = set.analysis.setMetrics, m.repCount > 0 {
                            model.add(set)
                            plan.steps[i].setID = set.id
                            plan.steps[i].bestMeanVelocity = m.bestMeanVelocity
                            reviewSetID = set.id
                            let ex = ExerciseCatalog.exercise(id: plan.exerciseID)
                            let mvt = model.profile(for: plan.exerciseID).mvt ?? model.prefs(for: plan.exerciseID).editedMvt ?? ex?.defaultMvt
                            if plan.adapt(mvt: (ex?.allowsOneRm ?? true) ? mvt : nil, unit: unit) {
                                let lower = plan.planKg < plan.guessKg
                                adjustNote = "Next loads adjusted: so far your 1RM looks closer to \(unit.format(kg: unit.roundedToStep(kg: plan.planKg))) \(unit.rawValue)\(lower ? " than your guess" : "")."
                            }
                            test = plan
                            applyCurrentStep()
                        } else {
                            errorText = "No reps were found in that set. Check the plate is in view and record this load again."
                        }
                        lastSetEnd = Date()
                        if !(test?.finished ?? true) { camera.start() }
                    } else {
                        model.add(set)
                        resultID = set.id
                        announceNext()
                    }
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

    enum AnalysisFallback: LocalizedError {
        case savedLiveCount(Int)
        case failed
        var errorDescription: String? {
            switch self {
            case .savedLiveCount(let n): return "The analysis didn't finish, so the live count (\(n) rep\(n == 1 ? "" : "s")) was saved as a set logged by hand."
            case .failed: return "The analysis didn't finish. Record the set again, or log it by hand."
            }
        }
    }

    // MARK: Between sets

    /// Under the set results: what happens next, the rest timer, and Next set.
    private func afterSetPanel(_ id: UUID) -> some View {
        let summary = model.afterSetSummary(setID: id)
        return VStack(alignment: .leading, spacing: 8) {
            if test == nil && model.rest != nil { RestTimerBar(now: now) }
            if let summary {
                Text(summary.text).font(.subheadline)
            }
            HStack {
                if summary?.done == true {
                    Button { camera.stop(); dismiss() } label: { Text("Back to session").frame(maxWidth: .infinity).fontWeight(.semibold) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button { nextSet() } label: {
                        Text(summary?.isWarmUp == true ? "Save and start working sets" : "Next set").frame(maxWidth: .infinity).fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    if summary != nil {
                        Button { camera.stop(); dismiss() } label: { Text("Session") }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .controlSize(.large)
        }
        .padding(12)
        .background(.bar)
    }

    /// Back to the camera, set up for the program's next set when there is one.
    private func nextSet() {
        if model.sessionTargets != nil, let plan = model.sessionPlan() {
            // The lift is finished: go to the next lift's warm-up, or back to the session for accessories.
            if plan.doneReason != nil {
                camera.stop(); dismiss(); return
            }
            model.prepareMainSet(plan, loadKg: plan.nextLoadKg)
        }
        resultID = nil
    }

    /// The next set, shown under the rest timer on the camera.
    private var restDetail: String? {
        guard model.sessionTargets != nil, let plan = model.sessionPlan(), plan.doneReason == nil else { return nil }
        return "Next: \(unit.format(kg: plan.nextLoadKg)) \(unit.rawValue) · stop at \(Fmt.percent(plan.prescription.lossCutoffPct)) loss or \(plan.prescription.repCapPerSet) reps"
    }

    /// Say the next load at the start of rest, when sound cues are on.
    private func announceNext() {
        guard UserDefaults.standard.object(forKey: SettingsKey.liveCues) as? Bool ?? true else { return }
        camera.cues.start()
        if model.sessionTargets != nil, let plan = model.sessionPlan() {
            if plan.doneReason != nil { camera.cues.say("Main lift done.") }
            else { camera.cues.say("Next set, \(unit.format(kg: plan.nextLoadKg)) \(unit == .lb ? "pounds" : "kilos").") }
        }
    }

    /// Tones 30 seconds before rest is done and when it is.
    private func restCues() {
        guard let r = model.rest, UserDefaults.standard.object(forKey: SettingsKey.liveCues) as? Bool ?? true else { return }
        let key = r.start.addingTimeInterval(r.extraSec)
        if restCueKey != key { restCueKey = key; restWarned = false; restDoneSounded = false }
        let t = r.elapsed(now)
        camera.cues.start()
        if !restWarned && r.doneAt > 45 && t >= r.doneAt - 30 && t < r.doneAt { restWarned = true; camera.cues.restWarning() }
        if !restDoneSounded && t >= r.doneAt { restDoneSounded = true; restWarned = true; camera.cues.restDone() }
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

/// The reps of one recorded load, for a quick check during a profile test: tap a rep to leave it
/// out or bring it back. Reps screening questioned are marked.
struct RepReviewStrip: View {
    let set: AnalyzedSet
    let unit: WeightUnit
    let onToggle: (Int) -> Void
    let onDetails: () -> Void

    var body: some View {
        let a = set.analysis
        let kept = a.reps.filter { !$0.deleted }.map(\.id)
        let mvByID = Dictionary(uniqueKeysWithValues: zip(kept, (a.setMetrics?.reps ?? []).map(\.meanVelocity)))
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(unit.format(kg: a.input.loadKg)) \(unit.rawValue): tap a rep to leave it out").font(.caption).foregroundStyle(Theme.muted)
                Spacer()
                Button("Details", action: onDetails).font(.caption.weight(.semibold))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(a.reps.enumerated()), id: \.offset) { k, rep in
                        Button { onToggle(k) } label: {
                            VStack(spacing: 1) {
                                Text("Rep \(k + 1)").font(.caption2)
                                Text(rep.deleted ? "out" : Fmt.velocity(mvByID[rep.id]))
                                    .font(.caption.weight(.semibold)).monospacedDigit()
                                    .strikethrough(rep.deleted)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .foregroundStyle(rep.deleted ? Theme.muted : (rep.flag != nil ? Theme.warn : Color.primary))
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(rep.flag != nil ? Theme.warn : Theme.line))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Rep \(k + 1), \(rep.deleted ? "left out" : "kept")\(rep.flag.map { ", " + $0 } ?? "")")
                    }
                }
            }
            if let flag = a.reps.first(where: { $0.flag != nil && !$0.deleted })?.flag {
                Text(flag).font(.caption2).foregroundStyle(Theme.warn)
            }
        }
    }
}
