import Foundation

/// Counts reps while the set is being recorded, so the lifter can be cued in the moment.
///
/// It takes the plate's position frame by frame as tracking produces it, at whatever irregular
/// rate the phone keeps up with, and:
/// 1. resamples to an even 100 Hz grid and smooths with a one-way (causal) 2nd-order
///    Butterworth low-pass, since the two-way filter used after the set needs the future;
/// 2. finds lifting phases the same way as the after-set segmenter: velocity above 0.05 m/s,
///    extended back to where it crossed zero, ended once it has stayed at or below zero for
///    0.25 s (so a sticking point doesn't end the rep), and at least 10 cm of travel;
/// 3. screens like the after-set analysis: a lift under 70% of the typical distance so far is a
///    partial and doesn't count; a rep over 25% faster than the typical rep so far is counted but
///    marked as a likely bounce and never becomes the loss reference;
/// 4. reports velocity loss against the fastest unmarked rep so far, and says when to stop:
///    loss at or past the cutoff, or the rep cap reached;
/// 5. optionally says when the set is over: once at least one rep is counted, the bar has stayed
///    within 3 cm for `settleSeconds`. Any movement restarts that wait, so reps after the stop cue
///    are never cut off.
///
/// The after-set analysis stays the record; these numbers are for cueing only.
public final class LiveRepCounter {
    public struct RepEvent: Sendable, Equatable {
        public var number: Int
        public var meanVelocity: Double
        public var distance: Double
        public var lossPct: Double          // vs the fastest unmarked rep so far
        public var likelyBounce: Bool
        public var stop: StopReason?
    }

    public enum StopReason: Sendable, Equatable {
        case lossCutoff(Double)
        case repCap(Int)
    }

    public let plateDiameterM: Double
    public let lossCutoffPct: Double?
    public let repCap: Int?

    public private(set) var reps: [RepEvent] = []
    public private(set) var stopped = false
    /// True once the bar has stayed still for `settleSeconds` after a counted rep.
    public private(set) var settled = false
    public let settleSeconds: Double?

    // Scale, from the plate radius over the first frames.
    private var radii: [Double] = []
    private var metersPerPixel: Double?

    // Resampling and filtering.
    private let dt = 0.01
    private var lastT: Double?, lastY: Double?
    private var nextGridT: Double?
    private var filter: Biquad
    private var primed = false
    private var prevYf: Double?

    // Phase tracking, on the 100 Hz grid.
    private var ys: [Double] = []           // filtered position, m (up positive)
    private var vs: [Double] = []           // velocity, m/s
    private var lastZeroUp = 0              // index where velocity last went from <= 0 to > 0
    private var upStart: Int?
    private var tentativeEnd: Int?
    private let vThresh = 0.05, minRom = 0.10, mergeGap = 0.25
    private var distances: [Double] = []    // counted reps
    private var unmarked: [Double] = []     // mean velocities of counted reps not marked as bounces
    private var stillY: Double?, stillSince = 0.0   // where and since when (grid time) the bar has stayed
    private let stillBand = 0.03

    public init(plateDiameterM: Double = 0.45, cutoffHz: Double = 8, lossCutoffPct: Double?, repCap: Int?,
                settleSeconds: Double? = nil) {
        self.plateDiameterM = plateDiameterM
        self.settleSeconds = settleSeconds
        self.lossCutoffPct = lossCutoffPct
        self.repCap = repCap
        filter = Biquad(lowpassCutoff: cutoffHz, sampleRate: 100)
    }

    /// Add one tracked frame: time in seconds, plate centre y and radius in image pixels
    /// (y grows downward, as in the image). Returns any reps completed by this frame.
    public func add(time t: Double, yPixels: Double, radiusPx: Double) -> [RepEvent] {
        guard yPixels.isFinite, radiusPx.isFinite, radiusPx > 0 else { return [] }
        if metersPerPixel == nil {
            radii.append(radiusPx)
            guard radii.count >= 15 else { return [] }
            metersPerPixel = plateDiameterM / (2 * Stats.median(radii))
        }
        let y = -yPixels * metersPerPixel!
        defer { lastT = t; lastY = y }
        guard let t0 = lastT, let y0 = lastY, t > t0 else {
            nextGridT = t
            return []
        }
        if t - t0 > 0.25 {            // tracking gap: start the grid again rather than draw a line through it
            nextGridT = t
            return []
        }
        var out: [RepEvent] = []
        while let g = nextGridT, g <= t {
            let yi = g <= t0 ? y0 : y0 + (y - y0) * (g - t0) / (t - t0)
            if let e = step(yi, at: g) { out.append(e) }
            nextGridT = g + dt
        }
        return out
    }

    private func step(_ y: Double, at g: Double) -> RepEvent? {
        if !primed { filter.prime(y); primed = true }
        let yf = filter.process(y)
        let v = prevYf.map { (yf - $0) / dt } ?? 0
        prevYf = yf
        ys.append(yf); vs.append(v)
        let i = vs.count - 1
        if i > 0 && vs[i - 1] <= 0 && v > 0 { lastZeroUp = i }
        if stillY == nil || abs(yf - stillY!) > stillBand || upStart != nil { stillY = yf; stillSince = g }
        if let s = settleSeconds, !settled, !reps.isEmpty, upStart == nil, g - stillSince >= s { settled = true }

        if let s = upStart {
            if v > vThresh {
                tentativeEnd = nil                     // still lifting (or lifting again after a sticking point)
            } else if v <= 0 {
                if tentativeEnd == nil { tentativeEnd = i }
                if Double(i - tentativeEnd!) * dt >= mergeGap {
                    let e = tentativeEnd!
                    upStart = nil; tentativeEnd = nil
                    return finish(start: s, end: e)
                }
            }
        } else if v > vThresh {
            upStart = lastZeroUp
        }
        return nil
    }

    private func finish(start s: Int, end e: Int) -> RepEvent? {
        guard e > s else { return nil }
        let dist = ys[e] - ys[s]
        guard dist >= minRom else { return nil }
        if !distances.isEmpty && dist < 0.70 * Stats.median(distances) { return nil }   // partial
        let mv = vs[s...e].reduce(0, +) / Double(e - s + 1)
        let bounce = unmarked.count >= 2 && mv > 1.25 * Stats.median(unmarked)
        distances.append(dist)
        if !bounce { unmarked.append(mv) }
        let ref = unmarked.max() ?? mv
        let loss = max(0, (ref - mv) / ref * 100)
        var ev = RepEvent(number: reps.count + 1, meanVelocity: mv, distance: dist, lossPct: loss, likelyBounce: bounce, stop: nil)
        if !stopped {
            if let c = lossCutoffPct, c > 0, loss >= c { ev.stop = .lossCutoff(c) }
            else if let cap = repCap, ev.number >= cap { ev.stop = .repCap(cap) }
            if ev.stop != nil { stopped = true }
        }
        reps.append(ev)
        return ev
    }
}

/// A 2nd-order Butterworth low-pass in transposed direct form II.
struct Biquad {
    private var b0, b1, b2, a1, a2: Double
    private var z1 = 0.0, z2 = 0.0

    init(lowpassCutoff fc: Double, sampleRate fs: Double) {
        let k = tan(Double.pi * min(fc, 0.45 * fs) / fs)
        let norm = 1 / (1 + 2.0.squareRoot() * k + k * k)
        b0 = k * k * norm; b1 = 2 * b0; b2 = b0
        a1 = 2 * (k * k - 1) * norm
        a2 = (1 - 2.0.squareRoot() * k + k * k) * norm
    }

    /// Start at rest at x, so the first samples don't ring.
    mutating func prime(_ x: Double) {
        for _ in 0..<400 { _ = process(x) }
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}
