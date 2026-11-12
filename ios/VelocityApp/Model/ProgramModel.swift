import Foundation
import VelocityCore

/// Today's main lift for the program, worked out from the plan and the lifter's profile.
struct SessionPlan {
    var day: ProgramDay
    var week: WeekPlan
    var oneRmKg: Double
    var readinessLoadKg: Double
    var readinessSet: AnalyzedSet?
    var readiness: Readiness?
    var readinessDelta: Double?
    var prescription: MainLiftPrescription
    /// Working sets of the main lift done today, oldest first (the readiness set left out).
    var setsDone: [AnalyzedSet]
    var nextLoadKg: Double
    var nextLoadReason: String?
    var doneReason: String?
    /// True when velocity targets come from recent sessions rather than a profile test.
    var lineLearned: Bool
}

extension AppModel {
    var unit: WeightUnit { WeightUnit(rawValue: UserDefaults.standard.string(forKey: SettingsKey.unit) ?? "lb") ?? .lb }

    /// The 1RM the program uses: the profile estimate or a hand-entered 1RM, whichever is newer.
    func programOneRm(_ exerciseID: String) -> (kg: Double, fromProfile: Bool)? {
        let prof = profile(for: exerciseID)
        let pr = prefs(for: exerciseID)
        switch (prof.oneRmKg, pr.knownOneRmKg) {
        case let (est?, known?):
            let testDate = prof.testDate ?? .distantPast
            return (pr.knownOneRmDate ?? .distantPast) > testDate ? (known, false) : (est, true)
        case let (est?, nil): return (est, true)
        case let (nil, known?): return (known, false)
        default: return nil
        }
    }

    /// The load-velocity line for velocity targets: the profile's, or for a hand-entered 1RM one
    /// learned from earlier sessions (today left out). Nil until there's enough to fit.
    func velocityLine(_ exerciseID: String) -> (line: LoadVelocityLine, learned: Bool)? {
        if let line = profile(for: exerciseID).line { return (line, false) }
        guard let orm = programOneRm(exerciseID)?.kg else { return nil }
        let pts = sets.compactMap { s -> LearnedLine.Point? in
            guard s.exerciseID == exerciseID, let m = s.analysis.setMetrics, m.repCount > 0 else { return nil }
            return LearnedLine.Point(date: s.date, loadKg: m.loadKg, bestMeanVelocity: m.bestMeanVelocity)
        }
        return LearnedLine.fit(pts, oneRmKg: orm, before: Date()).map { ($0, true) }
    }

    /// Why a main lift can't be programmed yet, or nil when it has a 1RM.
    func programBlocker(_ exerciseID: String) -> String? {
        let ex = ExerciseCatalog.exercise(id: exerciseID)
        if ex?.allowsOneRm == false { return "\(ex?.name ?? "This lift") can't be programmed by %1RM." }
        if programOneRm(exerciseID) == nil {
            return "Enter a known 1RM for \(ex?.name ?? "this lift"), or record a profile test: the plan turns %1RM into loads from it."
        }
        return nil
    }

    func setKnownOneRm(_ exerciseID: String, kg: Double?) {
        var p = prefs(for: exerciseID)
        p.knownOneRmKg = kg.flatMap { $0 > 0 ? $0 : nil }
        p.knownOneRmDate = p.knownOneRmKg == nil ? nil : Date()
        prefs[exerciseID] = p
    }

    /// The plan for today's session, or nil when there's no program or the profile isn't ready.
    func sessionPlan() -> SessionPlan? {
        guard let program, let day = program.currentDay else { return nil }
        let prof = profile(for: day.mainExerciseID)
        guard let orm = programOneRm(day.mainExerciseID)?.kg else { return nil }
        let vl = velocityLine(day.mainExerciseID)
        let line = vl?.line
        let u = unit
        let round = { (kg: Double) in u.roundedToStep(kg: kg) }
        let week = program.weekPlan(for: day)

        // Readiness from today's set nearest 60% 1RM (within ±10%).
        let target60 = round(0.60 * orm)
        let today = sets(on: Date()).filter { $0.exerciseID == day.mainExerciseID }.reversed()
        let rSet = today.first { s in
            guard let m = s.analysis.setMetrics, m.repCount > 0 else { return false }
            return abs(m.loadKg - target60) <= 0.10 * target60
        }
        var reading: Readiness?
        var delta: Double?
        if let m = rSet?.analysis.setMetrics, let line {
            let d = m.bestMeanVelocity - line.velocity(atLoad: m.loadKg)
            reading = Readiness(deltaMetersPerSecond: d); delta = d
        }
        _ = prof

        let p = Prescriber.mainLift(goal: day.goal, template: .default(day.goal), week: week, oneRmKg: orm, line: line,
                                    readiness: reading, round: round)
        // Working sets: today's sets of the main lift at or above 90% of the planned load.
        let done = today.filter { s in
            s.id != rSet?.id && s.setType == .working && (s.analysis.setMetrics?.repCount ?? 0) > 0 && s.analysis.input.loadKg >= 0.9 * p.minLoadKg
        }
        var next = p.loadKg
        var reason: String?
        if let last = done.last, let first = last.analysis.setMetrics?.reps.first?.meanVelocity {
            let r = Prescriber.nextLoad(after: last.analysis.input.loadKg, firstRepMV: first, prescription: p, stepKg: u.toKg(u.step))
            next = round(r.loadKg); reason = r.reason
        }
        let reps = done.compactMap { $0.analysis.setMetrics?.repCount }.reduce(0, +)
        return SessionPlan(day: day, week: week, oneRmKg: orm, readinessLoadKg: target60, readinessSet: rSet, readiness: reading,
                           readinessDelta: delta, prescription: p, setsDone: Array(done), nextLoadKg: next, nextLoadReason: reason,
                           doneReason: Prescriber.liftDone(setsDone: done.count, repsDone: reps, prescription: p),
                           lineLearned: vl?.learned ?? false)
    }

    /// Point the Today screen and camera at a load, with the session's loss cutoff and target zone.
    func prepareMainSet(_ plan: SessionPlan, loadKg: Double) {
        let id = plan.day.mainExerciseID
        currentExerciseID = id
        nextSetType = .working
        var p = prefs(for: id)
        p.loadKg = loadKg
        p.lossCutoffPct = plan.prescription.lossCutoffPct
        p.targetLow = plan.prescription.zoneLow.map { ($0 * 100).rounded() / 100 }
        p.targetHigh = plan.prescription.zoneHigh.map { ($0 * 100).rounded() / 100 }
        prefs[id] = p
    }

    /// Close today's session: advance the block, and set each accessory's next load from its reps and RIR.
    func finishSession(_ plan: SessionPlan, accessoryLog: [UUID: [AccessorySet]], loadsUsed: [UUID: Double]) {
        guard var program else { return }
        let dayIndex = program.progress.day
        program.log.append(ProgramSessionLog(date: Date(), week: program.progress.week, dayIndex: dayIndex,
                                             deload: plan.week.isDeload, reading: plan.readiness))
        let u = unit
        if let i = program.days.firstIndex(where: { $0.id == plan.day.id }) {
            program.days[i].accessories = program.days[i].accessories.map { a in
                var today = a
                if let used = loadsUsed[a.id] { today.loadKg = used }
                let step = max(a.stepKg, 0.1)
                let round = { (kg: Double) in u.toKg((u.fromKg(kg) / u.fromKg(step)).rounded() * u.fromKg(step)) }
                return today.next(after: accessoryLog[a.id] ?? [], round: round).plan
            }
        }
        program.progress.finishSession(reading: plan.readiness, weeks: program.weeks, daysPerWeek: program.days.count)
        self.program = program
    }

    /// Average change in 1RM that recent working sets imply, when it's large enough to suggest a retest.
    func profileDrift(_ exerciseID: String) -> Double? {
        let prof = profile(for: exerciseID)
        guard let line = velocityLine(exerciseID)?.line, let orm = programOneRm(exerciseID)?.kg, let mvt = prof.mvt else { return nil }
        let since = max(prof.lastTestDate ?? .distantPast, prefs(for: exerciseID).knownOneRmDate ?? .distantPast)
        let checks = sets.filter { $0.exerciseID == exerciseID && $0.setType == .working && $0.date > since }
            .compactMap { s -> ProfileDrift.Check? in
                guard let mv = s.analysis.setMetrics?.reps.first?.meanVelocity, s.analysis.input.loadKg >= 0.5 * orm else { return nil }
                return ProfileDrift.Check(date: s.date, loadKg: s.analysis.input.loadKg, firstRepMV: mv)
            }
        return ProfileDrift.retestSuggested(checks, line: line, mvt: mvt, oneRmKg: orm)
    }
}
