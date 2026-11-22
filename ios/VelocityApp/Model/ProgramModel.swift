import Foundation
import VelocityCore

/// Today's main lift for the program, worked out from the plan and the lifter's profile.
struct SessionPlan {
    var day: ProgramDay
    /// The main lift this plan is for (the day's first, or a later one).
    var lift: MainLift
    var liftIndex: Int
    var week: WeekPlan
    var oneRmKg: Double
    var readinessLoadKg: Double
    var readinessSet: AnalyzedSet?
    var readiness: Readiness?
    var readinessDelta: Double?
    var prescription: MainLiftPrescription
    /// Working sets of the main lift done today, oldest first (the readiness set left out).
    var setsDone: [AnalyzedSet]
    /// Sets of the main lift logged by hand today (no velocity), oldest first.
    var manualDone: [ManualSet]
    /// Reps the camera missed, added by hand to today's filmed sets.
    var addedReps: Int
    /// Main-lift sets done today, filmed or by hand.
    var setCount: Int { setsDone.count + manualDone.count }
    var repCount: Int { setsDone.compactMap { $0.analysis.setMetrics?.repCount }.reduce(0, +) + manualDone.map(\.reps).reduce(0, +) + addedReps }
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
        if ex?.allowsOneRm == false, programOneRm(exerciseID) == nil {
            return "Enter your best \(ex?.name.lowercased() ?? "lift") as a known 1RM: the plan sets loads from it. Velocity can't estimate a 1RM for this lift."
        }
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

    /// Today's plan for each main lift that has a 1RM, in the day's order.
    func sessionPlans() -> [SessionPlan] {
        guard let program, let day = program.currentDay else { return [] }
        return day.lifts.enumerated().compactMap { i, lift in sessionPlan(day: day, lift: lift, index: i, program: program) }
    }

    /// The plan for one of today's lifts: the one named, else the one the camera is set up for, else the first.
    func sessionPlan(_ exerciseID: String? = nil) -> SessionPlan? {
        let all = sessionPlans()
        let id = exerciseID ?? sessionTargets?.exerciseID
        return all.first { $0.lift.exerciseID == id } ?? all.first
    }

    /// Readiness for the whole session (accessories, the block's Down count): the first lift that has a reading.
    func sessionReadiness(_ plans: [SessionPlan]) -> Readiness? { plans.lazy.compactMap(\.readiness).first }

    private func sessionPlan(day: ProgramDay, lift: MainLift, index: Int, program: Program) -> SessionPlan? {
        guard let orm = programOneRm(lift.exerciseID)?.kg else { return nil }
        let vl = velocityLine(lift.exerciseID)
        let line = vl?.line
        let u = unit
        let round = { (kg: Double) in u.roundedToStep(kg: kg) }
        let week = program.weekPlan(for: lift)

        // Readiness from today's set nearest 60% 1RM (within ±10%).
        let target60 = round(0.60 * orm)
        let today = sets(on: Date()).filter { $0.exerciseID == lift.exerciseID }.reversed()
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
        let p = Prescriber.mainLift(goal: lift.goal, template: lift.template, week: week, oneRmKg: orm, line: line,
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
        let todays = manualSets.filter { $0.exerciseID == lift.exerciseID && Calendar.current.isDateInToday($0.date) }
            .sorted { $0.date < $1.date }
        let manual = todays.filter { $0.addedToSetID == nil }
        let added = todays.filter { $0.addedToSetID != nil }.map(\.reps).reduce(0, +)
        // A set logged by hand after the last filmed one: keep its load (there's no velocity to adjust from).
        if let m = manual.last, m.date > (done.last?.date ?? .distantPast) {
            next = m.loadKg; reason = nil
        }
        let reps = done.compactMap { $0.analysis.setMetrics?.repCount }.reduce(0, +) + manual.map(\.reps).reduce(0, +) + added
        return SessionPlan(day: day, lift: lift, liftIndex: index, week: week, oneRmKg: orm, readinessLoadKg: target60, readinessSet: rSet, readiness: reading,
                           readinessDelta: delta, prescription: p, setsDone: Array(done), manualDone: manual, addedReps: added,
                           nextLoadKg: next, nextLoadReason: reason,
                           doneReason: Prescriber.liftDone(setsDone: done.count + manual.count, repsDone: reps, prescription: p),
                           lineLearned: vl?.learned ?? false)
    }

    /// Point the Today screen and camera at a load, with the session's loss cutoff and target zone.
    func prepareMainSet(_ plan: SessionPlan, loadKg: Double) {
        let id = plan.lift.exerciseID
        currentExerciseID = id
        nextSetType = .working
        var p = prefs(for: id)
        p.loadKg = loadKg
        nextSetRepCap = plan.prescription.repCapPerSet
        prefs[id] = p
        let lo = plan.prescription.zoneLow.map { ($0 * 100).rounded() / 100 }
        let hi = plan.prescription.zoneHigh.map { ($0 * 100).rounded() / 100 }
        sessionTargets = SessionTargets(exerciseID: id, lossCutoffPct: plan.prescription.lossCutoffPct,
                                        zone: lo.flatMap { l in hi.flatMap { h in l < h ? l...h : nil } },
                                        restLowMin: plan.prescription.restLowMin, restHighMin: plan.prescription.restHighMin)
    }

    /// Close today's session: advance the block, and set each accessory's next load from its reps and RIR.
    /// Returns the session's debrief.
    @discardableResult
    func finishSession(_ plans: [SessionPlan], accessoryLog: [UUID: [AccessorySet]], loadsUsed: [UUID: Double]) -> SessionDebrief? {
        guard var program, let plan = plans.first else { return nil }
        let readiness = sessionReadiness(plans)
        var debrief = makeDebrief(plan, accessoryLog: accessoryLog)
        let others = plans.dropFirst().map { makeDebrief($0, accessoryLog: [:]) }
        debrief.otherLifts = others.isEmpty ? nil : others
        let dayIndex = program.progress.day
        program.log.append(ProgramSessionLog(date: Date(), week: program.progress.week, dayIndex: dayIndex,
                                             deload: plan.week.isDeload, reading: readiness))
        let u = unit
        if let i = program.days.firstIndex(where: { $0.id == plan.day.id }) {
            var changes: [AccessoryChange] = []
            program.days[i].accessories = program.days[i].accessories.map { a in
                var today = a
                if let used = loadsUsed[a.id] { today.loadKg = used }
                let step = max(a.stepKg, 0.1)
                let round = { (kg: Double) in u.toKg((u.fromKg(kg) / u.fromKg(step)).rounded() * u.fromKg(step)) }
                let log = accessoryLog[a.id] ?? []
                let r = today.next(after: log, round: round)
                changes.append(AccessoryChange(name: a.name, usedKg: today.loadKg, nextKg: r.plan.loadKg, reps: log.map(\.reps),
                                               rirs: log.map { $0.rir ?? a.rir }, repLow: a.repLow, repHigh: a.repHigh,
                                               targetRIR: a.rir, setsPlanned: a.sets(for: readiness),
                                               eachHand: a.exercise?.equipment == .dumbbell, note: r.note))
                return r.plan
            }
            debrief.accessories = changes
        }
        program.progress.finishSession(reading: readiness, weeks: program.weeks, daysPerWeek: program.days.count)
        self.program = program
        addNext(to: &debrief)
        debriefs.insert(debrief, at: 0)
        Task { await syncCalendar(only: nil) }
        Task { @MainActor in _ = try? await self.backUp() }
        return debrief
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

    /// After a program set: what happens next, in plain words (readiness result or next load).
    func afterSetSummary(setID: UUID) -> (text: String, isWarmUp: Bool, done: Bool)? {
        guard sessionTargets != nil, let plan = sessionPlan() else { return nil }
        let nextLift = sessionPlans().first { $0.liftIndex > plan.liftIndex && $0.doneReason == nil }
        let u = unit
        let lb = { (kg: Double) in "\(u.format(kg: kg)) \(u.rawValue)" }
        let p = plan.prescription
        if plan.readinessSet?.id == setID {
            let diff = p.loadKg - p.plannedLoadKg
            let change: String
            if abs(u.fromKg(diff)) < u.step / 2 { change = "Today's load stays at \(lb(p.loadKg)), as planned." }
            else if diff < 0 { change = "Today's load drops \(lb(-diff)) to \(lb(p.loadKg))." }
            else { change = "Today's load goes up \(lb(diff)) to \(lb(p.loadKg))." }
            if let r = plan.readiness, let d = plan.readinessDelta {
                return (String(format: "Warm-up saved. Readiness: %@ (%+.2f m/s vs your profile). ", r.rawValue, d) + change, true, false)
            }
            return ("Warm-up saved as today's 60% set. Readiness starts next session, once your velocity targets are learned from today's sets. " + change, true, false)
        }
        if let done = plan.doneReason {
            if let n = nextLift { return ("\(done) Next lift: \(n.lift.name), \(n.lift.goal.rawValue.lowercased()). Start with its warm-up.", false, true) }
            return ("\(done) Log your accessories, then finish the session.", false, true)
        }
        var t = "Next set: \(lb(plan.nextLoadKg))"
        if let why = plan.nextLoadReason { t += ". " + why } else { t += "." }
        t += " Stop at \(Fmt.percent(p.lossCutoffPct)) loss or \(p.repCapPerSet) reps."
        return (t, false, false)
    }

    /// Start the rest timer after a set, with the program's rest range or 2–3 minutes.
    func startRest() {
        let lo = (sessionTargets?.restLowMin ?? 2) * 60, hi = (sessionTargets?.restHighMin ?? 3) * 60
        rest = RestTimerState(start: Date(), lowSec: lo, highSec: max(hi, lo))
    }

    /// Reps the camera missed in a filmed set, added by hand.
    func addedReps(to setID: UUID) -> Int {
        manualSets.filter { $0.addedToSetID == setID }.map(\.reps).reduce(0, +)
    }

    func setAddedReps(_ n: Int, to set: AnalyzedSet) {
        manualSets.removeAll { $0.addedToSetID == set.id }
        if n > 0 {
            manualSets.append(ManualSet(date: set.date, exerciseID: set.exerciseID, loadKg: set.analysis.input.loadKg,
                                        reps: n, rir: nil, addedToSetID: set.id))
        }
    }
}
