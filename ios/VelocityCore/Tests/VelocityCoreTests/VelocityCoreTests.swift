import XCTest
@testable import VelocityCore

/// Reference values come from SciPy/NumPy, which the Python prototype uses.
final class SignalTests: XCTestCase {
    func testButterworthMatchesScipy() {
        let (b, a) = Butterworth.lowpass(order: 4, wn: 8.0 / 120.0)
        let bRef = [9.276462029231158e-05, 0.00037105848116924633, 0.0005565877217538694, 0.00037105848116924633, 9.276462029231158e-05]
        let aRef = [1.0, -3.45318513758661, 4.5041390916339585, -2.627303618228232, 0.5778338981055609]
        for (x, r) in zip(b, bRef) { XCTAssertEqual(x, r, accuracy: 1e-12) }
        for (x, r) in zip(a, aRef) { XCTAssertEqual(x, r, accuracy: 1e-10) }
    }

    func testFiltfiltMatchesScipy() {
        let (b, a) = Butterworth.lowpass(order: 4, wn: 8.0 / 120.0)
        let x = (0..<50).map { sin(Double($0) / 5.0) + 0.1 * Double($0) }
        let y = Butterworth.filtfilt(b: b, a: a, x: x, padlen: 15)
        let ref: [(Int, Double)] = [(0, 0.07510922253053978), (10, 1.5430138721474986), (25, 1.91756951248244), (49, 4.8192607147788005)]
        for (i, r) in ref { XCTAssertEqual(y[i], r, accuracy: 1e-9) }
    }

    func testGradientMatchesNumpy() {
        XCTAssertEqual(Stats.gradient([0, 1, 4, 9, 16], dt: 0.5), [2, 4, 8, 12, 14])
    }

    func testPercentileAndMedian() {
        XCTAssertEqual(Stats.median([3, 1, 2, 4]), 2.5)
        XCTAssertEqual(Stats.percentile([1, 2, 3, 4, 5], 5), 1.2, accuracy: 1e-12)
    }
}

final class PipelineTests: XCTestCase {
    /// A synthetic trap bar set: 3 lifts of 0.5 m, each taking 0.8 s up and 1.0 s down, at 240 fps.
    func syntheticTrack() -> Track {
        let fps = 240.0
        var t: [Double] = [], y: [Double] = []
        let pxPerM = 500.0, floorY = 1400.0
        var time = 0.0
        func hold(_ s: Double, _ h: Double) { for _ in 0..<Int(s * fps) { t.append(time); y.append(floorY - h * pxPerM); time += 1 / fps } }
        func move(_ s: Double, from h0: Double, to h1: Double) {
            let n = Int(s * fps)
            for i in 0..<n {
                let u = Double(i) / Double(n)
                let h = h0 + (h1 - h0) * (1 - cos(Double.pi * u)) / 2
                t.append(time); y.append(floorY - h * pxPerM); time += 1 / fps
            }
        }
        hold(1, 0)
        for _ in 0..<3 { move(0.8, from: 0, to: 0.5); hold(0.3, 0.5); move(1.0, from: 0.5, to: 0); hold(0.5, 0) }
        let r = 0.225 * pxPerM
        return Track(fps: fps, t: t, x: [Double](repeating: 500, count: t.count), y: y,
                     r: [Double](repeating: r, count: t.count), roundness: 1, frameWidth: 1080, frameHeight: 1920)
    }

    func testFindsRepsAndVelocity() throws {
        let ex = ExerciseCatalog.exercise(id: "trap_bar_deadlift")!
        let a = try SetAnalyzer.analyze(track: syntheticTrack(), input: SetInput(exercise: ex, loadKg: 100, bodyMassKg: 80))
        let m = try XCTUnwrap(a.setMetrics)
        XCTAssertEqual(m.repCount, 3)
        for r in m.reps {
            XCTAssertEqual(r.concentricDistance, 0.5, accuracy: 0.01)
            // Mean velocity is distance over the rep's duration. The filter spreads the start and end a
            // little, so the counted rep runs slightly longer than the 0.8 s move.
            XCTAssertEqual(r.meanVelocity, r.concentricDistance / r.concentricDuration, accuracy: 0.01)
            XCTAssertEqual(r.meanVelocity, 0.6, accuracy: 0.03)
            XCTAssertNotNil(r.systemMeanPower)
        }
    }

    func testDeletingARepRenumbersAndRecomputes() throws {
        let ex = ExerciseCatalog.exercise(id: "trap_bar_deadlift")!
        var a = try SetAnalyzer.analyze(track: syntheticTrack(), input: SetInput(exercise: ex, loadKg: 100))
        a.reps[1].deleted = true
        let m = try XCTUnwrap(a.setMetrics)
        XCTAssertEqual(m.repCount, 2)
        XCTAssertEqual(m.reps.map(\.rep), [1, 2])
        XCTAssertNil(m.systemMeanPower)
    }

    func testPeakMetricsAreBeta() {
        XCTAssertEqual(MetricKind.peakVelocity.status, .beta)
        XCTAssertEqual(MetricKind.peakPower.status, .beta)
        XCTAssertEqual(MetricKind.meanVelocity.status, .validated)
    }
}

final class ResampleTests: XCTestCase {
    /// A 240 fps recording whose timestamps jitter must still be analyzed on a 240 Hz grid.
    func testJitteryTimestampsSnapToCaptureRate() {
        var t: [Double] = []
        var time = 0.0
        for i in 0..<2400 {
            t.append(time)
            let step: Double
            switch i % 10 {
            case 0: step = 1.0 / 300
            case 1: step = 2.0 / 240 - 1.0 / 300
            default: step = 1.0 / 240
            }
            time += step
        }
        let track = Track(fps: 240, t: t, x: t.map { _ in 0 }, y: t.map { 500 + 100 * sin($0) }, r: t.map { _ in 100 },
                          roundness: 1, frameWidth: 1080, frameHeight: 1920)
        XCTAssertEqual(KinematicsBuilder.resampleUniform(track).fps, 240)
    }
}

final class TrackingTests: XCTestCase {
    /// Draw a dark plate with a lighter hub on a light background and check it is found precisely.
    func testDetectsAndRefinesPlate() throws {
        let w = 540, h = 960
        let cx = 270.3, cy = 610.7, r = 120.0
        var px = [UInt8](repeating: 200, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let d = hypot(Double(x) - cx, Double(y) - cy)
                if d < r { px[y * w + x] = d < 0.3 * r ? 120 : 40 }
            }
        }
        let img = GrayImage(width: w, height: h, pixels: px)
        let c = try XCTUnwrap(PlateDetector.detect(img))
        XCTAssertEqual(c.x, cx, accuracy: 1.0)
        XCTAssertEqual(c.y, cy, accuracy: 1.0)
        XCTAssertEqual(c.r, r, accuracy: 1.5)
        XCTAssertGreaterThan(c.roundness, 0.97)
    }
}
