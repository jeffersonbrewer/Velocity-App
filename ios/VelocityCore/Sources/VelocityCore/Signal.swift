import Foundation

// Numerical helpers that reproduce the NumPy/SciPy functions the Python prototype uses,
// so the app gives the same numbers as the validated prototype.

enum Stats {
    /// Median ignoring nothing; returns NaN for an empty array (like numpy, with a warning there).
    static func median(_ values: [Double]) -> Double {
        if values.isEmpty { return .nan }
        let s = values.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
    }

    static func nanMedian(_ values: [Double]) -> Double {
        median(values.filter { !$0.isNaN })
    }

    /// numpy.percentile with the default linear interpolation.
    static func percentile(_ values: [Double], _ q: Double) -> Double {
        if values.isEmpty { return .nan }
        let s = values.sorted()
        let pos = q / 100 * Double(s.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = min(lo + 1, s.count - 1)
        let frac = pos - Double(lo)
        return s[lo] + (s[hi] - s[lo]) * frac
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count)
    }

    static func mean(_ values: ArraySlice<Double>) -> Double {
        values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count)
    }

    /// Least-squares straight line y = a + b x. Returns (a, b) like numpy.polyfit(x, y, 1) reversed.
    static func lineFit(_ x: [Double], _ y: [Double]) -> (a: Double, b: Double) {
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n
        let my = y.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for i in 0..<x.count {
            let dx = x[i] - mx
            sxx += dx * dx
            sxy += dx * (y[i] - my)
        }
        let b = sxy / sxx
        return (my - b * mx, b)
    }

    /// numpy.interp: piecewise-linear interpolation, clamped to the end values outside xp.
    static func interp(_ x: [Double], _ xp: [Double], _ fp: [Double]) -> [Double] {
        var out = [Double](repeating: .nan, count: x.count)
        guard !xp.isEmpty else { return out }
        var j = 0
        for (i, xi) in x.enumerated() {
            if xi <= xp[0] { out[i] = fp[0]; continue }
            if xi >= xp[xp.count - 1] { out[i] = fp[fp.count - 1]; continue }
            // x is usually sorted, so walk forward; fall back to binary search otherwise.
            if j >= xp.count - 1 || xp[j] > xi { j = max(0, searchSortedRight(xp, xi) - 1) }
            while j < xp.count - 2 && xp[j + 1] <= xi { j += 1 }
            let x0 = xp[j], x1 = xp[j + 1]
            let f = (xi - x0) / (x1 - x0)
            out[i] = fp[j] + f * (fp[j + 1] - fp[j])
        }
        return out
    }

    /// numpy.searchsorted(a, v, side="left").
    static func searchSortedLeft(_ a: [Double], _ v: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < v { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    static func searchSortedRight(_ a: [Double], _ v: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] <= v { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// numpy.gradient with uniform spacing (second-order centered inside, first-order at the ends).
    static func gradient(_ y: [Double], dt: Double) -> [Double] {
        let n = y.count
        guard n >= 2 else { return [Double](repeating: 0, count: n) }
        var g = [Double](repeating: 0, count: n)
        g[0] = (y[1] - y[0]) / dt
        g[n - 1] = (y[n - 1] - y[n - 2]) / dt
        if n > 2 {
            for i in 1..<(n - 1) { g[i] = (y[i + 1] - y[i - 1]) / (2 * dt) }
        }
        return g
    }

    /// Python's round(): halves go to the nearest even number.
    static func pyRound(_ x: Double) -> Int { Int(x.rounded(.toNearestOrEven)) }
}

/// Zero-lag Butterworth low-pass filter, matching scipy.signal.butter + filtfilt.
public enum Butterworth {
    /// Digital low-pass coefficients (b, a) for scipy.signal.butter(order, wn), wn relative to Nyquist.
    static func lowpass(order n: Int, wn: Double) -> (b: [Double], a: [Double]) {
        // Analog prototype poles, pre-warped cutoff, then the bilinear transform (fs = 2).
        let fs = 2.0
        let warped = 2 * fs * tan(Double.pi * wn / fs)
        var poles: [Complex] = []
        var m = -n + 1
        while m < n {
            poles.append(-Complex.expi(Double.pi * Double(m) / Double(2 * n)) * warped)
            m += 2
        }
        let fs2 = 2 * fs
        let zPoles = poles.map { (Complex(fs2) + $0) / (Complex(fs2) - $0) }
        var denom = Complex(1)
        for p in poles { denom = denom * (Complex(fs2) - p) }
        let k = pow(warped, Double(n)) / denom.re  // gain k = warped^n, divided by prod(fs2 - p)
        let zZeros = [Complex](repeating: Complex(-1), count: n)
        let b = poly(zZeros).map { $0.re * k }
        let a = poly(zPoles).map { $0.re }
        return (b, a)
    }

    /// Zero-phase filtering like scipy.signal.filtfilt(b, a, x, padlen=...) with odd padding.
    static func filtfilt(b: [Double], a: [Double], x: [Double], padlen: Int) -> [Double] {
        let n = x.count
        guard n > padlen, n > 0 else { return x }
        var ext = [Double]()
        ext.reserveCapacity(n + 2 * padlen)
        if padlen > 0 {
            for i in stride(from: padlen, through: 1, by: -1) { ext.append(2 * x[0] - x[i]) }
        }
        ext.append(contentsOf: x)
        if padlen > 0 {
            for i in 1...padlen { ext.append(2 * x[n - 1] - x[n - 1 - i]) }
        }
        let zi = lfilterZi(b: b, a: a)
        var y = lfilter(b: b, a: a, x: ext, zi: zi.map { $0 * ext[0] })
        y.reverse()
        var y2 = lfilter(b: b, a: a, x: y, zi: zi.map { $0 * y[0] })
        y2.reverse()
        return Array(y2[padlen..<(padlen + n)])
    }

    /// Direct form II transposed, like scipy.signal.lfilter with initial conditions zi.
    static func lfilter(b: [Double], a: [Double], x: [Double], zi: [Double]) -> [Double] {
        let a0 = a[0]
        let bn = b.map { $0 / a0 }, an = a.map { $0 / a0 }
        let order = max(bn.count, an.count)
        let bb = bn + [Double](repeating: 0, count: order - bn.count)
        let aa = an + [Double](repeating: 0, count: order - an.count)
        var z = zi + [Double](repeating: 0, count: max(0, order - 1 - zi.count))
        var y = [Double](repeating: 0, count: x.count)
        for (i, xi) in x.enumerated() {
            let yi = bb[0] * xi + (order > 1 ? z[0] : 0)
            if order > 1 {
                for j in 0..<(order - 2) { z[j] = bb[j + 1] * xi + z[j + 1] - aa[j + 1] * yi }
                z[order - 2] = bb[order - 1] * xi - aa[order - 1] * yi
            }
            y[i] = yi
        }
        return y
    }

    /// Steady-state initial conditions for a step input, like scipy.signal.lfilter_zi.
    static func lfilterZi(b: [Double], a: [Double]) -> [Double] {
        let a0 = a[0]
        var bn = b.map { $0 / a0 }, an = a.map { $0 / a0 }
        let n = max(bn.count, an.count)
        bn += [Double](repeating: 0, count: n - bn.count)
        an += [Double](repeating: 0, count: n - an.count)
        let m = n - 1
        guard m > 0 else { return [] }
        // I - A^T where A is the companion matrix of a.
        var mat = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)
        for i in 0..<m {
            for j in 0..<m {
                // companion(a): row 0 = -a[1:], subdiagonal ones. Transposed: column 0 = -a[1:].
                var aT = 0.0
                if j == 0 { aT = -an[i + 1] }
                if i + 1 == j { aT = 1 }  // transpose of subdiagonal
                mat[i][j] = (i == j ? 1 : 0) - aT
            }
        }
        var rhs = (0..<m).map { bn[$0 + 1] - an[$0 + 1] * bn[0] }
        return LinearAlgebra.solve(&mat, &rhs)
    }

    /// Multiply out (x - r0)(x - r1)... into coefficients, highest power first (numpy.poly).
    private static func poly(_ roots: [Complex]) -> [Complex] {
        var c = [Complex(1)]
        for r in roots {
            var next = [Complex](repeating: Complex(0), count: c.count + 1)
            for i in 0..<c.count {
                next[i] = next[i] + c[i]
                next[i + 1] = next[i + 1] - c[i] * r
            }
            c = next
        }
        return c
    }

    /// Low-pass a uniformly sampled signal, as kinematics.lowpass in the prototype.
    public static func lowpassFilter(_ sig: [Double], fps: Double, cutoffHz: Double, order: Int = 4) -> [Double] {
        let nyq = fps / 2
        if cutoffHz >= nyq * 0.95 { return sig }
        let (b, a) = lowpass(order: order, wn: cutoffHz / nyq)
        let padlen = min(3 * max(a.count, b.count), sig.count - 1)
        return filtfilt(b: b, a: a, x: sig, padlen: padlen)
    }
}

enum LinearAlgebra {
    /// Solve m x = rhs with partial-pivot Gaussian elimination (small systems only).
    static func solve(_ m: inout [[Double]], _ rhs: inout [Double]) -> [Double] {
        let n = rhs.count
        for col in 0..<n {
            var piv = col
            for r in (col + 1)..<max(col + 1, n) where abs(m[r][col]) > abs(m[piv][col]) { piv = r }
            if piv != col { m.swapAt(piv, col); rhs.swapAt(piv, col) }
            let d = m[col][col]
            if d == 0 { continue }
            for r in 0..<n where r != col {
                let f = m[r][col] / d
                if f == 0 { continue }
                for c in col..<n { m[r][c] -= f * m[col][c] }
                rhs[r] -= f * rhs[col]
            }
        }
        return (0..<n).map { m[$0][$0] == 0 ? 0 : rhs[$0] / m[$0][$0] }
    }
}

struct Complex {
    var re: Double
    var im: Double
    init(_ re: Double, _ im: Double = 0) { self.re = re; self.im = im }
    static func expi(_ t: Double) -> Complex { Complex(cos(t), sin(t)) }
    static func + (l: Complex, r: Complex) -> Complex { Complex(l.re + r.re, l.im + r.im) }
    static func - (l: Complex, r: Complex) -> Complex { Complex(l.re - r.re, l.im - r.im) }
    static prefix func - (v: Complex) -> Complex { Complex(-v.re, -v.im) }
    static func * (l: Complex, r: Complex) -> Complex {
        Complex(l.re * r.re - l.im * r.im, l.re * r.im + l.im * r.re)
    }
    static func * (l: Complex, r: Double) -> Complex { Complex(l.re * r, l.im * r) }
    static func / (l: Complex, r: Complex) -> Complex {
        let d = r.re * r.re + r.im * r.im
        return Complex((l.re * r.re + l.im * r.im) / d, (l.im * r.re - l.re * r.im) / d)
    }
}
