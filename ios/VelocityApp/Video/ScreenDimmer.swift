import UIKit

/// Dims the screen while a set is recording, since it faces away from the athlete.
/// A tap brightens it for a few seconds; stopping restores the brightness the user had.
@MainActor
final class ScreenDimmer {
    private var saved: CGFloat?
    private var wakeTask: Task<Void, Never>?
    private let dimLevel: CGFloat = 0.02

    var isDimmed: Bool { saved != nil }

    func dim() {
        guard saved == nil else { return }
        saved = UIScreen.main.brightness
        UIScreen.main.brightness = dimLevel
    }

    /// Brighten for a moment (a tap on the screen), then dim again.
    func peek(seconds: Double = 5) {
        guard let s = saved else { return }
        UIScreen.main.brightness = s
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.saved != nil else { return }
            UIScreen.main.brightness = self.dimLevel
        }
    }

    func restore() {
        wakeTask?.cancel(); wakeTask = nil
        if let s = saved { UIScreen.main.brightness = s }
        saved = nil
    }
}
