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

    func testSetRecordRoundTripKeepsEditsAndNumbers() throws {
        let ex = ExerciseCatalog.exercise(id: "trap_bar_deadlift")!
        var a = try SetAnalyzer.analyze(track: syntheticTrack(), input: SetInput(exercise: ex, loadKg: 100, bodyMassKg: 80))
        a.reps[2].deleted = true
        a.reps[0].adjustedConcentric = Phase(start: a.reps[0].detected.concentric.start + 10, end: a.reps[0].detected.concentric.end)
        var track = a.track
        track.x[5] = .nan  // lost frames must survive the round trip
        a.track = track
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SetStore(folder: folder)
        let id = UUID()
        try store.save(SetRecord(id: id, date: Date(), setType: "Working", clipName: "test", analysis: a))
        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertTrue(loaded[0].track.x[5].isNaN)
        let b = try loaded[0].analysis()
        XCTAssertEqual(b.setMetrics?.repCount, 2)
        XCTAssertEqual(b.setMetrics!.meanVelocity, a.setMetrics!.meanVelocity, accuracy: 1e-9)
        store.delete(id)
        XCTAssertEqual(store.loadAll().count, 0)
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

final class ProfileTests: XCTestCase {
    private func day(_ d: Int) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + Double(d) * 86_400) }

    /// Line fit matches numpy.polyfit, and the 1RM is read off at the group default.
    func testFitAndOneRm() throws {
        let loads = [60.0, 80, 100, 120]
        let mv = loads.map { 1.62 - 0.008 * $0 }
        let sets = zip(loads, mv).map { ProfileSet(date: day(0), loadKg: $0, bestMeanVelocity: $1, slowestMeanVelocity: $1 - 0.05, isMaxSingle: false) }
        let p = StrengthProfile.build(sets: sets, defaultMvt: 0.26)
        let line = try XCTUnwrap(p.line)
        XCTAssertEqual(line.slope, -0.008, accuracy: 1e-9)
        XCTAssertEqual(line.intercept, 1.62, accuracy: 1e-9)
        XCTAssertEqual(line.r2, 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(p.oneRmKg), 170, accuracy: 1e-6)
        XCTAssertEqual(p.mvtSource, .groupDefault)
        XCTAssertEqual(p.readiness(loadKg: 100, bestMeanVelocity: 0.83)?.reading, .normal)
        XCTAssertEqual(p.readiness(loadKg: 100, bestMeanVelocity: 0.74)?.reading, .down)
    }

    /// A max single replaces the default 1RM velocity; the line comes from the latest ramp; edits lose to a measured value.
    func testMeasuredMvtAndLatestTest() throws {
        var sets = [60.0, 100].map { ProfileSet(date: day(0), loadKg: $0, bestMeanVelocity: 1.5 - 0.01 * $0, slowestMeanVelocity: 0, isMaxSingle: false) }
        sets += [60.0, 80, 100].map { ProfileSet(date: day(30), loadKg: $0, bestMeanVelocity: 1.62 - 0.008 * $0, slowestMeanVelocity: 0, isMaxSingle: false) }
        sets.append(ProfileSet(date: day(30).addingTimeInterval(600), loadKg: 160, bestMeanVelocity: 0.34, slowestMeanVelocity: 0.34, isMaxSingle: true))
        let p = StrengthProfile.build(sets: sets, defaultMvt: 0.30, editedMvt: 0.20)
        XCTAssertEqual(p.testSets.count, 4)
        XCTAssertEqual(p.mvt, 0.34)
        XCTAssertEqual(try XCTUnwrap(p.oneRmKg), 160, accuracy: 1)
        XCTAssertNil(p.retestReason(today: day(40)))
        XCTAssertNotNil(p.retestReason(today: day(58)))
    }

    func testNoLineWithOneLoadAndNoOneRmForCleans() {
        let one = [ProfileSet(date: day(0), loadKg: 100, bestMeanVelocity: 0.8, slowestMeanVelocity: 0.7, isMaxSingle: false)]
        XCTAssertNil(StrengthProfile.build(sets: one, defaultMvt: 0.3).line)
        let ramp = [60.0, 80].map { ProfileSet(date: day(0), loadKg: $0, bestMeanVelocity: 2 - 0.01 * $0, slowestMeanVelocity: 1, isMaxSingle: false) }
        let p = StrengthProfile.build(sets: ramp, defaultMvt: nil, allowsOneRm: false)
        XCTAssertNotNil(p.line)
        XCTAssertNil(p.oneRmKg)
        XCTAssertFalse(ExerciseCatalog.exercise(id: "power_clean")!.allowsOneRm)
    }
}

final class ProfileRampTests: XCTestCase {
    /// True 1RM 125 kg (MV = 1.6 - 0.0108 x load, MVT 0.25); the lifter guessed 136 kg (300 lb).
    func testOverestimateIsCutAtOnce() {
        let mv = { (kg: Double) in 1.6 - 0.0108 * kg }
        let done = [54.0, 68].map { (loadKg: $0, mv: mv($0)) }
        XCTAssertEqual(ProfileRamp.revisedOneRm(currentKg: 136, done: done, mvt: 0.25), 125, accuracy: 0.01)
    }

    func testUnderestimateIsRaisedCautiously() {
        let mv = { (kg: Double) in 1.6 - 0.0108 * kg }
        let two = [44.0, 56].map { (loadKg: $0, mv: mv($0)) }
        XCTAssertEqual(ProfileRamp.revisedOneRm(currentKg: 110, done: two, mvt: 0.25), 117.5, accuracy: 0.01)
        let three = [44.0, 56, 72].map { (loadKg: $0, mv: mv($0)) }
        XCTAssertEqual(ProfileRamp.revisedOneRm(currentKg: 110, done: three, mvt: 0.25), 121, accuracy: 0.01)
        XCTAssertEqual(ProfileRamp.revisedOneRm(currentKg: 110, done: [(60, 0.9)], mvt: 0.25), 110)
    }
}

final class ProgrammingTests: XCTestCase {
    // Spec example: 1RM 170 kg, MV = 1.62 - 0.008 x load.
    let line = LoadVelocityLine(slope: -0.008, intercept: 1.62, r2: 1, loadCount: 5, minLoadKg: 60, maxLoadKg: 150)
    let round = { (kg: Double) in (kg / 2.5).rounded() * 2.5 }

    func testSpecExampleLoadAndTarget() {
        let week = WeekPlan(pctLow: 0.85, pctHigh: 0.85, lossCutoffPct: 20, sets: 4, isDeload: false)
        let p = Prescriber.mainLift(goal: .maxStrength, template: .default(.maxStrength), week: week, oneRmKg: 170,
                                    line: line, readiness: .normal, round: round)
        XCTAssertEqual(p.loadKg, 145)
        XCTAssertEqual(try XCTUnwrap(p.targetVelocity), 0.46, accuracy: 0.001)
        let manual = Prescriber.mainLift(goal: .maxStrength, template: .default(.maxStrength), week: week, oneRmKg: 170,
                                         line: nil, readiness: nil, round: round)
        XCTAssertEqual(manual.loadKg, 145)
        XCTAssertNil(manual.zoneLow)
        XCTAssertEqual(Prescriber.nextLoad(after: 145, firstRepMV: 0.9, prescription: manual, stepKg: 2.5).loadKg, 145)
        let down = Prescriber.mainLift(goal: .maxStrength, template: .default(.maxStrength), week: week, oneRmKg: 170,
                                       line: line, readiness: .down, round: round)
        XCTAssertEqual(down.loadKg, 137.5)
        XCTAssertEqual(down.sets, 3)
        let well = Prescriber.mainLift(goal: .maxStrength, template: .default(.maxStrength), week: week, oneRmKg: 170,
                                       line: line, readiness: .wellDown, round: round)
        XCTAssertEqual(well.goal, .strengthSpeed)
    }

    func testBlocksEndWithDeload() {
        let ms = BlockPlanner.weeks(for: .default(.maxStrength), count: 6)
        XCTAssertEqual(ms.map(\.pctLow), [0.74, 0.77, 0.80, 0.83, 0.86, 0.70])
        let power = BlockPlanner.weeks(for: .default(.power), count: 4)
        XCTAssertEqual(power.count, 4)
        XCTAssertTrue(power.last!.isDeload)
        XCTAssertLessThanOrEqual(power.last!.pctHigh, 0.35 + 1e-9)
        XCTAssertLessThan(power[0].pctMid, power[2].pctMid)
    }

    func testBetweenSetsCappedAtFivePercent() {
        let week = WeekPlan(pctLow: 0.84, pctHigh: 0.86, lossCutoffPct: 20, sets: 4, isDeload: false)
        let p = Prescriber.mainLift(goal: .maxStrength, template: .default(.maxStrength), week: week, oneRmKg: 170,
                                    line: line, readiness: nil, round: round)
        XCTAssertEqual(Prescriber.nextLoad(after: 145, firstRepMV: 0.60, prescription: p, stepKg: 2.5).loadKg, 147.5)
        XCTAssertEqual(Prescriber.nextLoad(after: 152.5, firstRepMV: 0.60, prescription: p, stepKg: 2.5).loadKg, 152.5)
        XCTAssertEqual(Prescriber.nextLoad(after: 145, firstRepMV: 0.30, prescription: p, stepKg: 2.5).loadKg, 142.5)
        XCTAssertEqual(Prescriber.nextLoad(after: 145, firstRepMV: 0.46, prescription: p, stepKg: 2.5).loadKg, 145)
    }

    func testResponsiveDeloadAndSkipAhead() {
        var b = BlockProgress()
        b.finishSession(reading: .down, weeks: 6, daysPerWeek: 3)      // week 1 day 1
        b.finishSession(reading: .wellDown, weeks: 6, daysPerWeek: 3)  // week 1 day 2 -> deload
        XCTAssertTrue(b.inResponsiveDeload)
        XCTAssertEqual(b.week, 1); XCTAssertEqual(b.day, 2)
        b.finishSession(reading: .down, weeks: 6, daysPerWeek: 3)
        XCTAssertEqual(b.deloadSessionsLeft, 1)
        b.finishSession(reading: .normal, weeks: 6, daysPerWeek: 3)    // recovered: skip ahead 2 sessions
        XCTAssertFalse(b.inResponsiveDeload)
        XCTAssertEqual(b.week, 2); XCTAssertEqual(b.day, 1)

        var late = BlockProgress(); late.week = 4
        late.finishSession(reading: .down, weeks: 6, daysPerWeek: 2)
        late.finishSession(reading: .down, weeks: 6, daysPerWeek: 2)
        XCTAssertEqual(late.week, 6)
        late.finishSession(reading: nil, weeks: 6, daysPerWeek: 2)
        late.finishSession(reading: nil, weeks: 6, daysPerWeek: 2)
        XCTAssertTrue(late.retestDue)
    }

    func testDriftAndAccessories() {
        let day = { (d: Double) in Date(timeIntervalSince1970: 1_790_000_000 + d * 86_400) }
        // Bar moves 0.08 m/s faster than predicted at 145 kg: implied 1RM 180 kg (+5.9%).
        let fast = (0..<3).map { ProfileDrift.Check(date: day(Double($0 * 2)), loadKg: 145, firstRepMV: 0.54) }
        XCTAssertEqual(try XCTUnwrap(ProfileDrift.retestSuggested(fast, line: line, mvt: 0.26, oneRmKg: 170)), 10.0 / 170, accuracy: 1e-6)
        let small = (0..<3).map { ProfileDrift.Check(date: day(Double($0 * 2)), loadKg: 145, firstRepMV: 0.50) }
        XCTAssertNil(ProfileDrift.retestSuggested(small, line: line, mvt: 0.26, oneRmKg: 170))

        let a = AccessoryPlan(name: "RDL", sets: 3, repLow: 8, repHigh: 12, loadKg: 60, stepKg: 2.5)
        XCTAssertEqual(a.progressed(repsPerSet: [12, 12, 12]).loadKg, 62.5)
        XCTAssertEqual(a.progressed(repsPerSet: [12, 11, 12]).loadKg, 60)
        XCTAssertEqual(a.sets(for: .down), 2)
        XCTAssertEqual(a.sets(for: .wellDown), 0)
    }
}

final class LearnedLineTests: XCTestCase {
    func testLearnsFromEarlierSessionsOnly() throws {
        let day = { (d: Double) in Date(timeIntervalSince1970: 1_790_000_000 + d * 86_400) }
        let mv = { (kg: Double) in 1.62 - 0.008 * kg }
        var pts = [100.0, 130, 132.5, 135].map { LearnedLine.Point(date: day(0), loadKg: $0, bestMeanVelocity: mv($0)) }
        XCTAssertNil(LearnedLine.fit(pts, oneRmKg: 170, before: day(0)))        // today only: nothing learned yet
        let line = try XCTUnwrap(LearnedLine.fit(pts, oneRmKg: 170, before: day(2)))
        XCTAssertEqual(line.slope, -0.008, accuracy: 1e-9)
        pts = [130.0, 135].map { LearnedLine.Point(date: day(0), loadKg: $0, bestMeanVelocity: mv($0)) }
        XCTAssertNil(LearnedLine.fit(pts, oneRmKg: 170, before: day(2)))         // loads too close together
    }
}

final class AccessoryTests: XCTestCase {
    let round = { (kg: Double) in (kg / 2.5).rounded() * 2.5 }

    func testRIRSetsNextLoad() {
        let a = AccessoryPlan(name: "DB bench", sets: 3, repLow: 8, repHigh: 12, loadKg: 20, stepKg: 2.5, targetRIR: 2)
        // 12 reps with 4 in reserve at 20 kg: rep max 30.7 kg; 10 reps at RIR 2 -> 24 kg, capped at +15% (22.5).
        XCTAssertEqual(a.next(after: [AccessorySet(reps: 12, rir: 4)], round: round).plan.loadKg, 22.5)
        // 8 reps at 0 RIR: rep max 25.3 kg -> 10 at RIR 2 = 19.0 -> 20 kg after rounding... stays or drops.
        XCTAssertLessThanOrEqual(a.next(after: [AccessorySet(reps: 8, rir: 0)], round: round).plan.loadKg, 20)
        // Exactly on target (10 reps at RIR 2) keeps the load.
        XCTAssertEqual(a.next(after: [AccessorySet(reps: 10, rir: 2)], round: round).plan.loadKg, 20)
        // No RIR: double progression.
        XCTAssertEqual(a.next(after: [12, 12, 12].map { AccessorySet(reps: $0, rir: nil) }, round: round).plan.loadKg, 22.5)
    }

    func testFillIsHolisticAndBalanced() {
        let bench = AccessoryLibraryData.fill(mainLiftID: "bench_press", goal: .maxStrength, otherDays: [], usedElsewhere: [])
        XCTAssertEqual(bench.count, 3)
        XCTAssertTrue(bench[0].patterns.contains(.horizontalPush))
        let covered = Set(bench.flatMap(\.patterns).map(\.family))
        XCTAssertTrue(covered.contains("Hinge") || covered.contains("Squat / lunge"))
        print("BENCH DAY:", bench.map(\.name))
        let trap = AccessoryLibraryData.fill(mainLiftID: "trap_bar_deadlift", goal: .maxStrength,
                                             otherDays: [[.horizontalPush] + bench.flatMap(\.patterns)], usedElsewhere: Set(bench.map(\.id)))
        print("TRAP DAY:", trap.map(\.name))
        let power = AccessoryLibraryData.fill(mainLiftID: "back_squat", goal: .power, otherDays: [], usedElsewhere: [])
        print("POWER SQUAT DAY:", power.map(\.name))
        XCTAssertTrue(power[0].ballistic)
        let flags = PatternBalance.flags([PatternBalance.Day(name: "A", main: .horizontalPush, accessories: [.verticalPush]),
                                          PatternBalance.Day(name: "B", main: .verticalPush, accessories: [])])
        XCTAssertTrue(flags.contains { $0.contains("Pushing outweighs") })
    }
}

final class RepScreenTests: XCTestCase {
    /// Squat-like set: a 30 cm partial while settling, then 4 full reps of 50 cm, the third much faster.
    /// (Bumps under half the typical range are already dropped by the segmenter.)
    func testPartialLeftOutAndFastRepMarked() {
        let fps = 240.0
        var y: [Double] = []
        func hold(_ s: Double) { y += Array(repeating: y.last ?? 0, count: Int(s * fps)) }
        func move(_ d: Double, _ s: Double) {
            let y0 = y.last ?? 0, n = Int(s * fps)
            for i in 1...n { y.append(y0 + d * (1 - cos(Double.pi * Double(i) / Double(n))) / 2) }
        }
        hold(1); move(-0.30, 0.6); move(0.30, 0.6); hold(1)            // settling after the unrack
        for up in [0.8, 0.8, 0.5, 0.8] { move(-0.5, 1.0); move(0.5, up); hold(0.8) }
        let t = y.indices.map { Double($0) / fps }
        let kin = KinematicsBuilder.fromPosition(t: t, x: t.map { _ in 0 }, y: y, fps: fps, cutoffHz: 8)
        var reps = RepSegmenter.segment(kin, concentricFirst: false).map { EditableRep(detected: $0) }
        XCTAssertEqual(reps.count, 5)
        let r = RepScreen.screen(&reps, kinematics: kin)
        XCTAssertEqual(r.excluded, 1)
        XCTAssertTrue(reps[0].deleted)
        XCTAssertEqual(r.flagged, 1)
        XCTAssertTrue(reps[3].flag?.hasPrefix("Unusually fast") ?? false)
        XCTAssertFalse(reps[3].deleted)
    }
}

final class LiveRepTests: XCTestCase {
    /// A squat-like set with slowing reps, fed at an irregular ~150 frames a second.
    private func makeSet(upTimes: [Double], pause: Double = 0.8, end: Double = 1) -> (t: [Double], yPx: [Double]) {
        let fps = 240.0
        var y: [Double] = []
        func hold(_ s: Double) { y += Array(repeating: y.last ?? 0, count: Int(s * fps)) }
        func move(_ d: Double, _ s: Double) {
            let y0 = y.last ?? 0, n = Int(s * fps)
            for i in 1...n { y.append(y0 + d * (1 - cos(Double.pi * Double(i) / Double(n))) / 2) }
        }
        hold(1)
        for up in upTimes { move(-0.5, 1.0); move(0.5, up); hold(pause) }
        hold(end)
        let mpp = 0.45 / 200
        var t: [Double] = [], yPx: [Double] = []
        var rng = SystemRandomNumberGenerator()
        var i = 0
        while i < y.count {
            t.append(Double(i) / fps); yPx.append(1000 - y[i] / mpp)
            i += Int.random(in: 1...2, using: &rng)   // irregular: the phone skips frames when busy
        }
        return (t, yPx)
    }

    func testLiveMatchesAfterSetAndStopsAtCutoff() throws {
        let ups = [0.70, 0.72, 0.78, 0.85, 0.95]       // mean velocity falls about 26% by rep 5
        let s = makeSet(upTimes: ups)
        let live = LiveRepCounter(lossCutoffPct: 20, repCap: nil)
        var events: [LiveRepCounter.RepEvent] = []
        for k in s.t.indices { events += live.add(time: s.t[k], yPixels: s.yPx[k], radiusPx: 100) }
        XCTAssertEqual(events.count, 5)
        // The after-set engine on the same frames.
        let track = Track(fps: 150, t: s.t, x: s.t.map { _ in 540 }, y: s.yPx, r: s.t.map { _ in 100 },
                          roundness: 1, frameWidth: 1080, frameHeight: 1920)
        let ex = ExerciseCatalog.exercise(id: "back_squat")!
        let a = try SetAnalyzer.analyze(track: track, input: SetInput(exercise: ex, loadKg: 100), settings: .init())
        let after = try XCTUnwrap(a.setMetrics).reps.map(\.meanVelocity)
        XCTAssertEqual(after.count, 5)
        print("LIVEvsAFTER", zip(events.map(\.meanVelocity), after).map { String(format: "%.3f/%.3f", $0, $1) })
        for (l, r) in zip(events.map(\.meanVelocity), after) { XCTAssertEqual(l, r, accuracy: 0.02) }
        let stopAt = try XCTUnwrap(events.firstIndex { $0.stop != nil })
        XCTAssertEqual(events[stopAt].stop, .lossCutoff(20))
        XCTAssertGreaterThanOrEqual(events[stopAt].lossPct, 20)
        XCTAssertLessThan(events[stopAt - 1].lossPct, 20)
    }

    func testBounceIsNotTheReference() {
        let s = makeSet(upTimes: [0.8, 0.8, 0.8, 0.5, 0.8])   // rep 4 much faster
        let live = LiveRepCounter(lossCutoffPct: 20, repCap: 3)
        var events: [LiveRepCounter.RepEvent] = []
        for k in s.t.indices { events += live.add(time: s.t[k], yPixels: s.yPx[k], radiusPx: 100) }
        XCTAssertEqual(events.count, 5)
        XCTAssertTrue(events[3].likelyBounce)
        XCTAssertEqual(events[4].lossPct, 0, accuracy: 3)   // compared with reps 1-3, not the bounce
        XCTAssertEqual(events[2].stop, .repCap(3))
    }

    func testSettlesOnlyAfterStillnessAndNotBetweenReps() {
        // 2.5 s pauses between reps never end the set; 3 s of stillness after the last rep does.
        let s = makeSet(upTimes: [0.8, 0.8, 0.8], pause: 2.5, end: 4)
        let live = LiveRepCounter(lossCutoffPct: 20, repCap: 1, settleSeconds: 3)
        var settledAt: Double?
        var reps = 0
        for k in s.t.indices {
            reps += live.add(time: s.t[k], yPixels: s.yPx[k], radiusPx: 100).count
            if live.settled && settledAt == nil { settledAt = s.t[k]; XCTAssertEqual(reps, 3) }
        }
        let end = 1 + 3 * (1.0 + 0.8 + 2.5)   // when the last rep's lockout ends
        let at = try! XCTUnwrap(settledAt)
        XCTAssertGreaterThan(at, end - 2.5 + 3 - 0.3)
        XCTAssertLessThan(at, end - 2.5 + 3 + 0.5)
        // Off by default.
        let off = LiveRepCounter(lossCutoffPct: nil, repCap: nil)
        for k in s.t.indices { _ = off.add(time: s.t[k], yPixels: s.yPx[k], radiusPx: 100) }
        XCTAssertFalse(off.settled)
    }

    func testSettlesWhenPlateHiddenAfterLastRep() {
        // The plate goes out of view right after the last rep (racked behind an upright).
        let s = makeSet(upTimes: [0.8, 0.8], pause: 2.5, end: 0)
        let live = LiveRepCounter(lossCutoffPct: 20, repCap: nil, settleSeconds: 3)
        var reps = 0
        for k in s.t.indices { reps += live.add(time: s.t[k], yPixels: s.yPx[k], radiusPx: 100).count }
        XCTAssertEqual(reps, 2)
        let last = s.t.last!
        live.missing(time: last + 2)
        XCTAssertFalse(live.settled, "not before settleSeconds")
        live.missing(time: last + 3.1)
        XCTAssertTrue(live.settled)
        // Hidden before any rep: never ends the set.
        let early = LiveRepCounter(lossCutoffPct: 20, repCap: nil, settleSeconds: 3)
        _ = early.add(time: 0, yPixels: 500, radiusPx: 100)
        early.missing(time: 10)
        XCTAssertFalse(early.settled)
    }
}
