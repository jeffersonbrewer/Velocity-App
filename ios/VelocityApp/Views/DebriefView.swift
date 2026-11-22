import Charts
import SwiftUI
import VelocityCore

/// After a program session: a plain-words summary over the numbers, then the next session and a
/// Calendar button.
struct DebriefView: View {
    let debriefID: UUID
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.unit) private var unitRaw = WeightUnit.lb.rawValue
    @State private var showSets = false
    @State private var scheduling: PlannedSession?
    @State private var calendarRefused = false
    @State private var refresh = 0

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .lb }

    var body: some View {
        Group {
            if let d = model.debriefs.first(where: { $0.id == debriefID }) {
                content(d)
            } else {
                ContentUnavailableView("Debrief not found", systemImage: "doc.text.magnifyingglass")
            }
        }
        .background(Theme.background)
        .navigationTitle("Session debrief")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $scheduling) { s in
            MoveSessionSheet(session: s, title: "Schedule next session") { date in
                Task {
                    await model.move(s, to: date)
                    var moved = s
                    moved.date = date
                    if !(await model.addToCalendar(moved)) { calendarRefused = true }
                    refresh += 1
                }
            }
        }
        .alert("Calendar access is off", isPresented: $calendarRefused) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Turn it on in Settings › Privacy & Security › Calendars › Velocity, then try again.")
        }
    }

    private func content(_ d: SessionDebrief) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Verdict
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(d.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) · \(d.dayName) · \(d.liftName) · Week \(d.week) of \(d.weeks)")
                        .font(.footnote).foregroundStyle(Theme.muted)
                    Text(DebriefText.verdict(d)).font(.title2.weight(.bold))
                    HStack(spacing: 8) {
                        if let r = d.readiness { Pill(text: "Readiness: \(r.rawValue)", color: readinessColor(r)) }
                        if d.mainSetCount > 0 { Pill(text: DebriefText.loadLabel(d), color: Theme.accent) }
                        if d.deload { Pill(text: "Deload", color: Theme.warn) }
                    }
                }
                if let event = d.event {
                    Card { Label(event, systemImage: "info.circle").font(.subheadline).foregroundStyle(Theme.warn) }
                }
                Card {
                    CardLabel(text: "How it went")
                    Text(DebriefText.howItWent(d, unit: unit)).font(.subheadline)
                }
                Card {
                    CardLabel(text: "What it means")
                    Text(DebriefText.whatItMeans(d, unit: unit)).font(.subheadline)
                }

                // The numbers
                CardLabel(text: "The numbers").padding(.top, 6)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                    tile("Readiness", d.readiness?.rawValue ?? "–",
                         d.readinessDelta.map { String(format: "%+.2f m/s vs profile", $0) } ?? (d.readinessLoadKg != nil ? "starts next session" : "no check today"),
                         d.readiness.map(readinessColor) ?? .primary)
                    tile("Best rep", d.bestMV.map { "\(Fmt.velocity($0)) m/s" } ?? "–",
                         d.bestMVChange.map { c in String(format: "%+.2f vs %@", c, d.compareDate?.formatted(.dateTime.month(.abbreviated).day()) ?? "") }
                            ?? d.bestMVLoadKg.map { "at \(unit.format(kg: $0)) \(unit.rawValue)" } ?? "")
                    tile("Avg loss", Fmt.percent(d.avgLossPct), "cutoff \(Fmt.percent(d.lossCutoffPct))")
                    tile("Reps", "\(d.totalReps) / \(d.repCap)", d.manual.isEmpty ? "session cap" : "session cap, incl. by hand")
                }

                Card {
                    HStack(alignment: .firstTextBaseline) {
                        CardLabel(text: "Estimated 1RM")
                        Spacer()
                        Text("\(unit.format(kg: d.oneRmKg)) \(unit.rawValue)").font(.subheadline.weight(.semibold))
                    }
                    let trend = model.oneRmTrend(d.exerciseID)
                    if trend.count >= 2 {
                        Chart(Array(trend.enumerated()), id: \.offset) { _, p in
                            LineMark(x: .value("Date", p.date), y: .value("1RM", unit.fromKg(p.kg)))
                                .foregroundStyle(Theme.accent)
                            PointMark(x: .value("Date", p.date), y: .value("1RM", unit.fromKg(p.kg)))
                                .foregroundStyle(Theme.accent).symbolSize(20)
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .chartXAxis(.hidden)
                        .frame(height: 70)
                        Text(trendNote(trend)).font(.caption).foregroundStyle(Theme.muted)
                    } else {
                        Text("The trend line starts after your next session of this lift.").font(.caption).foregroundStyle(Theme.muted)
                    }
                }

                Card {
                    HStack {
                        CardLabel(text: "Block")
                        Spacer()
                        Text("Week \(d.week) of \(d.weeks)").font(.caption).foregroundStyle(Theme.muted)
                    }
                    HStack(spacing: 6) {
                        ForEach(1...max(d.weeks, 1), id: \.self) { w in
                            Capsule().fill(w < d.week ? Theme.good : w == d.week ? Theme.accent : Theme.line).frame(height: 8)
                        }
                    }
                    Text(DebriefText.blockNote(d)).font(.caption).foregroundStyle(Theme.muted)
                }

                if !d.setIDs.isEmpty {
                    Button { withAnimation { showSets.toggle() } } label: {
                        Label(showSets ? "Hide sets" : "See set by set", systemImage: showSets ? "chevron.up" : "list.bullet")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    if showSets {
                        ForEach(d.setIDs.compactMap { model.set($0) }) { set in
                            NavigationLink(value: set.id) { SetRow(set: set, unit: unit, showDate: false) }.buttonStyle(.plain)
                        }
                    }
                }

                if let acc = d.accessories, !acc.isEmpty {
                    Card {
                        CardLabel(text: "Accessories next time")
                        ForEach(Array(acc.enumerated()), id: \.offset) { _, a in
                            let row = DebriefText.accessoryRow(a, unit: unit)
                            let color = changeColor(row.change)
                            Divider().overlay(Theme.line)
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(a.name).font(.subheadline.weight(.semibold))
                                    Text(row.today).font(.caption).foregroundStyle(Theme.muted)
                                }
                                Spacer(minLength: 4)
                                VStack(alignment: .trailing, spacing: 4) {
                                    Pill(text: changeSymbol(row.change) + row.tag, color: color)
                                    Text(row.next).font(.subheadline.weight(.semibold)).monospacedDigit()
                                        .foregroundStyle(row.change == .same || row.change == .notDone ? Color.primary : color)
                                }
                            }
                            .padding(.vertical, 2)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(a.name). Today \(row.today). Next time \(row.next), \(row.tag).")
                        }
                        Text("Loads come from your reps and reps in reserve: more in reserve than planned moves the load up, less moves it down.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }

                nextCard(d)

                Card {
                    CardLabel(text: "Recovery")
                    Text(DebriefText.recovery(d)).font(.subheadline).foregroundStyle(Theme.muted)
                }

                calendarButton(d)
            }
            .padding()
            .id(refresh)
        }
    }

    /// The next session as planned now (falls back to what was saved with the debrief).
    private func upcoming(_ d: SessionDebrief) -> PlannedSession? {
        guard let key = d.nextKey, let next = model.program?.nextSession, next.key == key else { return nil }
        return next
    }

    @ViewBuilder
    private func nextCard(_ d: SessionDebrief) -> some View {
        if let day = d.nextDayName, let ex = d.nextExerciseID {
            let when = upcoming(d)?.date.map { ", " + $0.formatted(.dateTime.weekday(.wide)) } ?? ""
            Card {
                CardLabel(text: "Next session · \(day)\(when)")
                row(ExerciseCatalog.exercise(id: ex)?.name ?? ex, d.nextGoal?.rawValue ?? "")
                if let l = d.nextLoadKg { row("Expected load", "\(unit.format(kg: l)) \(unit.rawValue)") }
                if let lo = d.nextZoneLow, let hi = d.nextZoneHigh { row("Target, first rep", "\(Fmt.velocity(lo))–\(Fmt.velocity(hi)) m/s") }
                if d.nextDeload == true {
                    Text("It's a deload session: lighter, fewer sets.").font(.caption).foregroundStyle(Theme.muted)
                }
                Text("The load is adjusted on the day from your warm-up.").font(.caption).foregroundStyle(Theme.muted)
            }
        } else if model.program?.progress.retestDue == true {
            Card {
                CardLabel(text: "Next")
                Text("The block is done. Retest each main lift from the Program tab.").font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private func calendarButton(_ d: SessionDebrief) -> some View {
        if let next = upcoming(d) {
            if let date = next.date, model.isInCalendar(next) {
                Label("\(date.formatted(.dateTime.weekday(.wide))), \(date.formatted(date: .omitted, time: .shortened)) · in Calendar",
                      systemImage: "calendar.badge.checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.good)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                Button("Change day or time") { scheduling = next }
                    .font(.subheadline).frame(maxWidth: .infinity)
            } else if let date = next.date {
                Button {
                    Task {
                        if !(await model.addToCalendar(next)) { calendarRefused = true }
                        refresh += 1
                    }
                } label: {
                    Label("Add \(date.formatted(.dateTime.weekday(.wide))) to Calendar", systemImage: "calendar.badge.plus")
                        .frame(maxWidth: .infinity).fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button { scheduling = suggested(next, after: d.date) } label: {
                    Label("Schedule next session", systemImage: "calendar.badge.plus").frame(maxWidth: .infinity).fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text("Or plan your whole week from the Program tab.").font(.caption).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// Two days later, at the same time of day as this session.
    private func suggested(_ s: PlannedSession, after date: Date) -> PlannedSession {
        var s = s
        s.date = Calendar.current.date(byAdding: .day, value: 2, to: date)
        return s
    }

    private func changeColor(_ c: DebriefText.Change) -> Color {
        switch c {
        case .up: return Theme.good
        case .down: return Theme.warn
        case .addLoad: return Theme.accent
        case .same, .notDone: return Theme.muted
        }
    }

    private func changeSymbol(_ c: DebriefText.Change) -> String {
        switch c {
        case .up, .addLoad: return "▲ "
        case .down: return "▼ "
        case .same, .notDone: return "= "
        }
    }

    private func trendNote(_ t: [(date: Date, kg: Double)]) -> String {
        guard let first = t.first?.kg, let last = t.last?.kg, first > 0 else { return "" }
        let change = (last - first) / first
        if abs(change) < 0.01 { return "Holding steady over the last \(t.count) sessions." }
        return String(format: "%@ %.0f%% over the last %d sessions.", change > 0 ? "Up" : "Down", abs(change) * 100, t.count)
    }

    private func tile(_ label: String, _ value: String, _ sub: String, _ color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Theme.muted)
            Text(value).font(.title3.weight(.bold)).foregroundStyle(color).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.caption2).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(Theme.muted); Spacer(); Text(value).monospacedDigit() }.font(.subheadline)
    }
}

/// Pick a day and time for one session.
struct MoveSessionSheet: View {
    let session: PlannedSession
    var title = "Move session"
    let onSave: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Day and time", selection: $date, in: Calendar.current.startOfDay(for: Date())...,
                           displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(date); dismiss() }.fontWeight(.semibold)
                }
            }
            .onAppear { date = session.date ?? Calendar.current.date(byAdding: .day, value: 2, to: Date())! }
        }
        .presentationDetents([.large])
    }
}
