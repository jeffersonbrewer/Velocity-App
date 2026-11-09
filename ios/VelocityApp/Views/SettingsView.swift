import SwiftUI
import VelocityCore

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.unit) private var unitRaw = WeightUnit.lb.rawValue
    @AppStorage(SettingsKey.bodyMassKg) private var bodyMassKg = 0.0
    @AppStorage(SettingsKey.velocityLossCutoff) private var lossCutoff = 20.0
    @AppStorage(SettingsKey.cutoffHz) private var cutoffHz = 8.0
    @AppStorage(SettingsKey.plateDiameterCm) private var plateCm = 45.0
    @AppStorage(SettingsKey.tiltCorrection) private var tilt = true

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
                        HStack { Text("Velocity-loss cutoff"); Spacer(); Text(lossCutoff > 0 ? Fmt.percent(lossCutoff) : "Off").foregroundStyle(Theme.muted) }
                    }
                } header: { Text("Training") }

                Section {
                    HStack {
                        Text("Plate diameter")
                        Spacer()
                        TextField("45", value: $plateCm, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .fixedSize()
                        Text("cm").foregroundStyle(Theme.muted)
                    }
                    Stepper(value: $cutoffHz, in: 2...20, step: 0.5) {
                        HStack { Text("Smoothing filter"); Spacer(); Text(String(format: "%.1f Hz", cutoffHz)).foregroundStyle(Theme.muted) }
                    }
                    Toggle("Correct for camera tilt", isOn: $tilt)
                    Button("Restore defaults") { plateCm = 45; cutoffHz = 8; tilt = true }
                } header: { Text("Measurement") } footer: {
                    Text("Bumper and competition plates are 45 cm across. The 8 Hz filter is the setting validated against GymAware; it stays adjustable while peak velocity is being checked. Changes apply to sets analyzed after the change.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
