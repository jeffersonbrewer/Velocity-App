import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VelocityCore

/// Today's session: pick the exercise, check the next set's load and targets, record, and see
/// the sets done so far.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.unit) private var unitRaw = WeightUnit.lb.rawValue
    @State private var pickerItem: PhotosPickerItem?
    @State private var showFiles = false
    @State private var loading = false
    @State private var clip: Clip?
    @State private var errorText: String?
    @State private var showCamera = false
    @State private var editingTargets = false
    @State private var testing = false

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .lb }
    private var exercise: Exercise { ExerciseCatalog.exercise(id: model.currentExerciseID) ?? ExerciseCatalog.all[0] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    exerciseChips
                    nextSetCard
                    profileStrip
                    let today = model.sets(on: Date())
                    if !today.isEmpty {
                        summaryTiles(today)
                        CardLabel(text: "Done so far").padding(.top, 4)
                        ForEach(today) { set in
                            NavigationLink(value: set.id) { SetRow(set: set, unit: unit, showDate: false) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .keyboardDoneButton()
            .background(Theme.background)
            .navigationTitle("Today")
            .navigationDestination(item: $clip) { clip in SetDetailsView(clip: clip) }
            .navigationDestination(for: UUID.self) { id in SetResultsView(setID: id) }
            .navigationDestination(for: TodayRoute.self) { route in
                switch route { case .profile(let id): ProfileView(exerciseID: id) }
            }
            .fullScreenCover(isPresented: $showCamera) { CameraSetupView() }
            .sheet(isPresented: $editingTargets) { TargetsSheet(exerciseID: model.currentExerciseID) }
            .sheet(isPresented: $testing) { ProfileTestSetupView(exerciseID: model.currentExerciseID) }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .quickTimeMovie, .mpeg4Movie]) { result in
                switch result {
                case .success(let url):
                    do { clip = try ClipLoader.loadFile(url); errorText = nil } catch { errorText = error.localizedDescription }
                case .failure(let error):
                    errorText = error.localizedDescription
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                guard let id = item.itemIdentifier else {
                    errorText = ClipLoaderError.notFound.localizedDescription
                    return
                }
                loading = true
                errorText = nil
                Task {
                    do { clip = try await ClipLoader.loadOriginal(localIdentifier: id) } catch { errorText = error.localizedDescription }
                    loading = false
                    pickerItem = nil
                }
            }
        }
    }

    // MARK: Exercise switching

    private var exerciseChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.quickExerciseIDs, id: \.self) { id in
                    let selected = id == model.currentExerciseID
                    Button {
                        model.currentExerciseID = id
                    } label: {
                        Text(ExerciseCatalog.exercise(id: id)?.name ?? id)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(selected ? Color.black : Color.primary)
                            .background(selected ? Theme.accent : Theme.card, in: Capsule())
                            .overlay(Capsule().stroke(Theme.line))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                Menu {
                    ForEach(ExerciseCatalog.all.filter { !model.quickExerciseIDs.contains($0.id) }) { ex in
                        Button(ex.name) { model.currentExerciseID = ex.id }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Theme.card, in: Capsule())
                        .overlay(Capsule().stroke(Theme.line))
                }
            }
        }
    }

    // MARK: Next set

    private var nextSetCard: some View {
        let id = model.currentExerciseID
        let p = model.prefs(for: id)
        return Card {
            CardLabel(text: "Next set")
            Text(exercise.name).font(.title3.weight(.bold))
            LoadField(loadKg: model.loadBinding(id), unit: unit)
            HStack {
                Text("Set type").foregroundStyle(Theme.muted)
                Spacer()
                Picker("Set type", selection: model.nextSetTypeBinding) {
                    ForEach(SetType.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
            }
            .font(.subheadline)
            if model.nextSetType != .working {
                Text("Tagged sets build your strength profile. Switch back to Working when the test is done.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            Button {
                editingTargets = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Target").font(.caption).foregroundStyle(Theme.muted)
                        Text(p.targetZone.map { "\(Fmt.velocity($0.lowerBound))–\(Fmt.velocity($0.upperBound)) m/s" } ?? "None set")
                            .fontWeight(.semibold)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Stop at").font(.caption).foregroundStyle(Theme.muted)
                        Text(model.lossCutoff(for: id).map { "\(Fmt.percent($0)) loss" } ?? "No cutoff").fontWeight(.semibold)
                    }
                    Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit the target zone and velocity-loss cutoff")

            Button {
                showCamera = true
            } label: {
                Label("Set up camera", systemImage: "video.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                testing = true
            } label: {
                Label("Guided profile test", systemImage: "chart.line.downtrend.xyaxis").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .font(.subheadline)

            HStack {
                PhotosPicker(selection: $pickerItem, matching: .videos, photoLibrary: .shared()) {
                    Label("From Photos", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                }
                Button { showFiles = true } label: {
                    Label("From Files", systemImage: "folder").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .font(.subheadline)
            if loading {
                HStack { ProgressView(); Text("Opening the original video…").foregroundStyle(Theme.muted) }
            }
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(Theme.bad)
            }
        }
    }

    /// Estimated 1RM, today's readiness and a retest nudge for the current exercise.
    @ViewBuilder
    private var profileStrip: some View {
        let id = model.currentExerciseID
        let prof = model.profile(for: id)
        NavigationLink(value: TodayRoute.profile(id)) {
                Card {
                    HStack {
                        CardLabel(text: "Strength profile")
                        Spacer()
                        if prof.retestReason() != nil { Pill(text: "Retest suggested", color: Theme.warn) }
                        Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                    }
                    HStack {
                        Text("Estimated 1RM").foregroundStyle(Theme.muted)
                        Spacer()
                        Text(prof.oneRmKg.map { "\(unit.format(kg: unit.roundedToStep(kg: $0))) \(unit.rawValue)" } ?? "–").monospacedDigit()
                    }
                    .font(.subheadline)
                    if prof.lastTestDate == nil {
                        Text("No profile test yet. Open to enter a known 1RM, edit your 1RM velocity or start a guided test.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    if let r = model.readinessToday(for: id) {
                        HStack {
                            Text("Readiness from first set").foregroundStyle(Theme.muted)
                            Spacer()
                            Pill(text: r.reading.rawValue, color: readinessColor(r.reading))
                        }
                        .font(.subheadline)
                    }
                }
            }
            .buttonStyle(.plain)
    }

    private func summaryTiles(_ today: [AnalyzedSet]) -> some View {
        let volume = today.compactMap { $0.analysis.setMetrics?.volumeLoadKg }.reduce(0, +)
        let best = today.compactMap { $0.analysis.setMetrics?.bestMeanVelocity }.max()
        return HStack(spacing: 12) {
            Card {
                CardLabel(text: "Session volume")
                BigNumber(value: unit.format(kg: volume), unit: unit.rawValue)
            }
            Card {
                CardLabel(text: "Best MV today")
                BigNumber(value: Fmt.velocity(best), unit: "m/s")
            }
        }
    }
}

enum TodayRoute: Hashable { case profile(String) }

extension Clip: Hashable {
    static func == (l: Clip, r: Clip) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// How a set went against its targets.
enum SetStatus {
    case onTarget, outsideZone, nearCutoff, pastCutoff, none

    init(_ m: SetMetrics?) {
        guard let m else { self = .none; return }
        if let cutoff = m.velocityLossThresholdPct {
            if m.velocityLossPct >= cutoff { self = .pastCutoff; return }
            if m.velocityLossPct >= 0.85 * cutoff { self = .nearCutoff; return }
        }
        if !m.outsideTargetReps.isEmpty { self = .outsideZone; return }
        self = m.velocityLossThresholdPct == nil ? .none : .onTarget
    }

    var label: String? {
        switch self {
        case .onTarget: return "On target"
        case .outsideZone: return "Outside zone"
        case .nearCutoff: return "Near cutoff"
        case .pastCutoff: return "Past cutoff"
        case .none: return nil
        }
    }

    var color: Color {
        switch self {
        case .onTarget: return Theme.good
        case .outsideZone, .nearCutoff: return Theme.warn
        case .pastCutoff: return Theme.bad
        case .none: return Theme.muted
        }
    }
}

/// One set in a list: exercise, load × reps, mean velocity and loss.
struct SetRow: View {
    let set: AnalyzedSet
    let unit: WeightUnit
    var showDate = true

    var body: some View {
        let a = set.analysis
        let m = a.setMetrics
        let status = SetStatus(m)
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(a.input.exercise.name) · \(unit.format(kg: a.input.loadKg)) \(unit.rawValue) × \(m?.repCount ?? 0)")
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text("MV \(Fmt.velocity(m?.meanVelocity)) · loss \(Fmt.percent(m?.velocityLossPct))")
                        if set.setType != .working { Text("· \(set.setType.rawValue)") }
                        if showDate { Text("· \(set.date.formatted(date: .abbreviated, time: .shortened))") }
                    }
                    .font(.subheadline).foregroundStyle(Theme.muted)
                }
                Spacer()
                if let label = status.label {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .foregroundStyle(status.color)
                        .overlay(Capsule().stroke(status.color))
                }
                Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
            }
        }
    }
}
