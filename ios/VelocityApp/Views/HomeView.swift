import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VelocityCore

/// Start screen: pick a recorded set to analyze, and see sets analyzed this session.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.unit) private var unitRaw = WeightUnit.lb.rawValue
    @State private var pickerItem: PhotosPickerItem?
    @State private var showFiles = false
    @State private var loading = false
    @State private var clip: Clip?
    @State private var errorText: String?
    @State private var showSettings = false
    @State private var showCamera = false

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .lb }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Card {
                        CardLabel(text: "Record a set")
                        Text("Phone on a tripod, level, side-on to the plate, about 1.5 to 3 m away.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.muted)
                        Button {
                            showCamera = true
                        } label: {
                            Label("Open camera", systemImage: "video.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }

                    Card {
                        CardLabel(text: "Analyze a recorded set")
                        Text("Film the set from the side in slow motion (240 fps) with the whole plate in view, then pick the video here.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.muted)
                        PhotosPicker(selection: $pickerItem, matching: .videos, photoLibrary: .shared()) {
                            Label("Choose from Photos", systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        Button {
                            showFiles = true
                        } label: {
                            Label("Choose from Files", systemImage: "folder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        if loading {
                            HStack { ProgressView(); Text("Opening the original video…").foregroundStyle(Theme.muted) }
                        }
                        if let errorText {
                            Text(errorText).font(.footnote).foregroundStyle(Theme.bad)
                        }
                    }

                    if !model.recentSets.isEmpty {
                        CardLabel(text: "This session").padding(.top, 8)
                        ForEach(model.recentSets) { set in
                            NavigationLink(value: set.id) {
                                RecentSetRow(set: set, unit: unit)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle("Velocity")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(item: $clip) { clip in
                SetDetailsView(clip: clip)
            }
            .navigationDestination(for: UUID.self) { id in
                SetResultsView(setID: id)
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(isPresented: $showCamera) { CameraSetupView() }
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
}

extension Clip: Hashable {
    static func == (l: Clip, r: Clip) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

private struct RecentSetRow: View {
    let set: AnalyzedSet
    let unit: WeightUnit

    var body: some View {
        let a = set.analysis
        let m = a.setMetrics
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.input.exercise.name).font(.headline)
                    Text("\(unit.format(kg: a.input.loadKg)) \(unit.rawValue) × \(m?.repCount ?? 0) · \(set.setType.rawValue)")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.velocity(m?.meanVelocity)).font(.title2.weight(.bold)).monospacedDigit()
                    Text("mean m/s").font(.caption).foregroundStyle(Theme.muted)
                }
                Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
            }
        }
    }
}
