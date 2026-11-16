import AVFoundation
import VelocityCore

/// Sound cues during a set: a short tone on each rep, a double tone for a likely bounce, and a
/// distinct falling three-tone "stop". Optionally speaks each rep's mean velocity. Plays alongside
/// any music (mixes rather than interrupting it).
final class LiveCuePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private let speech = AVSpeechSynthesizer()
    private var started = false

    func start() {
        guard !started else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do { try engine.start(); player.play(); started = true } catch { started = false }
    }

    func stop() {
        guard started else { return }
        player.stop(); engine.stop(); started = false
    }

    func rep(_ e: LiveRepCounter.RepEvent, speak: Bool) {
        if let _ = e.stop {
            play([(659, 0.16), (0, 0.05), (523, 0.16), (0, 0.05), (392, 0.30)])
        } else if e.likelyBounce {
            play([(988, 0.06), (0, 0.05), (988, 0.06)])
        } else {
            play([(880, 0.09)])
        }
        if speak {
            let u = AVSpeechUtterance(string: String(format: "%.2f", e.meanVelocity))
            u.rate = 0.55
            speech.speak(u)
        }
    }

    /// Play tones (frequency Hz, seconds); frequency 0 is silence.
    private func play(_ tones: [(Double, Double)]) {
        guard started else { return }
        let sr = format.sampleRate
        let frames = AVAudioFrameCount(tones.reduce(0) { $0 + $1.1 } * sr)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let ch = buf.floatChannelData?[0] else { return }
        var i = 0
        for (f, d) in tones {
            let n = Int(d * sr)
            for k in 0..<n {
                let env = min(1, Double(k) / 200, Double(n - k) / 200)   // short fade in/out, no clicks
                ch[i] = f > 0 ? Float(0.6 * env * sin(2 * .pi * f * Double(k) / sr)) : 0
                i += 1
            }
        }
        buf.frameLength = AVAudioFrameCount(i)
        player.scheduleBuffer(buf, completionHandler: nil)
    }
}
