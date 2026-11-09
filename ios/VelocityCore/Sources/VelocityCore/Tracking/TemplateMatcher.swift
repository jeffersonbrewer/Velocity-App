import Foundation

/// Normalized cross-correlation template search (like cv2.matchTemplate with TM_CCOEFF_NORMED),
/// run coarse-to-fine so it is fast enough on a phone.
struct PlateTemplate {
    let size: Int          // full-size template side (2 * half)
    let half: Int
    let coarse: [Float]    // template shrunk by coarseFactor, mean removed
    let coarseSize: Int
    let coarseNorm: Float
    let fine: [Float]      // template shrunk by fineFactor, mean removed
    let fineSize: Int
    let fineNorm: Float
    static let coarseFactor = 8
    static let fineFactor = 2

    init?(image: GrayImage, cx: Double, cy: Double, r: Double) {
        let half = Int((r * 1.05).rounded())
        let x0 = Int(cx.rounded()) - half, y0 = Int(cy.rounded()) - half
        guard x0 >= 0, y0 >= 0, x0 + 2 * half < image.width, y0 + 2 * half < image.height, half >= 16 else { return nil }
        self.half = half
        size = 2 * half
        var f = [Float](repeating: 0, count: size * size)
        for y in 0..<size { for x in 0..<size { f[y * size + x] = Float(image[x0 + x, y0 + y]) } }
        coarseSize = size / PlateTemplate.coarseFactor
        (coarse, coarseNorm) = PlateTemplate.zeroMean(PlateTemplate.shrink(f, width: size, height: size, factor: PlateTemplate.coarseFactor))
        fineSize = size / PlateTemplate.fineFactor
        (fine, fineNorm) = PlateTemplate.zeroMean(PlateTemplate.shrink(f, width: size, height: size, factor: PlateTemplate.fineFactor))
    }

    static func zeroMean(_ v: [Float]) -> ([Float], Float) {
        let m = v.reduce(0, +) / Float(v.count)
        let z = v.map { $0 - m }
        return (z, z.reduce(0) { $0 + $1 * $1 }.squareRoot())
    }

    static func shrink(_ v: [Float], width: Int, height: Int, factor k: Int) -> [Float] {
        let w2 = width / k, h2 = height / k
        var out = [Float](repeating: 0, count: w2 * h2)
        for y in 0..<h2 {
            for x in 0..<w2 {
                var s: Float = 0
                for dy in 0..<k { for dx in 0..<k { s += v[(y * k + dy) * width + x * k + dx] } }
                out[y * w2 + x] = s / Float(k * k)
            }
        }
        return out
    }

    /// Best match of the template's center inside the box around (px, py). Returns the center and score.
    /// Searches the whole box at 1/8 size, then around that hit at 1/2 size with a sub-pixel peak.
    func match(_ img: GrayImage, px: Double, py: Double, search: Int) -> (x: Double, y: Double, score: Double)? {
        let x0 = max(Int(px) - half - search, 0), y0 = max(Int(py) - half - search, 0)
        let x1 = min(Int(px) + half + search, img.width), y1 = min(Int(py) + half + search, img.height)
        let ww = x1 - x0, wh = y1 - y0
        guard ww > size, wh > size else { return nil }
        var win = [Float](repeating: 0, count: ww * wh)
        img.pixels.withUnsafeBufferPointer { p in
            for y in 0..<wh { for x in 0..<ww { win[y * ww + x] = Float(p[(y0 + y) * img.width + x0 + x]) } }
        }

        let kc = PlateTemplate.coarseFactor, kf = PlateTemplate.fineFactor
        let cw = ww / kc, ch = wh / kc
        guard cw >= coarseSize, ch >= coarseSize else { return nil }
        let cWin = PlateTemplate.shrink(win, width: ww, height: wh, factor: kc)
        guard let c = PlateTemplate.ncc(window: cWin, ww: cw, wh: ch, tpl: coarse, ts: coarseSize, tnorm: coarseNorm,
                                        xs: 0...(cw - coarseSize), ys: 0...(ch - coarseSize)) else { return nil }

        let fw = ww / kf, fh = wh / kf
        let fWin = PlateTemplate.shrink(win, width: ww, height: wh, factor: kf)
        let ratio = kc / kf
        let xlo = max(c.x * ratio - ratio, 0), xhi = min(c.x * ratio + ratio, fw - fineSize)
        let ylo = max(c.y * ratio - ratio, 0), yhi = min(c.y * ratio + ratio, fh - fineSize)
        guard xlo <= xhi, ylo <= yhi else { return nil }
        let xs = xlo...xhi, ys = ylo...yhi
        guard let f = PlateTemplate.ncc(window: fWin, ww: fw, wh: fh, tpl: fine, ts: fineSize, tnorm: fineNorm,
                                        xs: xs, ys: ys, keepScores: true) else { return nil }
        // Sub-pixel peak by parabola fit, as _match_subpixel in the prototype.
        var dx = 0.0, dy = 0.0
        if let s = f.scores {
            func at(_ x: Int, _ y: Int) -> Double? {
                guard xs.contains(x), ys.contains(y) else { return nil }
                return Double(s[(y - ys.lowerBound) * xs.count + (x - xs.lowerBound)])
            }
            let cs = Double(f.score)
            if let l = at(f.x - 1, f.y), let r = at(f.x + 1, f.y) {
                let d = l - 2 * cs + r
                dx = abs(d) > 1e-9 ? 0.5 * (l - r) / d : 0
            }
            if let u = at(f.x, f.y - 1), let dn = at(f.x, f.y + 1) {
                let d = u - 2 * cs + dn
                dy = abs(d) > 1e-9 ? 0.5 * (u - dn) / d : 0
            }
        }
        let scale = Double(kf)
        return (Double(x0) + (Double(f.x) + dx) * scale + Double(half),
                Double(y0) + (Double(f.y) + dy) * scale + Double(half), Double(f.score))
    }

    static func ncc(window: [Float], ww: Int, wh: Int, tpl: [Float], ts: Int, tnorm: Float,
                    xs: ClosedRange<Int>, ys: ClosedRange<Int>, keepScores: Bool = false)
        -> (x: Int, y: Int, score: Float, scores: [Float]?)? {
        guard tnorm > 0, xs.lowerBound >= 0, ys.lowerBound >= 0 else { return nil }
        var best: (Int, Int, Float) = (xs.lowerBound, ys.lowerBound, -2)
        var scores: [Float]? = keepScores ? [] : nil
        let n = Float(ts * ts)
        window.withUnsafeBufferPointer { wp in
            tpl.withUnsafeBufferPointer { tp in
                for oy in ys {
                    for ox in xs {
                        var sumI: Float = 0, sumI2: Float = 0, sumTI: Float = 0
                        for ty in 0..<ts {
                            let wrow = (oy + ty) * ww + ox
                            let trow = ty * ts
                            for tx in 0..<ts {
                                let iv = wp[wrow + tx]
                                sumI += iv; sumI2 += iv * iv
                                sumTI += tp[trow + tx] * iv
                            }
                        }
                        let varI = sumI2 - sumI * sumI / n
                        let score = varI > 1e-6 ? sumTI / (tnorm * varI.squareRoot()) : 0
                        scores?.append(score)
                        if score > best.2 { best = (ox, oy, score) }
                    }
                }
            }
        }
        return (best.0, best.1, best.2, scores)
    }
}
