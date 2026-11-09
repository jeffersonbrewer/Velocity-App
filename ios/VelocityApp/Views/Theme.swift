import SwiftUI

/// Colors and small building blocks shared by the screens, following the app mockup.
enum Theme {
    static let background = Color(red: 0x0f / 255, green: 0x14 / 255, blue: 0x1a / 255)
    static let card = Color(red: 0x19 / 255, green: 0x21 / 255, blue: 0x2b / 255)
    static let line = Color(red: 0x2a / 255, green: 0x35 / 255, blue: 0x42 / 255)
    static let muted = Color(red: 0x8b / 255, green: 0x98 / 255, blue: 0xa7 / 255)
    static let accent = Color(red: 0x5b / 255, green: 0x9b / 255, blue: 0xff / 255)
    static let good = Color(red: 0x3f / 255, green: 0xbf / 255, blue: 0x7f / 255)
    static let warn = Color(red: 0xf0 / 255, green: 0xa6 / 255, blue: 0x3a / 255)
    static let bad = Color(red: 0xef / 255, green: 0x5a / 255, blue: 0x5a / 255)
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }
}

struct CardLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.muted)
    }
}

/// Marks a metric that has not been validated against GymAware yet.
struct BetaBadge: View {
    var body: some View {
        Text("BETA")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(Theme.warn)
            .overlay(Capsule().stroke(Theme.warn, lineWidth: 1))
            .accessibilityLabel("Beta")
    }
}

/// Explains what Beta means, shown wherever peak values appear.
struct BetaNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            BetaBadge()
            Text("Peak velocity and peak power are still being checked against GymAware. So far peak velocity reads about 10–15% high and peak power is not reliable. Use mean velocity for training decisions.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
    }
}
