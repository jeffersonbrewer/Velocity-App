import Foundation

/// An exercise the app knows how to measure, with the defaults the prototype agreed on.
public struct Exercise: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Starts with the lifting phase (deadlifts, cleans, rows) rather than the lowering phase.
    public var concentricFirst: Bool
    /// Share of body mass counted as moving with the bar for system power.
    public var bodyMassFraction: Double
    /// Group-average mean velocity at 1RM (minimum velocity threshold), m/s. Nil: no 1RM estimate.
    public var defaultMvt: Double?
    public var mvtSource: String?
    public var mvtChecked: Bool

    /// Olympic lifts have no dependable 1RM velocity, so no 1RM is estimated for them.
    public var allowsOneRm: Bool { !ExerciseCatalog.noOneRm.contains(id) }
    public var isOlympic: Bool { ExerciseCatalog.olympic.contains(id) }

    public init(id: String, name: String, concentricFirst: Bool, bodyMassFraction: Double,
                defaultMvt: Double? = nil, mvtSource: String? = nil, mvtChecked: Bool = false) {
        self.id = id; self.name = name; self.concentricFirst = concentricFirst
        self.bodyMassFraction = bodyMassFraction; self.defaultMvt = defaultMvt
        self.mvtSource = mvtSource; self.mvtChecked = mvtChecked
    }
}

public enum ExerciseCatalog {
    // Squat and deadlift fractions weight each body segment by its travel relative to the bar:
    // head, arms and trunk move about as far as the bar, thighs about half, shanks and feet barely.
    public static let all: [Exercise] = [
        Exercise(id: "trap_bar_deadlift", name: "Trap bar deadlift", concentricFirst: true, bodyMassFraction: 0.80,
                 defaultMvt: 0.15, mvtSource: "GymAware's 1RM velocity for the trap bar deadlift; no study checked"),
        Exercise(id: "back_squat", name: "Back squat", concentricFirst: false, bodyMassFraction: 0.80,
                 defaultMvt: 0.30, mvtSource: "Conceicao et al. 2016 (0.30 ± 0.04 m/s); trained women 0.36 m/s (Caven et al. 2020)",
                 mvtChecked: true),
        Exercise(id: "front_squat", name: "Front squat", concentricFirst: false, bodyMassFraction: 0.80,
                 defaultMvt: 0.33, mvtSource: "Less established; no study checked"),
        Exercise(id: "box_squat", name: "Box squat", concentricFirst: false, bodyMassFraction: 0.80),
        Exercise(id: "deadlift", name: "Deadlift", concentricFirst: true, bodyMassFraction: 0.80,
                 defaultMvt: 0.15, mvtSource: "Not checked against a study"),
        Exercise(id: "sumo_deadlift", name: "Sumo deadlift", concentricFirst: true, bodyMassFraction: 0.80,
                 defaultMvt: 0.15, mvtSource: "Not checked against a study"),
        Exercise(id: "bench_press", name: "Bench press", concentricFirst: false, bodyMassFraction: 0,
                 defaultMvt: 0.17, mvtSource: "Garcia-Ramos et al. 2020 (0.17 m/s); powerlifters as low as 0.10 m/s (Helms et al. 2017)",
                 mvtChecked: true),
        Exercise(id: "overhead_press", name: "Overhead press", concentricFirst: false, bodyMassFraction: 0,
                 defaultMvt: 0.24, mvtSource: "Fahs et al. 2019 via Soriano et al. 2022; original not checked"),
        Exercise(id: "hip_thrust", name: "Hip thrust", concentricFirst: false, bodyMassFraction: 0,
                 defaultMvt: 0.25, mvtSource: "Less established; no study checked"),
        Exercise(id: "prone_bench_pull", name: "Prone bench pull", concentricFirst: true, bodyMassFraction: 0,
                 defaultMvt: 0.48, mvtSource: "Garcia-Ramos et al. 2019 (0.479 ± 0.032 m/s)", mvtChecked: true),
        Exercise(id: "pendlay_row", name: "Pendlay row", concentricFirst: true, bodyMassFraction: 0),
        Exercise(id: "power_clean", name: "Power clean", concentricFirst: true, bodyMassFraction: 0),
        Exercise(id: "hang_clean", name: "Hang clean", concentricFirst: true, bodyMassFraction: 0),
        Exercise(id: "hang_power_clean", name: "Hang power clean", concentricFirst: true, bodyMassFraction: 0),
        Exercise(id: "push_jerk", name: "Push jerk", concentricFirst: false, bodyMassFraction: 0),
        Exercise(id: "split_jerk", name: "Split jerk", concentricFirst: false, bodyMassFraction: 0),
        Exercise(id: "pull_up", name: "Pull-up (weighted)", concentricFirst: false, bodyMassFraction: 1.0,
                 defaultMvt: 0.20, mvtSource: "Sanchez-Moreno et al. 2017 (0.20 ± 0.05 m/s)", mvtChecked: true),
        Exercise(id: "dip", name: "Dip (weighted)", concentricFirst: false, bodyMassFraction: 1.0),
    ]

    static let noOneRm: Set<String> = olympic
    /// Olympic lifts and their variations: loaded from a typed 1RM, with their own power range and low reps.
    public static let olympic: Set<String> = ["power_clean", "hang_clean", "hang_power_clean", "push_jerk", "split_jerk"]

    public static func exercise(id: String) -> Exercise? { all.first { $0.id == id } }
}
