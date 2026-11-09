import Foundation

public struct PlateCircle: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var r: Double
    /// Minor/major axis ratio of the edge points. 1.0 means the camera is square to the plate.
    public var roundness: Double = 1.0
    /// How many of the 180 rays found an edge that agrees with the fitted circle.
    public var support: Int = 0
}

enum CircleFit {
    static let nRays = 180
    static let nRadii = 64
    // Ray directions are the same for every frame.
    static let cosA: [Double] = (0..<nRays).map { cos(2 * Double.pi * Double($0) / Double(nRays)) }
    static let sinA: [Double] = (0..<nRays).map { sin(2 * Double.pi * Double($0) / Double(nRays)) }

    /// Fit a circle to the plate's outer edge with sub-pixel precision. Mirrors tracking.refine_circle:
    /// sample along rays from the approximate center, take the strongest edge on each ray, then
    /// least-squares fit a circle with outlier rejection.
    static func refine(_ img: GrayImage, x: Double, y: Double, r: Double) -> PlateCircle? {
        let r0 = 0.75 * r
        let step = (1.25 * r - r0) / Double(nRadii - 1)
        var edgeR = [Double](repeating: 0, count: nRays)
        var strength = [Double](repeating: 0, count: nRays)
        var valid = [Bool](repeating: false, count: nRays)
        var profile = [Double](repeating: 0, count: nRadii)
        var grad = [Double](repeating: 0, count: nRadii - 1)
        var validCount = 0
        for ray in 0..<nRays {
            let c = cosA[ray], s = sinA[ray]
            var ok = true
            for k in 0..<nRadii {
                let rr = r0 + Double(k) * step
                let v = img.sample(x + c * rr, y + s * rr)
                if v.isNaN { ok = false; break }
                profile[k] = v
            }
            guard ok else { continue }
            valid[ray] = true
            validCount += 1
            var best = 0
            for k in 0..<(nRadii - 1) {
                grad[k] = abs(profile[k + 1] - profile[k])
                if grad[k] > grad[best] { best = k }
            }
            // Parabolic interpolation of the gradient peak for sub-sample precision.
            let ks = min(max(best, 1), nRadii - 3)
            let g0 = grad[ks - 1], g1 = grad[ks], g2 = grad[ks + 1]
            let denom = g0 - 2 * g1 + g2
            let offset = abs(denom) > 1e-6 ? 0.5 * (g0 - g2) / denom : 0
            edgeR[ray] = r0 + (Double(ks) + 0.5 + offset) * step
            strength[ray] = g1
        }
        if Double(validCount) < Double(nRays) * 0.4 { return nil }
        let medStrength = Stats.median((0..<nRays).filter { valid[$0] }.map { strength[$0] })
        var px: [Double] = [], py: [Double] = []
        for ray in 0..<nRays where valid[ray] && strength[ray] > 0.3 * medStrength {
            px.append(x + cosA[ray] * edgeR[ray])
            py.append(y + sinA[ray] * edgeR[ray])
        }
        if px.count < 20 { return nil }

        var fit = kasa(px, py)
        for _ in 0..<3 {
            fit = kasa(px, py)
            let resid = zip(px, py).map { hypot($0 - fit.x, $1 - fit.y) - fit.r }
            let medResid = Stats.median(resid)
            let mad = Stats.median(resid.map { abs($0 - medResid) }) + 1e-6
            let inl = resid.map { abs($0) < 3 * 1.4826 * mad + 0.5 }
            let nIn = inl.filter { $0 }.count
            if nIn == px.count || nIn < 20 { break }
            px = px.indices.filter { inl[$0] }.map { px[$0] }
            py = py.indices.filter { inl[$0] }.map { py[$0] }
        }
        return PlateCircle(x: fit.x, y: fit.y, r: fit.r, roundness: px.count >= 5 ? roundness(px, py) : 1, support: px.count)
    }

    /// Algebraic (Kasa) least-squares circle fit.
    static func kasa(_ px: [Double], _ py: [Double]) -> (x: Double, y: Double, r: Double) {
        // Solve [2x 2y 1] [cx cy c]^T = x^2 + y^2 through the normal equations.
        var m = [[Double]](repeating: [0, 0, 0], count: 3)
        var rhs = [0.0, 0.0, 0.0]
        for i in 0..<px.count {
            let row = [2 * px[i], 2 * py[i], 1.0]
            let b = px[i] * px[i] + py[i] * py[i]
            for j in 0..<3 {
                rhs[j] += row[j] * b
                for k in 0..<3 { m[j][k] += row[j] * row[k] }
            }
        }
        let s = LinearAlgebra.solve(&m, &rhs)
        return (s[0], s[1], (s[2] + s[0] * s[0] + s[1] * s[1]).squareRoot())
    }

    /// Minor/major axis ratio of a least-squares ellipse through the edge points
    /// (Halir & Flusser direct fit, as cv2.fitEllipse is used in the prototype).
    static func roundness(_ px: [Double], _ py: [Double]) -> Double {
        let mx = Stats.mean(px), my = Stats.mean(py)
        var scale = 0.0
        for i in 0..<px.count { scale = max(scale, abs(px[i] - mx), abs(py[i] - my)) }
        guard scale > 0 else { return 1 }
        var s1 = [[Double]](repeating: [0, 0, 0], count: 3)
        var s2 = s1, s3 = s1
        for i in 0..<px.count {
            let x = (px[i] - mx) / scale, y = (py[i] - my) / scale
            let d1 = [x * x, x * y, y * y], d2 = [x, y, 1.0]
            for j in 0..<3 {
                for k in 0..<3 {
                    s1[j][k] += d1[j] * d1[k]
                    s2[j][k] += d1[j] * d2[k]
                    s3[j][k] += d2[j] * d2[k]
                }
            }
        }
        guard let s3inv = invert3(s3) else { return 1 }
        // T = -S3^-1 S2^T ; M = S1 + S2 T
        var t = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { t[i][j] -= s3inv[i][k] * s2[j][k] } } }
        var m = s1
        for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { m[i][j] += s2[i][k] * t[k][j] } } }
        // Premultiply by C1^-1 = [[0, 0, 1/2], [0, -1, 0], [1/2, 0, 0]].
        let mm = [m[2].map { $0 / 2 }, m[1].map { -$0 }, m[0].map { $0 / 2 }]
        for lambda in realEigenvalues3(mm) {
            guard let v = nullVector3(mm, lambda) else { continue }
            let a = v[0], b = v[1], c = v[2]
            guard 4 * a * c - b * b > 0 else { continue }
            // Axis lengths go as 1/sqrt of the eigenvalues of [[a, b/2], [b/2, c]].
            let tr = a + c, det = a * c - b * b / 4
            let disc = max(tr * tr / 4 - det, 0).squareRoot()
            let l1 = abs(tr / 2 + disc), l2 = abs(tr / 2 - disc)
            guard l1 > 0, l2 > 0 else { continue }
            return (min(l1, l2) / max(l1, l2)).squareRoot()
        }
        return 1
    }

    static func invert3(_ m: [[Double]]) -> [[Double]]? {
        let det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        guard abs(det) > 1e-300 else { return nil }
        var inv = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 {
            for j in 0..<3 {
                let r = [0, 1, 2].filter { $0 != j }, c = [0, 1, 2].filter { $0 != i }
                let minor = m[r[0]][c[0]] * m[r[1]][c[1]] - m[r[0]][c[1]] * m[r[1]][c[0]]
                inv[i][j] = ((i + j) % 2 == 0 ? 1 : -1) * minor / det
            }
        }
        return inv
    }

    /// Real roots of the characteristic polynomial of a 3x3 matrix.
    static func realEigenvalues3(_ m: [[Double]]) -> [Double] {
        let tr = m[0][0] + m[1][1] + m[2][2]
        let c1 = m[0][0] * m[1][1] - m[0][1] * m[1][0] + m[0][0] * m[2][2] - m[0][2] * m[2][0]
            + m[1][1] * m[2][2] - m[1][2] * m[2][1]
        let det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        // lambda^3 - tr lambda^2 + c1 lambda - det = 0; substitute lambda = t + tr/3.
        let p = c1 - tr * tr / 3
        let q = -2 * tr * tr * tr / 27 + tr * c1 / 3 - det
        let shift = tr / 3
        let disc = q * q / 4 + p * p * p / 27
        if disc > 0 {
            let sq = disc.squareRoot()
            return [cbrt(-q / 2 + sq) + cbrt(-q / 2 - sq) + shift]
        }
        let r = (-p / 3).squareRoot()
        guard r > 0 else { return [shift] }
        let phi = acos(max(-1, min(1, -q / (2 * r * r * r))))
        return (0..<3).map { 2 * r * cos((phi - 2 * Double.pi * Double($0)) / 3) + shift }
    }

    /// A vector v with (m - lambda I) v = 0, from the largest cross product of two rows.
    static func nullVector3(_ m: [[Double]], _ lambda: Double) -> [Double]? {
        var a = m
        for i in 0..<3 { a[i][i] -= lambda }
        func cross(_ u: [Double], _ v: [Double]) -> [Double] {
            [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]]
        }
        let cands = [cross(a[0], a[1]), cross(a[0], a[2]), cross(a[1], a[2])]
        let best = cands.max { $0.reduce(0) { $0 + $1 * $1 } < $1.reduce(0) { $0 + $1 * $1 } }!
        return best.reduce(0) { $0 + $1 * $1 } > 0 ? best : nil
    }
}
