import Foundation

/// Standard bumper and competition plates (10 to 25 kg) are 450 mm across.
public let standardPlateDiameterM = 0.45

/// The plate's center, frame by frame, in image pixels (y points down). NaN where it was lost.
public struct Track: Codable, Sendable {
    public var fps: Double
    public var t: [Double]
    public var x: [Double]
    public var y: [Double]
    public var r: [Double]
    /// Median minor/major axis ratio of the plate's outline. 1.0 means the camera is square to it.
    public var roundness: Double
    public var frameWidth: Int
    public var frameHeight: Int

    public init(fps: Double, t: [Double], x: [Double], y: [Double], r: [Double],
                roundness: Double, frameWidth: Int, frameHeight: Int) {
        self.fps = fps; self.t = t; self.x = x; self.y = y; self.r = r
        self.roundness = roundness; self.frameWidth = frameWidth; self.frameHeight = frameHeight
    }

    public var radiusPx: Double { Stats.nanMedian(r) }
    public var lostFraction: Double {
        x.isEmpty ? 1 : Double(x.filter { $0.isNaN }.count) / Double(x.count)
    }
}

/// Filtered bar position, velocity and acceleration in SI units on an even time grid.
public struct Kinematics: Sendable {
    public var t: [Double]   // s
    public var x: [Double]   // m, horizontal (positive = right in the image)
    public var y: [Double]   // m, vertical (positive = up)
    public var v: [Double]   // m/s, vertical velocity
    public var a: [Double]   // m/s², vertical acceleration
    public var fps: Double
    public var metersPerPixel: Double
}

public enum KinematicsError: Error, LocalizedError {
    case plateNeverFound
    case trackingLostMidClip

    public var errorDescription: String? {
        switch self {
        case .plateNeverFound: return "The plate was not found in the video."
        case .trackingLostMidClip:
            return "The plate was lost for too long in the middle of the clip. Make sure nothing blocks the plate."
        }
    }
}

public enum KinematicsBuilder {
    /// Scale the track to meters using the plate's known diameter, then filter and differentiate.
    /// Mirrors kinematics.from_track in the prototype.
    public static func fromTrack(_ input: Track, plateDiameterM: Double = standardPlateDiameterM,
                                 cutoffHz: Double = 8.0, maxGapS: Double = 0.1,
                                 positionScale: Bool = true) throws -> Kinematics {
        let track = resampleUniform(input)
        var mPerPx = plateDiameterM / (2 * track.radiusPx)
        let maxGap = max(1, Stats.pyRound(maxGapS * track.fps))
        let xpAll = fillGaps(track.x, maxGap: maxGap)
        let ypAll = fillGaps(track.y, maxGap: maxGap)

        guard let first = ypAll.firstIndex(where: { !$0.isNaN }),
              let lastGood = ypAll.lastIndex(where: { !$0.isNaN }) else {
            throw KinematicsError.plateNeverFound
        }
        let last = lastGood + 1
        if ypAll[first..<last].contains(where: { $0.isNaN }) { throw KinematicsError.trackingLostMidClip }
        let t = Array(track.t[first..<last])
        let yp = Array(ypAll[first..<last]), xp = Array(xpAll[first..<last])

        var x = [Double](repeating: 0, count: yp.count)
        var y = [Double](repeating: 0, count: yp.count)
        if positionScale, let fit = radiusVsHeight(y: track.y, r: track.r) {
            // The plate's apparent size changes with height when the camera is tilted, so the
            // meters-per-pixel scale does too. With radius r(y) = a + b*y, vertical distance is the
            // integral of D / (2 r(y)) dy = D / (2b) * ln(r(y)).
            let (a, b) = fit
            let s = yp.map { plateDiameterM / (2 * b) * log(a + b * $0) }
            for i in 0..<yp.count {
                y[i] = -(s[i] - s[0])
                x[i] = (xp[i] - xp[0]) * plateDiameterM / (2 * (a + b * yp[i]))
            }
            mPerPx = plateDiameterM / (2 * (a + b * yp[0]))
        } else {
            for i in 0..<yp.count {
                y[i] = -(yp[i] - yp[0]) * mPerPx  // image y points down; flip so up is positive
                x[i] = (xp[i] - xp[0]) * mPerPx
            }
        }
        return fromPosition(t: t, x: x, y: y, fps: track.fps, cutoffHz: cutoffHz, metersPerPixel: mPerPx)
    }

    /// Filter a position signal (meters) and differentiate it. cutoffHz nil or 0 skips filtering.
    public static func fromPosition(t: [Double], x: [Double], y: [Double], fps: Double,
                                    cutoffHz: Double?, metersPerPixel: Double = .nan) -> Kinematics {
        var xf = x, yf = y
        if let c = cutoffHz, c > 0 {
            yf = Butterworth.lowpassFilter(y, fps: fps, cutoffHz: c)
            xf = Butterworth.lowpassFilter(x, fps: fps, cutoffHz: c)
        }
        let dt = 1.0 / fps
        let v = Stats.gradient(yf, dt: dt)
        let a = Stats.gradient(v, dt: dt)
        return Kinematics(t: t, x: xf, y: yf, v: v, a: a, fps: fps, metersPerPixel: metersPerPixel)
    }

    /// Linearly interpolate NaN runs no longer than maxGap samples. Leading and trailing runs stay NaN.
    static func fillGaps(_ sig: [Double], maxGap: Int) -> [Double] {
        var out = sig
        let isNan = sig.map { $0.isNaN }
        guard isNan.contains(true) else { return out }
        let idx = (0..<sig.count).map(Double.init)
        let goodIdx = idx.indices.filter { !isNan[$0] }
        guard goodIdx.count >= 2 else { return out }
        let interp = Stats.interp(idx, goodIdx.map { idx[$0] }, goodIdx.map { sig[$0] })
        var runStart: Int? = nil
        for i in 0...sig.count {
            let bad = i < sig.count ? isNan[i] : false
            if bad && runStart == nil {
                runStart = i
            } else if !bad, let s = runStart {
                if i - s <= maxGap && s > 0 && i < sig.count {
                    for j in s..<i { out[j] = interp[j] }
                }
                runStart = nil
            }
        }
        return out
    }

    /// Put a variable-frame-rate track onto an even time grid, needed for filtering.
    /// The grid rate is the clip's fastest common frame rate (240 Hz for iPhone slo-mo).
    static func resampleUniform(_ track: Track) -> Track {
        let n = track.t.count
        guard n >= 2 else { return track }
        let dt = (1..<n).map { track.t[$0] - track.t[$0 - 1] }
        let ptp = (dt.max() ?? 0) - (dt.min() ?? 0)
        if ptp < 0.05 * Stats.median(dt) { return track }
        let rate = (1.0 / Stats.percentile(dt, 5)).rounded(.toNearestOrEven)
        let step = 1.0 / rate
        let stop = track.t[n - 1] + 1e-9
        let count = Int((stop / step).rounded(.up))
        let t = (0..<count).map { Double($0) * step }
        let lost = track.x.map { $0.isNaN }
        var gap = [Bool](repeating: false, count: count)
        for (i, ti) in t.enumerated() {
            let nearest = min(max(Stats.searchSortedLeft(track.t, ti), 0), n - 1)
            let prev = max(nearest - 1, 0)
            gap[i] = lost[nearest] || lost[prev]
        }
        func interp(_ sig: [Double]) -> [Double] {
            let good = sig.indices.filter { !sig[$0].isNaN }
            guard good.count >= 2 else { return [Double](repeating: .nan, count: count) }
            var out = Stats.interp(t, good.map { track.t[$0] }, good.map { sig[$0] })
            for i in 0..<count where gap[i] { out[i] = .nan }
            return out
        }
        return Track(fps: rate, t: t, x: interp(track.x), y: interp(track.y), r: interp(track.r),
                     roundness: track.roundness, frameWidth: track.frameWidth, frameHeight: track.frameHeight)
    }

    /// Robust straight-line fit of plate radius against image height, r = a + b*y.
    /// Returns nil when the plate barely moves vertically or its size does not change with height
    /// by at least minChange over the travel, in which case a single scale is used.
    static func radiusVsHeight(y yPx: [Double], r rPx: [Double], minSpanPx: Double = 100,
                               minChange: Double = 0.01) -> (Double, Double)? {
        var y: [Double] = [], r: [Double] = []
        for i in 0..<yPx.count where !yPx[i].isNaN && !rPx[i].isNaN {
            y.append(yPx[i]); r.append(rPx[i])
        }
        guard y.count >= 50, let ymax = y.max(), let ymin = y.min(), ymax - ymin >= minSpanPx else { return nil }
        var keep = [Bool](repeating: true, count: y.count)
        var a = 0.0, b = 0.0
        for _ in 0..<4 {
            let ky = y.indices.filter { keep[$0] }
            (a, b) = Stats.lineFit(ky.map { y[$0] }, ky.map { r[$0] })
            let resid = y.indices.map { r[$0] - (a + b * y[$0]) }
            let mad = Stats.median(ky.map { abs(resid[$0]) }) * 1.4826 + 1e-6
            let new = resid.map { abs($0) < 3 * mad }
            if new == keep { break }
            keep = new
        }
        let keptY = y.indices.filter { keep[$0] }.map { y[$0] }
        let keptR = y.indices.filter { keep[$0] }.map { r[$0] }
        let lo = Stats.percentile(keptY, 2), hi = Stats.percentile(keptY, 98)
        if abs(b) * (hi - lo) < minChange * Stats.median(keptR) { return nil }
        return (a, b)
    }
}
