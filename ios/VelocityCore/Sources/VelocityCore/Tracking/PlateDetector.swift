import Foundation

/// Finds the weight plate in a whole frame with a gradient Hough circle search, the same idea as
/// cv2.HoughCircles(HOUGH_GRADIENT) in the prototype, then refines it on the full-size image.
public enum PlateDetector {
    public static var debug = false
    public static func debugDetect(_ img: GrayImage) -> Circle? { debug = true; defer { debug = false }; return detect(img) }

    /// Return the plate: the circle with the strongest center vote, upgraded to the largest
    /// well-covered concentric circle (the plate rim around the hub), or nil.
    static func detect(_ full: GrayImage, minFrac: Double = 0.05, maxFrac: Double = 0.45) -> Circle? {
        // Search at half size for speed; the refinement afterwards restores full precision.
        let img = full.downsampled2x().median5()
        let w = img.width, h = img.height
        let dim = Double(min(w, h))
        let minR = Int(dim * minFrac), maxR = Int(dim * maxFrac)
        guard maxR > minR, w > 4, h > 4 else { return nil }

        let edges = cannyEdges(img, low: 60, high: 120)
        guard edges.count >= 20 else { return nil }

        // Each edge pixel votes for centers along its gradient direction, both ways.
        let dp = 1.5
        let aw = Int(Double(w) / dp) + 2, ah = Int(Double(h) / dp) + 2
        var acc = [Int32](repeating: 0, count: aw * ah)
        acc.withUnsafeMutableBufferPointer { a in
            for e in edges {
                for sgn in [-1.0, 1.0] {
                    let dx = e.dx * sgn, dy = e.dy * sgn
                    var r = minR
                    while r <= maxR {
                        let cx = (e.x + dx * Double(r)) / dp, cy = (e.y + dy * Double(r)) / dp
                        let ix = Int(cx), iy = Int(cy)
                        if cx < 0 || cy < 0 || ix >= aw || iy >= ah { break }
                        a[iy * aw + ix] += 1
                        r += 1
                    }
                }
            }
        }

        // Local maxima above the vote threshold, strongest first.
        let threshold: Int32 = 50
        var centers: [(x: Int, y: Int, votes: Int32)] = []
        for y in 1..<(ah - 1) {
            for x in 1..<(aw - 1) {
                let v = acc[y * aw + x]
                if v > threshold && v > acc[y * aw + x - 1] && v >= acc[y * aw + x + 1]
                    && v > acc[(y - 1) * aw + x] && v >= acc[(y + 1) * aw + x] {
                    centers.append((x, y, v))
                }
            }
        }
        centers.sort { $0.votes > $1.votes }

        // Try the strongest centers in turn; take the first that has a well-covered circle.
        let minDist = dim / 4
        var tried: [(Double, Double)] = []
        for c in centers.prefix(20) {
            let cx = (Double(c.x) + 0.5) * dp, cy = (Double(c.y) + 0.5) * dp
            if tried.contains(where: { hypot($0.0 - cx, $0.1 - cy) < minDist }) { continue }
            tried.append((cx, cy))
            if debug { print("center", cx * 2, cy * 2, "votes", c.votes) }
            // Largest candidate radius whose outline fits well on the full-size image wins, so the
            // plate rim beats the hub ring and the bar sleeve.
            for r in candidateRadii(edges: edges, cx: cx, cy: cy, minR: Double(minR), maxR: Double(maxR)) {
                let gx = cx * 2 + 0.5, gy = cy * 2 + 0.5, gr = r * 2
                guard let c = CircleFit.refine(full, x: gx, y: gy, r: gr) else { continue }
                if debug { print("  r", gr, "->", c.x, c.y, c.r, "support", c.support) }
                if abs(c.r - gr) < 0.15 * gr, hypot(c.x - gx, c.y - gy) < 0.2 * gr,
                   c.support >= CircleFit.nRays / 2 {
                    return c
                }
            }
        }
        return nil
    }

    struct Edge { var x: Double; var y: Double; var dx: Double; var dy: Double }

    /// Radii around (cx, cy) with a peak of edge points, largest first.
    static func candidateRadii(edges: [Edge], cx: Double, cy: Double, minR: Double, maxR: Double) -> [Double] {
        let nBins = Int(maxR) + 2
        var hist = [Int](repeating: 0, count: nBins)
        for e in edges {
            let ddx = e.x - cx, ddy = e.y - cy
            let d = (ddx * ddx + ddy * ddy).squareRoot()
            guard d >= minR, d <= maxR else { continue }
            // Only count edges whose gradient points roughly toward or away from the center.
            guard abs(ddx * e.dx + ddy * e.dy) / max(d, 1e-9) > 0.8 else { continue }
            hist[Int(d.rounded())] += 1
        }
        // Smooth over +-3 bins: the center is only known to a few pixels and the plate may look oval.
        var smooth = [Int](repeating: 0, count: nBins)
        for i in 3..<(nBins - 3) { smooth[i] = (i - 3...i + 3).reduce(0) { $0 + hist[$1] } }
        var candidates: [Int] = []
        for i in 4..<max(4, nBins - 4) where smooth[i] > 0 && smooth[i] >= smooth[i - 1] && smooth[i] > smooth[i + 1] {
            // Need edge pixels along at least a third of the circumference.
            if Double(smooth[i]) >= 0.33 * 2 * Double.pi * Double(i) { candidates.append(i) }
        }
        if PlateDetector.debug { print("  radius candidates", candidates.map { ($0 * 2, smooth[$0]) }) }
        return candidates.sorted(by: >).map(Double.init)
    }

    /// Canny edge detector (Sobel 3x3, L1 magnitude, non-maximum suppression, hysteresis).
    static func cannyEdges(_ img: GrayImage, low: Double, high: Double) -> [Edge] {
        let w = img.width, h = img.height
        var gx = [Float](repeating: 0, count: w * h), gy = [Float](repeating: 0, count: w * h)
        var mag = [Float](repeating: 0, count: w * h)
        img.pixels.withUnsafeBufferPointer { p in
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let i = y * w + x
                    @inline(__always) func P(_ j: Int) -> Float { Float(p[j]) }
                    let sx = (P(i - w + 1) + 2 * P(i + 1) + P(i + w + 1)) - (P(i - w - 1) + 2 * P(i - 1) + P(i + w - 1))
                    let sy = (P(i + w - 1) + 2 * P(i + w) + P(i + w + 1)) - (P(i - w - 1) + 2 * P(i - w) + P(i - w + 1))
                    gx[i] = sx; gy[i] = sy
                    mag[i] = abs(sx) + abs(sy)
                }
            }
        }
        // Non-maximum suppression along the gradient direction (4 sectors).
        // state: 0 none, 1 weak, 2 strong
        var state = [UInt8](repeating: 0, count: w * h)
        let tan22 = Float(tan(22.5 * Double.pi / 180)), tan67 = Float(tan(67.5 * Double.pi / 180))
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let m = mag[i]
                if m <= Float(low) { continue }
                let ax = abs(gx[i]), ay = abs(gy[i])
                var n1 = 0, n2 = 0
                if ay <= ax * tan22 { n1 = i - 1; n2 = i + 1 }
                else if ay >= ax * tan67 { n1 = i - w; n2 = i + w }
                else if (gx[i] > 0) == (gy[i] > 0) { n1 = i - w - 1; n2 = i + w + 1 }
                else { n1 = i - w + 1; n2 = i + w - 1 }
                if m > mag[n1] && m >= mag[n2] { state[i] = m > Float(high) ? 2 : 1 }
            }
        }
        // Hysteresis: keep weak edges connected to strong ones.
        var stack: [Int] = []
        for i in 0..<(w * h) where state[i] == 2 { stack.append(i) }
        var keep = [Bool](repeating: false, count: w * h)
        while let i = stack.popLast() {
            if keep[i] { continue }
            keep[i] = true
            let x = i % w, y = i / w
            for dy in -1...1 {
                for dx in -1...1 {
                    let xx = x + dx, yy = y + dy
                    if xx < 0 || yy < 0 || xx >= w || yy >= h { continue }
                    let j = yy * w + xx
                    if !keep[j] && state[j] != 0 { stack.append(j) }
                }
            }
        }
        var out: [Edge] = []
        for i in 0..<(w * h) where keep[i] {
            let gxf = Double(gx[i]), gyf = Double(gy[i])
            let n = (gxf * gxf + gyf * gyf).squareRoot()
            if n == 0 { continue }
            out.append(Edge(x: Double(i % w), y: Double(i / w), dx: gxf / n, dy: gyf / n))
        }
        return out
    }
}
