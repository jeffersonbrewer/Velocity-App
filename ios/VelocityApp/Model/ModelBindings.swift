import SwiftUI
import VelocityCore

extension AppModel {
    /// The exercise currently selected for the next set.
    var exerciseBinding: Binding<String> {
        Binding(get: { self.currentExerciseID }, set: { self.currentExerciseID = $0 })
    }

    /// An exercise's remembered load in kg.
    func loadBinding(_ id: String) -> Binding<Double> {
        Binding(get: { self.prefs(for: id).loadKg },
                set: { var p = self.prefs(for: id); p.loadKg = max(0, $0); self.prefs[id] = p })
    }

    /// An exercise's remembered settings.
    func prefsBinding(_ id: String) -> Binding<ExercisePrefs> {
        Binding(get: { self.prefs(for: id) }, set: { self.prefs[id] = $0 })
    }
}
