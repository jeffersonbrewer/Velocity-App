import SwiftUI

/// The rest between sets as a slim bar that never blocks the screen. Tap it for +30 s and Skip.
struct RestTimerBar: View {
    @Environment(AppModel.self) private var model
    let now: Date
    var detail: String?
    @State private var expanded = false

    var body: some View {
        if let r = model.rest {
            let t = r.elapsed(now)
            let done = t >= r.doneAt
            let color = done ? Theme.good : (t >= r.doneAt - 30 ? Theme.warn : Theme.accent)
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: done ? "checkmark.circle.fill" : "timer")
                        Text("Rest \(clock(t))").monospacedDigit().fontWeight(.semibold)
                        Text(done ? "· ready" : "· \(range(r))").foregroundStyle(.white.opacity(0.75))
                        Spacer(minLength: 4)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rest \(Int(t) / 60) minutes \(Int(t) % 60) seconds, \(done ? "ready for the next set" : range(r))")
                .accessibilityHint("Shows +30 seconds and Skip")
                GeometryReader { geo in
                    Capsule().fill(.white.opacity(0.2))
                        .overlay(alignment: .leading) {
                            Capsule().fill(color).frame(width: geo.size.width * min(1, t / max(r.doneAt, 1)))
                        }
                }
                .frame(height: 4)
                if let detail { Text(detail).font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(2) }
                if expanded {
                    HStack {
                        Button("+30 s") { model.rest?.extraSec += 30 }
                            .buttonStyle(.bordered)
                        Button("Skip rest") { model.rest = nil; expanded = false }
                            .buttonStyle(.bordered)
                        Spacer()
                    }
                    .font(.subheadline)
                    .tint(.white)
                }
            }
            .padding(10)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func clock(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }

    private func range(_ r: RestTimerState) -> String {
        let lo = (r.lowSec + r.extraSec) / 60, hi = (r.highSec + r.extraSec) / 60
        return lo == hi ? "rest \(Fmt.load(lo)) min" : "rest \(Fmt.load(lo))–\(Fmt.load(hi)) min"
    }
}
