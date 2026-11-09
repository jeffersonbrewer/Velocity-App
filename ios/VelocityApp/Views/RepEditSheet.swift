import Charts
import SwiftUI
import VelocityCore

/// Adjust where a rep's lift starts and ends, or delete/restore the rep. Set totals recompute.
struct RepEditSheet: View {
    let analysis: SetAnalysis
    let onSave: (EditableRep) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rep: EditableRep
    @State private var start: Double
    @State private var end: Double
    private let window: ClosedRange<Int>

    init(analysis: SetAnalysis, rep: EditableRep, onSave: @escaping (EditableRep) -> Void) {
        self.analysis = analysis
        self.onSave = onSave
        _rep = State(initialValue: rep)
        let con = rep.effective.concentric
        _start = State(initialValue: Double(con.start))
        _end = State(initialValue: Double(con.end))
        // Show half a second either side of the detected lift.
        let pad = Int(analysis.kinematics.fps * 0.5)
        let n = analysis.kinematics.v.count
        let lo = max(0, min(con.start, rep.detected.concentric.start) - pad)
        let hi = min(n - 1, max(con.end, rep.detected.concentric.end) + pad)
        window = lo...max(hi, lo + 2)
    }

    private var phase: Phase { Phase(start: Int(start), end: max(Int(end), Int(start) + 1)) }

    private var preview: RepMetrics {
        MetricsCalculator.repMetrics(analysis.kinematics,
                                     rep: Rep(number: rep.detected.number, concentric: phase, eccentric: rep.detected.eccentric),
                                     loadKg: analysis.input.loadKg, bodyMassKg: nil, bodyMassFraction: 0)
    }

    var body: some View {
        let kin = analysis.kinematics
        let fps = kin.fps
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Chart {
                    RectangleMark(xStart: .value("Start", Double(phase.start) / fps),
                                  xEnd: .value("End", Double(phase.end) / fps))
                        .foregroundStyle(Theme.accent.opacity(0.18))
                    ForEach(Array(stride(from: window.lowerBound, through: window.upperBound, by: 2)), id: \.self) { i in
                        LineMark(x: .value("s", Double(i) / fps), y: .value("m/s", kin.v[i]))
                            .foregroundStyle(Theme.accent)
                    }
                    RuleMark(y: .value("zero", 0)).foregroundStyle(Theme.line)
                }
                .chartXAxisLabel("seconds")
                .chartYAxisLabel("m/s")
                .frame(height: 160)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Start").font(.caption).foregroundStyle(Theme.muted)
                    Slider(value: $start, in: Double(window.lowerBound)...Double(window.upperBound - 1), step: 1)
                        .onChange(of: start) { _, v in if v >= end { end = min(v + 1, Double(window.upperBound)) } }
                    Text("End").font(.caption).foregroundStyle(Theme.muted)
                    Slider(value: $end, in: Double(window.lowerBound + 1)...Double(window.upperBound), step: 1)
                        .onChange(of: end) { _, v in if v <= start { start = max(v - 1, Double(window.lowerBound)) } }
                }

                HStack {
                    stat(Fmt.velocity(preview.meanVelocity), "Mean m/s", beta: false)
                    stat(Fmt.velocity(preview.peakVelocity), "Peak m/s", beta: true)
                    stat(Fmt.meters(preview.concentricDistance), "Up m", beta: false)
                }

                HStack {
                    Button(rep.deleted ? "Restore rep" : "Delete rep", role: rep.deleted ? nil : .destructive) {
                        rep.deleted.toggle()
                        onSave(rep)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    Button("Reset") {
                        start = Double(rep.detected.concentric.start)
                        end = Double(rep.detected.concentric.end)
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("Save") {
                        let p = phase
                        rep.adjustedConcentric = p == rep.detected.concentric ? nil : p
                        onSave(rep)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .background(Theme.background)
            .navigationTitle("Rep \(rep.detected.number)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func stat(_ value: String, _ label: String, beta: Bool) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.bold)).monospacedDigit()
            HStack(spacing: 4) {
                Text(label).font(.caption).foregroundStyle(Theme.muted)
                if beta { BetaBadge() }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
