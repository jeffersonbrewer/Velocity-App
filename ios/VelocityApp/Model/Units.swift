import Foundation

/// Loads are stored in kilograms and shown in the lifter's chosen unit.
enum WeightUnit: String, CaseIterable, Identifiable {
    case kg, lb
    var id: String { rawValue }

    static let kgPerLb = 0.45359237

    /// Stepper increment: 2.5 kg or 5 lb.
    var step: Double { self == .kg ? 2.5 : 5 }

    func fromKg(_ kg: Double) -> Double { self == .kg ? kg : kg / WeightUnit.kgPerLb }
    func toKg(_ value: Double) -> Double { self == .kg ? value : value * WeightUnit.kgPerLb }

    /// A load rounded to the nearest plate step (2.5 kg or 5 lb), in kg.
    func roundedToStep(kg: Double) -> Double { toKg((fromKg(kg) / step).rounded() * step) }

    /// A load in this unit, always with every needed decimal (102.5, not 102 or 103).
    func format(kg: Double) -> String { Fmt.load(fromKg(kg)) }
}

enum Fmt {
    /// Up to two decimals, trailing zeros removed.
    static func load(_ v: Double) -> String {
        let rounded = (v * 100).rounded() / 100
        var s = String(format: "%.2f", rounded)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func velocity(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "–" }
    static func watts(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "–" }
    static func meters(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "–" }
    static func percent(_ v: Double?) -> String { v.map { String(format: "%.0f%%", $0) } ?? "–" }
}
