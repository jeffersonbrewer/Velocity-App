import Foundation

/// A stretch of samples, start and end inclusive.
public struct Phase: Codable, Hashable, Sendable {
    public var start: Int
    public var end: Int
    public init(start: Int, end: Int) { self.start = start; self.end = end }
}

public struct Rep: Codable, Hashable, Sendable {
    public var number: Int
    public var concentric: Phase
    public var eccentric: Phase?
    public init(number: Int, concentric: Phase, eccentric: Phase?) {
        self.number = number; self.concentric = concentric; self.eccentric = eccentric
    }
}

/// Split a set into reps, each with an eccentric (down) and concentric (up) phase.
/// Mirrors reps.segment in the prototype.
public enum RepSegmenter {
    /// A phase is a stretch where the bar moves the same way faster than vThresh, extended out to
    /// where velocity crosses zero, covering at least minRom meters. Brief slowdowns inside a phase
    /// (a sticking point) shorter than mergeGapS do not split it.
    public static func segment(_ kin: Kinematics, concentricFirst: Bool, vThresh: Double = 0.05,
                               minRom: Double = 0.10, mergeGapS: Double = 0.25) -> [Rep] {
        var up = phases(kin, sign: 1, vThresh: vThresh, minRom: minRom, mergeGapS: mergeGapS)
        // Drop lifts far shorter than the set's typical range of motion: a bump of the bar
        // while setting up or a tracking glitch, not a rep.
        if up.count >= 3 {
            let typical = Stats.median(up.map { kin.y[$0.end] - kin.y[$0.start] })
            up = up.filter { kin.y[$0.end] - kin.y[$0.start] >= 0.5 * typical }
        }
        let down = phases(kin, sign: -1, vThresh: vThresh, minRom: minRom, mergeGapS: mergeGapS)

        let maxLink = Stats.pyRound(1.0 * kin.fps)  // phases more than 1 s apart are not one rep
        var reps: [Rep] = []
        var used = Set<Int>()
        for (i, con) in up.enumerated() {
            var ecc: Phase? = nil
            if concentricFirst {
                let options = down.indices.filter { !used.contains($0) && (0...maxLink).contains(down[$0].start - con.end) }
                if let k = options.min(by: { down[$0].start < down[$1].start }) { ecc = down[k]; used.insert(k) }
            } else {
                let options = down.indices.filter { !used.contains($0) && (0...maxLink).contains(con.start - down[$0].end) }
                // Python's max() keeps the first of equal keys.
                if let k = options.reduce(nil as Int?, { best, k in
                    guard let b = best else { return k }
                    return down[k].end > down[b].end ? k : b
                }) { ecc = down[k]; used.insert(k) }
            }
            reps.append(Rep(number: i + 1, concentric: con, eccentric: ecc))
        }
        return reps
    }

    static func phases(_ kin: Kinematics, sign: Double, vThresh: Double, minRom: Double, mergeGapS: Double) -> [Phase] {
        let v = kin.v.map { $0 * sign }
        let runs = runsOf(v.map { $0 > vThresh })

        // Merge runs separated by a short gap in which the bar never reversed direction.
        let mergeGap = Stats.pyRound(mergeGapS * kin.fps)
        var merged: [(Int, Int)] = []
        for (s, e) in runs {
            if let (_, pe) = merged.last {
                let gapOK = (pe + 1..<s).allSatisfy { v[$0] > -vThresh }
                if s - pe - 1 <= mergeGap && gapOK {
                    merged[merged.count - 1].1 = e
                    continue
                }
            }
            merged.append((s, e))
        }

        var out: [Phase] = []
        let n = v.count
        for (s0, e0) in merged {
            var s = s0, e = e0
            // Extend to the zero crossings so the phase covers the whole movement.
            while s > 0 && v[s - 1] > 0 { s -= 1 }
            while e < n - 1 && v[e + 1] > 0 { e += 1 }
            if sign * (kin.y[e] - kin.y[s]) >= minRom { out.append(Phase(start: s, end: e)) }
        }
        return out
    }

    static func runsOf(_ mask: [Bool]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var start: Int? = nil
        for (i, m) in mask.enumerated() {
            if m && start == nil { start = i }
            if !m, let s = start { out.append((s, i - 1)); start = nil }
        }
        if let s = start { out.append((s, mask.count - 1)) }
        return out
    }
}
