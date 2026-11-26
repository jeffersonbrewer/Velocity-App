import SwiftUI
import VelocityCore

struct SettingsView: View {
    var showsDone = true
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.unit) private var unitRaw = WeightUnit.lb.rawValue
    @AppStorage(SettingsKey.bodyMassKg) private var bodyMassKg = 0.0
    @AppStorage(SettingsKey.velocityLossCutoff) private var lossCutoff = 20.0
    @AppStorage(SettingsKey.cutoffHz) private var cutoffHz = 8.0
    @AppStorage(SettingsKey.plateDiameterCm) private var plateCm = 45.0
    @AppStorage(SettingsKey.tiltCorrection) private var tilt = true
    @AppStorage(SettingsKey.analyzeEveryFrame) private var everyFrame = false
    @AppStorage(SettingsKey.keepSetVideos) private var keepVideos = false
    @AppStorage(SettingsKey.liveCues) private var liveCues = true
    @AppStorage(SettingsKey.speakReps) private var speakReps = false
    @AppStorage(SettingsKey.dimWhileRecording) private var dimWhileRecording = true
    @AppStorage(SettingsKey.autoStop) private var autoStop = true
    @AppStorage(SettingsKey.autoStopSeconds) private var autoStopSeconds = 3.0

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .lb }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Units", selection: $unitRaw) {
                        Text("Kilograms").tag(WeightUnit.kg.rawValue)
                        Text("Pounds").tag(WeightUnit.lb.rawValue)
                    }
                    .pickerStyle(.segmented)
                    BodyMassField(bodyMassKg: $bodyMassKg, unit: unit)
                } header: { Text("You") }

                Section {
                    Stepper(value: $lossCutoff, in: 0...50, step: 5) {
                        HStack { Text("Default velocity-loss cutoff"); Spacer(); Text(lossCutoff > 0 ? Fmt.percent(lossCutoff) : "Off").foregroundStyle(Theme.muted) }
                    }
                } header: { Text("Training") }

                Section {
                    Toggle("Save set videos to Photos", isOn: $keepVideos)
                    Toggle("Sound cues during the set", isOn: $liveCues)
                    if liveCues { Toggle("Say each rep's velocity", isOn: $speakReps) }
                    Toggle("Dim the screen while recording", isOn: $dimWhileRecording)
                    Toggle("Stop recording when the bar is still", isOn: $autoStop)
                    if autoStop {
                        Stepper(value: $autoStopSeconds, in: 2...15, step: 1) {
                            HStack { Text("Still for"); Spacer(); Text("\(Int(autoStopSeconds)) s").monospacedDigit().foregroundStyle(Theme.muted) }
                        }
                    }
                } header: { Text("Recording") } footer: {
                    Text("Videos: off deletes each recorded set once it's analyzed, so videos don't fill your phone; on also saves the 240 fps video to Photos. Sound cues: a tone on each rep, a double tone for a likely bounce, and a falling three-tone stop when velocity loss reaches the cutoff or the rep cap is reached. The live count is for cueing; the results after the set are the record. Dimming saves battery and heat; tap the screen to see it for a few seconds. Auto-stop ends the recording once at least one rep is counted and the bar then stays within 3 cm for the set time; any movement restarts the wait, so extra reps are still recorded. Raise the time for sets with long pauses between reps.")
                }

                Section {
                    HStack {
                        Text("Plate diameter")
                        Spacer()
                        NumberField(value: $plateCm, fractionDigits: 1, placeholder: "45")
                            .multilineTextAlignment(.trailing)
                            .fixedSize()
                        Text("cm").foregroundStyle(Theme.muted)
                    }
                    Stepper(value: $cutoffHz, in: 2...20, step: 0.5) {
                        HStack { Text("Smoothing filter"); Spacer(); Text(String(format: "%.1f Hz", cutoffHz)).foregroundStyle(Theme.muted) }
                    }
                    Toggle("Correct for camera tilt", isOn: $tilt)
                    Toggle("Analyze every frame (240 fps)", isOn: $everyFrame)
                    Button("Restore defaults") { plateCm = 45; cutoffHz = 8; tilt = true }
                } header: { Text("Measurement") } footer: {
                    Text("Bumper and competition plates are 45 cm across. The 8 Hz filter is the setting validated against GymAware; it stays adjustable while peak velocity is being checked. Sets are analyzed at 120 frames a second, about twice as fast as every frame; turn on every frame for validation work. Changes apply to sets analyzed after the change.")
                }

                BackupSection()

                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                            .foregroundStyle(Theme.muted).monospacedDigit()
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .keyboardDoneButton()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDone { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
        }
    }
}
