import Foundation

/// Follows the plate's center through a video, one frame at a time. Mirrors tracking.track_video
/// in the prototype: find the plate once, then each frame take a coarse position from template
/// matching and a sub-pixel center from the plate's outline.
public final class PlateTracker {
    public private(set) var times: [Double] = []
    public private(set) var xs: [Double] = []
    public private(set) var ys: [Double] = []
    public private(set) var rs: [Double] = []
    private var rounds: [Double] = []
    private var prev: Circle?
    private var template: PlateTemplate?
    private var misses = 0
    private var lastGood: (c: Circle, t: Double)?
    private var beforeLastGood: (c: Circle, t: Double)?
    /// Plate radius from the first detection; the plate never changes size.
    private var refR: Double?
    private var frameWidth = 0, frameHeight = 0
    let minScore: Double

    /// Always search the prototype's full template box (slower; for checking against the prototype).
    public var alwaysTemplate = false

    public init(minScore: Double = 0.5) { self.minScore = minScore }

    /// The latest plate position, for drawing an overlay.
    public var current: Circle? { prev }

    /// Process one frame. time is the frame's presentation time in seconds.
    @discardableResult
    public func add(_ gray: GrayImage, time: Double) -> Circle? {
        frameWidth = gray.width; frameHeight = gray.height
        times.append(time)
        var circle: Circle? = nil
        if let p = prev {
            circle = step(gray, prev: p, time: time)
        } else {
            circle = PlateDetector.detect(gray)
            if let c = circle, let ref = refR, abs(c.r - ref) > 0.12 * ref {
                circle = nil  // re-detection found something else (the hub ring, a stray circle)
            }
            if let c = circle, refR == nil {
                refR = c.r
                template = PlateTemplate(image: gray, cx: c.x, cy: c.y, r: c.r)
            }
        }
        if let c = circle {
            xs.append(c.x); ys.append(c.y); rs.append(c.r)
            rounds.append(c.roundness)
            misses = 0
            prev = c
            beforeLastGood = lastGood
            lastGood = (c, time)
        } else {
            xs.append(.nan); ys.append(.nan); rs.append(.nan)
            // After losing the plate for a few frames, search the whole frame again: the last
            // accepted circle may be slightly off, and searching around it can fail forever.
            misses += 1
            if template == nil || misses >= 3 { prev = nil }
            lastGood = nil; beforeLastGood = nil
        }
        return circle
    }

    private func step(_ gray: GrayImage, prev: Circle, time: Double) -> Circle? {
        let r0 = refR ?? prev.r
        func accept(_ c: Circle?, guessX: Double, guessY: Double) -> Circle? {
            // Reject fits that jump implausibly or change size, which signal a wrong edge. Check against
            // the first detection so the fit cannot creep inward to the hub ring a few percent at a time
            // while a leg passes in front. 12% leaves room for a tilted camera.
            guard let c, abs(c.r - r0) <= 0.12 * r0, hypot(c.x - guessX, c.y - guessY) <= 0.3 * prev.r else { return nil }
            return c
        }
        // Coarse position from template matching, then a sub-pixel center from the plate's outline,
        // as in the prototype. The outline fit needs this accurate guess: under motion blur it is
        // pulled toward wherever it starts, so a guess predicted from earlier frames is not enough.
        // To save time, first search a small box around the predicted position, and fall back to
        // the prototype's full search box if the best match lands on the small box's edge.
        var px = prev.x, py = prev.y
        if let a = lastGood, let b = beforeLastGood, a.t > b.t, time - a.t < 0.05 {
            let k = (time - a.t) / (a.t - b.t)
            px = a.c.x + (a.c.x - b.c.x) * k
            py = a.c.y + (a.c.y - b.c.y) * k
        }
        var gx = prev.x, gy = prev.y
        if let tpl = template {
            let small = Int(prev.r * 0.2) + 8
            var m = alwaysTemplate ? nil : tpl.match(gray, px: px, py: py, search: small)
            if let mm = m, abs(mm.x - px) > Double(small) - 10 || abs(mm.y - py) > Double(small) - 10 || mm.score < minScore {
                m = nil
            }
            if m == nil { m = tpl.match(gray, px: prev.x, py: prev.y, search: Int(prev.r * 0.6) + 8) }
            if let m, m.score >= minScore { gx = m.x; gy = m.y }
        }
        return accept(CircleFit.refine(gray, x: gx, y: gy, r: prev.r), guessX: gx, guessY: gy)
    }

    /// The finished track. Frame times are made relative to the first frame.
    public func finish() -> Track {
        let t0 = times.first ?? 0
        var t = times.map { $0 - t0 }
        // Fall back to an even 240 fps grid if the timestamps are unusable.
        if t.count >= 2, zip(t.dropFirst(), t).contains(where: { $0 <= $1 }) {
            t = (0..<t.count).map { Double($0) / 240 }
        }
        let duration = t.last ?? 0
        let fps = duration > 0 ? Double(t.count - 1) / duration : 240
        return Track(fps: fps, t: t, x: xs, y: ys, r: rs,
                     roundness: rounds.isEmpty ? .nan : Stats.median(rounds),
                     frameWidth: frameWidth, frameHeight: frameHeight)
    }
}
