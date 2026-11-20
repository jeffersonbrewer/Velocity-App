import SwiftUI
import VelocityCore

/// This week's sessions day by day, with done, planned and rest days. Tap a session to move it.
struct WeekScheduleCard: View {
    @Environment(AppModel.self) private var model
    @State private var planning = false
    @State private var moving: PlannedSession?
    @State private var calendarRefused = false
    @State private var added: String?

    var body: some View {
        if let program = model.program, !program.progress.retestDue {
            Card {
                if program.schedule == nil {
                    CardLabel(text: "Schedule")
                    Text("Pick your training days and usual times, and the app dates each session, keeps them spaced, and can put them in Calendar.")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                    Button { planning = true } label: {
                        Label("Plan my week", systemImage: "calendar").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    weekList(program)
                }
            }
            .sheet(isPresented: $planning) { PlanWeekView() }
            .sheet(item: $moving) { s in
                MoveSessionSheet(session: s) { date in Task { await model.move(s, to: date) } }
            }
            .alert("Calendar access is off", isPresented: $calendarRefused) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Turn it on in Settings › Privacy & Security › Calendars › Velocity, then try again.")
            }
        }
    }

    @ViewBuilder
    private func weekList(_ program: Program) -> some View {
        let cal = Calendar.current
        let start = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? cal.startOfDay(for: Date())
        let daysOfWeek = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        let upcoming = program.upcomingSessions()
        let thisWeek = upcoming.filter { s in s.date.map { $0 >= start && $0 < cal.date(byAdding: .day, value: 7, to: start)! } ?? false }

        HStack(alignment: .firstTextBaseline) {
            CardLabel(text: "This week")
            Spacer()
            Text("\(start.formatted(.dateTime.month(.abbreviated).day()))–\(daysOfWeek.last!.formatted(.dateTime.day()))")
                .font(.caption).foregroundStyle(Theme.muted)
            Button("Edit") { planning = true }.font(.caption.weight(.semibold))
        }
        ForEach(daysOfWeek, id: \.self) { date in
            let done = program.log.filter { cal.isDate($0.date, inSameDayAs: date) }
            let planned = thisWeek.filter { cal.isDate($0.date!, inSameDayAs: date) }
            if done.isEmpty && planned.isEmpty {
                HStack(spacing: 12) {
                    Text(date.formatted(.dateTime.weekday(.abbreviated).day())).frame(width: 64, alignment: .leading)
                    Text("Rest")
                }
                .font(.subheadline).foregroundStyle(Theme.muted)
                .frame(minHeight: 28)
            }
            ForEach(done) { log in
                sessionRow(date: date, day: program.days[safe: log.dayIndex], status: "Done", color: Theme.good)
            }
            ForEach(planned) { s in
                Button { moving = s } label: {
                    sessionRow(date: date, day: program.days[safe: s.dayIndex],
                               status: s.date!.formatted(date: .omitted, time: .shortened),
                               color: model.isInCalendar(s) ? Theme.good : Theme.accent,
                               icon: model.isInCalendar(s) ? "calendar.badge.checkmark" : nil)
                }
                .buttonStyle(.plain)
            }
        }
        Text("Tap a session to move it. Later sessions keep their order; the plan doesn't skip a session you miss, it moves it to your next training day.")
            .font(.caption).foregroundStyle(Theme.muted)
        HStack {
            Button {
                Task {
                    if !(await model.addToCalendar(thisWeek)) { calendarRefused = true } else { added = "This week is in Calendar." }
                }
            } label: { Text("Add this week to Calendar").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .disabled(thisWeek.isEmpty)
            Button {
                Task {
                    if !(await model.addToCalendar(upcoming)) { calendarRefused = true } else { added = "The rest of the block is in Calendar." }
                }
            } label: { Text("Whole block").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
                .disabled(upcoming.isEmpty)
        }
        .font(.subheadline)
        if let added { Label(added, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.good) }
    }

    private func sessionRow(date: Date, day: ProgramDay?, status: String, color: Color, icon: String? = nil) -> some View {
        HStack(spacing: 12) {
            Text(date.formatted(.dateTime.weekday(.abbreviated).day())).font(.subheadline.weight(.semibold))
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(day?.name ?? "Session").font(.subheadline.weight(.semibold))
                if let day {
                    Text("\(ExerciseCatalog.exercise(id: day.mainExerciseID)?.name ?? "") · \(day.goal.rawValue)")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            if let icon { Image(systemName: icon).foregroundStyle(color).font(.caption) }
            Pill(text: status, color: color)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}

/// Set up the training week: days, usual times, the spacing check, and Calendar.
struct PlanWeekView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var s = WeekSchedule()
    @State private var calendarRefused = false
    @State private var saving = false

    private let order = [2, 3, 4, 5, 6, 7, 1]   // Monday first

    var body: some View {
        NavigationStack {
            Form {
                let sessions = model.program?.days.count ?? 3
                Section {
                    HStack(spacing: 6) {
                        ForEach(order, id: \.self) { w in
                            let on = s.weekdays.contains(w)
                            Button {
                                if on { s.weekdays.removeAll { $0 == w } } else { s.weekdays.append(w) }
                            } label: {
                                Text(Calendar.current.veryShortWeekdaySymbols[w - 1])
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 38)
                                    .background(on ? Theme.accent : Theme.line, in: RoundedRectangle(cornerRadius: 8))
                                    .foregroundStyle(on ? Color.white : Theme.muted)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Calendar.current.weekdaySymbols[w - 1])
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    if s.weekdays.count != sessions {
                        Text("Your block has \(sessions) sessions a week. With \(s.weekdays.count) training days, \(s.weekdays.count < sessions ? "the week takes longer than 7 days" : "sessions just follow in order").")
                            .font(.caption).foregroundStyle(Theme.warn)
                    }
                    ForEach(spacingNotes(), id: \.self) { Text($0).font(.caption).foregroundStyle(Theme.warn) }
                } header: { Text("Training days") }

                Section("Usual time") {
                    DatePicker("Weekdays", selection: minutes($s.weekdayMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("Weekends", selection: minutes($s.weekendMinutes), displayedComponents: .hourAndMinute)
                    Stepper("Session length: \(s.sessionMinutes) min", value: $s.sessionMinutes, in: 30...180, step: 15)
                }

                Section {
                    Toggle("Keep sessions in Calendar", isOn: $s.syncCalendar)
                    Picker("Reminder", selection: $s.reminderMinutes) {
                        Text("None").tag(0)
                        Text("15 min before").tag(15)
                        Text("30 min before").tag(30)
                        Text("1 hour before").tag(60)
                        Text("2 hours before").tag(120)
                    }
                } header: { Text("Calendar") } footer: {
                    Text("Events go in your default calendar with the lift, expected load and target. Moving a session in the app, or missing one, moves its event.")
                }

                Section("This week") {
                    ForEach(preview()) { p in
                        HStack {
                            Text(p.date.map { $0.formatted(.dateTime.weekday(.abbreviated).day()) + " · " + $0.formatted(date: .omitted, time: .shortened) } ?? "–")
                            Spacer()
                            Text(model.program?.days[safe: p.dayIndex]?.name ?? "").foregroundStyle(Theme.muted)
                        }
                        .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Plan my week")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(s.syncCalendar ? "Save and add" : "Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(s.weekdays.isEmpty || saving)
                }
            }
            .onAppear { if let existing = model.program?.schedule { s = existing } }
            .alert("Calendar access is off", isPresented: $calendarRefused) {
                Button("OK", role: .cancel) { dismiss() }
            } message: {
                Text("Your week is saved. To add it to Calendar, turn on access in Settings › Privacy & Security › Calendars › Velocity.")
            }
        }
    }

    private func save() {
        saving = true
        model.program?.schedule = s
        // A new routine replaces earlier hand moves.
        model.program?.calendar.moved = [:]
        Task {
            if s.syncCalendar, !(await CalendarSync.shared.requestAccess()) {
                calendarRefused = true
                return
            }
            await model.syncCalendar(only: nil)
            dismiss()
        }
    }

    private func preview() -> [PlannedSession] {
        guard var p = model.program else { return [] }
        p.schedule = s
        p.calendar.moved = [:]
        return Array(p.upcomingSessions(limit: max(s.weekdays.count, 1)))
    }

    private func spacingNotes() -> [String] {
        guard let days = model.program?.days, !days.isEmpty else { return [] }
        let names = Calendar.current.weekdaySymbols
        let order = s.weekdays.sorted { (($0 + 5) % 7) < (($1 + 5) % 7) }   // Monday first
        var notes: [String] = []
        for (a, b) in s.backToBack {
            // Which sessions land on these days in a typical week (in order).
            guard let ia = order.firstIndex(of: a), let ib = order.firstIndex(of: b) else { continue }
            let la = days[ia % days.count].mainExerciseID, lb = days[ib % days.count].mainExerciseID
            if la == lb {
                notes.append("\(names[a - 1]) and \(names[b - 1]) are back to back with the same lift. Leave a day between them if you can.")
            } else {
                notes.append("\(names[a - 1]) and \(names[b - 1]) are back to back. Fine for different lifts.")
            }
        }
        return notes
    }

    private func minutes(_ m: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(m.wrappedValue) * 60) },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                m.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }
}
