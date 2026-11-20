import EventKit
import Foundation
import VelocityCore

/// The lifter's usual training week: which days, at what time, and whether to keep sessions in Calendar.
struct WeekSchedule: Codable, Hashable {
    /// Calendar weekdays, 1 = Sunday … 7 = Saturday.
    var weekdays: [Int] = [2, 5, 7]
    var weekdayMinutes = 6 * 60      // start time on Monday–Friday, minutes after midnight
    var weekendMinutes = 9 * 60
    var sessionMinutes = 75
    var syncCalendar = false
    var reminderMinutes = 60         // 0: no reminder

    func startMinutes(onWeekday w: Int) -> Int { w == 1 || w == 7 ? weekendMinutes : weekdayMinutes }

    /// Back-to-back training days, for the spacing check.
    var backToBack: [(Int, Int)] {
        let d = weekdays.sorted()
        var out: [(Int, Int)] = []
        for (a, b) in zip(d, d.dropFirst()) where b - a == 1 { out.append((a, b)) }
        if let f = d.first, let l = d.last, f == 1, l == 7, d.count > 1 { out.append((7, 1)) }
        return out
    }
}

/// Hand-moved session times and the Calendar events the app made, by planned-session key.
struct SessionCalendar: Codable, Hashable {
    var moved: [String: Date] = [:]
    var eventIDs: [String: String] = [:]
}

/// A session still to come in the block, with its date when one is planned.
struct PlannedSession: Identifiable, Hashable {
    var key: String
    var week: Int
    var dayIndex: Int
    var date: Date?
    var id: String { key }
}

extension Program {
    /// Stable key for the n-th session of this block (counting finished ones).
    func sessionKey(ordinal: Int) -> String { "\(Int(startDate.timeIntervalSince1970))-\(ordinal)" }

    /// Sessions left in the block, in order, dated from the schedule (from today on) and any hand moves.
    func upcomingSessions(limit: Int = 60, now: Date = Date()) -> [PlannedSession] {
        guard !days.isEmpty, !progress.finished, !progress.retestDue else { return [] }
        let cal = Calendar.current
        var out: [PlannedSession] = []
        var week = progress.week, day = progress.day
        var i = 0
        while week <= weeks && out.count < limit {
            out.append(PlannedSession(key: sessionKey(ordinal: log.count + i), week: week, dayIndex: day, date: nil))
            i += 1; day += 1
            if day >= days.count { day = 0; week += 1 }
        }
        // Dates from the schedule: training days from today, or tomorrow when a session was already done today.
        if let schedule, !schedule.weekdays.isEmpty {
            var date = cal.startOfDay(for: now)
            if let last = log.last, cal.isDate(last.date, inSameDayAs: now) { date = cal.date(byAdding: .day, value: 1, to: date)! }
            var idx = 0
            var guardDays = 0
            while idx < out.count && guardDays < 800 {
                let w = cal.component(.weekday, from: date)
                if schedule.weekdays.contains(w) {
                    out[idx].date = cal.date(byAdding: .minute, value: schedule.startMinutes(onWeekday: w), to: date)
                    idx += 1
                }
                date = cal.date(byAdding: .day, value: 1, to: date)!
                guardDays += 1
            }
        }
        for j in out.indices { if let m = calendar.moved[out[j].key] { out[j].date = m } }
        return out
    }

    var nextSession: PlannedSession? { upcomingSessions(limit: 1).first }
}

extension AppModel {
    /// The main lift's expected load and first-rep zone for a future session (readiness not known yet).
    func preview(_ s: PlannedSession) -> (day: ProgramDay, prescription: MainLiftPrescription)? {
        guard let program, let day = program.days[safe: s.dayIndex], let orm = programOneRm(day.mainExerciseID)?.kg else { return nil }
        let plans = program.weekPlans(for: day)
        let week = (program.progress.inResponsiveDeload && s.week == program.progress.week)
            ? BlockPlanner.deload(for: .default(day.goal)) : plans[min(max(s.week - 1, 0), plans.count - 1)]
        let u = unit
        let p = Prescriber.mainLift(goal: day.goal, template: .default(day.goal), week: week, oneRmKg: orm,
                                    line: velocityLine(day.mainExerciseID)?.line, readiness: nil, round: { u.roundedToStep(kg: $0) })
        return (day, p)
    }

    /// Move one session to a new date and time, and update its Calendar event if it has one.
    @MainActor
    func move(_ s: PlannedSession, to date: Date) async {
        program?.calendar.moved[s.key] = date
        await syncCalendar(only: nil)
    }

    /// Put one session in Calendar (asking for access the first time). Returns false when access is refused.
    @MainActor
    @discardableResult
    func addToCalendar(_ s: PlannedSession) async -> Bool {
        guard s.date != nil else { return false }
        guard await CalendarSync.shared.requestAccess() else { return false }
        await upsert(s)
        return true
    }

    /// Add every remaining session of the block (or of this week only) to Calendar.
    @MainActor
    @discardableResult
    func addToCalendar(_ sessions: [PlannedSession]) async -> Bool {
        guard await CalendarSync.shared.requestAccess() else { return false }
        for s in sessions where s.date != nil { await upsert(s) }
        return true
    }

    /// Bring Calendar up to date: sessions that already have events move with the plan, and when
    /// "Keep sessions in Calendar" is on, every planned session gets one.
    @MainActor
    func syncCalendar(only keys: Set<String>?) async {
        guard let program else { return }
        let sync = program.schedule?.syncCalendar == true
        let all = program.calendar.eventIDs.isEmpty && !sync ? [] : program.upcomingSessions()
        let todo = all.filter { s in (keys?.contains(s.key) ?? true) && (sync || program.calendar.eventIDs[s.key] != nil) }
        guard !todo.isEmpty else { return }
        if !CalendarSync.shared.hasAccess {
            guard sync, await CalendarSync.shared.requestAccess() else { return }
        }
        for s in todo where s.date != nil { await upsert(s) }
    }

    @MainActor
    func isInCalendar(_ s: PlannedSession) -> Bool { program?.calendar.eventIDs[s.key] != nil && CalendarSync.shared.hasAccess }

    @MainActor
    private func upsert(_ s: PlannedSession) async {
        guard let date = s.date, let pv = preview(s) else { return }
        let day = pv.day, p = pv.prescription
        let u = unit
        let lift = ExerciseCatalog.exercise(id: day.mainExerciseID)?.name ?? day.mainExerciseID
        var notes = ["\(p.goal.rawValue) · week \(s.week) of \(program?.weeks ?? 6)\(p.week.isDeload ? " (deload)" : "")",
                     "Expected load: about \(u.format(kg: p.loadKg)) \(u.rawValue)"]
        if let lo = p.zoneLow, let hi = p.zoneHigh { notes.append("First-rep target: \(Fmt.velocity(lo))–\(Fmt.velocity(hi)) m/s") }
        if !day.accessories.isEmpty { notes.append("Accessories: " + day.accessories.map(\.name).joined(separator: ", ")) }
        notes.append("Planned by Velocity. Moving or skipping the session in the app updates this event.")
        let minutes = program?.schedule?.sessionMinutes ?? 75
        let reminder = program?.schedule?.reminderMinutes ?? 60
        let id = CalendarSync.shared.upsert(id: program?.calendar.eventIDs[s.key], title: "Velocity: \(day.name) · \(lift)",
                                            start: date, minutes: minutes, notes: notes.joined(separator: "\n"),
                                            reminderMinutes: reminder)
        if let id { program?.calendar.eventIDs[s.key] = id }
    }
}

/// Thin wrapper over EventKit.
@MainActor
final class CalendarSync {
    static let shared = CalendarSync()
    private let store = EKEventStore()

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func requestAccess() async -> Bool {
        if hasAccess { return true }
        let ok = (try? await store.requestFullAccessToEvents()) ?? false
        return ok
    }

    /// Create or update an event; returns its identifier.
    func upsert(id: String?, title: String, start: Date, minutes: Int, notes: String, reminderMinutes: Int) -> String? {
        guard hasAccess else { return nil }
        let event = id.flatMap { store.event(withIdentifier: $0) } ?? EKEvent(eventStore: store)
        if event.calendar == nil { event.calendar = store.defaultCalendarForNewEvents }
        guard event.calendar != nil else { return nil }
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(Double(minutes) * 60)
        event.notes = notes
        event.alarms = reminderMinutes > 0 ? [EKAlarm(relativeOffset: -Double(reminderMinutes) * 60)] : nil
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return event.eventIdentifier
        } catch {
            return nil
        }
    }
}
