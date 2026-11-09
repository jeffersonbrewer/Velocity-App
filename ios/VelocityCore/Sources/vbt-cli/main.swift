// Command-line checks of the Swift engine against the Python prototype.
//
//   vbt-cli track <frames.gray> <times.txt> <width> <height> <out.json>
//       Track the plate through raw 8-bit gray frames (as written by ffmpeg -pix_fmt gray -f rawvideo)
//       with one presentation time per line in times.txt. Writes the track as JSON.
//   vbt-cli analyze <track.json> <exercise_id> <load_kg> [body_mass_kg] [cutoff_hz]
//       Run kinematics, rep detection and metrics on a track JSON (from this tool or the prototype)
//       and print per-rep metrics as JSON.
import Foundation
import VelocityCore

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func jsonNum(_ v: Double?) -> String {
    guard let v, v.isFinite else { return "null" }
    return String(v)
}

func jsonArray(_ a: [Double]) -> String { "[" + a.map { jsonNum($0) }.joined(separator: ",") + "]" }

func loadTrack(_ path: String) -> Track {
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { fail("Cannot read \(path)") }
    func arr(_ k: String) -> [Double] { (obj[k] as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue ?? .nan } }
    let size = obj["frame_size"] as? [Int] ?? [0, 0]
    return Track(fps: (obj["fps"] as? NSNumber)?.doubleValue ?? 240, t: arr("t"), x: arr("x"), y: arr("y"), r: arr("r"),
                 roundness: (obj["roundness"] as? NSNumber)?.doubleValue ?? 1, frameWidth: size[0], frameHeight: size[1])
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: vbt-cli track|analyze ...") }

switch args[1] {
case "track":
    guard args.count == 7, let w = Int(args[4]), let h = Int(args[5]) else { fail("usage: vbt-cli track frames.gray times.txt w h out.json") }
    guard let fh = FileHandle(forReadingAtPath: args[2]) else { fail("Cannot open \(args[2])") }
    let times = (try? String(contentsOfFile: args[3], encoding: .utf8))?
        .split(separator: "\n").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? []
    let tracker = PlateTracker()
    tracker.alwaysTemplate = ProcessInfo.processInfo.environment["VBT_ALWAYS_TEMPLATE"] == "1"
    let start = Date()
    var i = 0
    while true {
        let data = fh.readData(ofLength: w * h)
        if data.count < w * h { break }
        let img = GrayImage(width: w, height: h, pixels: [UInt8](data))
        tracker.add(img, time: i < times.count ? times[i] : Double(i) / 240)
        i += 1
    }
    let secs = Date().timeIntervalSince(start)
    let tr = tracker.finish()
    let out = """
    {"fps": \(tr.fps), "frames": \(i), "secs": \(secs), "roundness": \(jsonNum(tr.roundness)),
     "frame_size": [\(tr.frameWidth), \(tr.frameHeight)],
     "t": \(jsonArray(tr.t)), "x": \(jsonArray(tr.x)), "y": \(jsonArray(tr.y)), "r": \(jsonArray(tr.r))}
    """
    try! out.write(toFile: args[6], atomically: true, encoding: .utf8)
    print("tracked \(i) frames in \(String(format: "%.1f", secs)) s, lost \(String(format: "%.1f", tr.lostFraction * 100))%")

case "analyze":
    guard args.count >= 5, let ex = ExerciseCatalog.exercise(id: args[3]), let load = Double(args[4]) else {
        fail("usage: vbt-cli analyze track.json exercise_id load_kg [body_mass_kg] [cutoff_hz]")
    }
    let bm = args.count > 5 ? Double(args[5]) : nil
    var settings = AnalysisSettings()
    if args.count > 6, let c = Double(args[6]) { settings.cutoffHz = c }
    let track = loadTrack(args[2])
    do {
        let a = try SetAnalyzer.analyze(track: track, input: SetInput(exercise: ex, loadKg: load, bodyMassKg: bm), settings: settings)
        let reps = a.repMetrics
        var rows: [String] = []
        for (r, m) in zip(a.reps, reps) {
            let e = r.detected.eccentric
            rows.append("""
            {"con": [\(r.detected.concentric.start), \(r.detected.concentric.end)], "ecc": \(e.map { "[\($0.start), \($0.end)]" } ?? "null"),
             "mean_velocity": \(jsonNum(m.meanVelocity)), "mean_propulsive_velocity": \(jsonNum(m.meanPropulsiveVelocity)),
             "peak_velocity": \(jsonNum(m.peakVelocity)), "mean_power": \(jsonNum(m.meanPower)), "peak_power": \(jsonNum(m.peakPower)),
             "concentric_distance": \(jsonNum(m.concentricDistance)), "eccentric_distance": \(jsonNum(m.eccentricDistance)),
             "system_mean_power": \(jsonNum(m.systemMeanPower)), "system_peak_power": \(jsonNum(m.systemPeakPower))}
            """)
        }
        print("{\"fps\": \(a.kinematics.fps), \"m_per_px\": \(a.kinematics.metersPerPixel), \"warnings\": \(a.warnings.count), \"reps\": [\(rows.joined(separator: ","))]}")
    } catch {
        fail("Analysis failed: \(error.localizedDescription)")
    }

case "detect":
    // vbt-cli detect frame.gray w h  -> prints the detected plate
    guard args.count == 5, let w = Int(args[3]), let h = Int(args[4]),
          let data = FileManager.default.contents(atPath: args[2]) else { fail("usage: vbt-cli detect frame.gray w h") }
    let img = GrayImage(width: w, height: h, pixels: [UInt8](data.prefix(w * h)))
    let c = PlateDetector.debugDetect(img)
    print(c.map { "plate x \($0.x) y \($0.y) r \($0.r) roundness \($0.roundness)" } ?? "no plate")

case "refine":
    // vbt-cli refine frame.gray w h x y r
    guard args.count == 8, let w = Int(args[3]), let h = Int(args[4]), let x = Double(args[5]), let y = Double(args[6]),
          let r = Double(args[7]), let data = FileManager.default.contents(atPath: args[2]) else { fail("usage") }
    let img = GrayImage(width: w, height: h, pixels: [UInt8](data.prefix(w * h)))
    let c = PlateDetector.debugRefine(img, x: x, y: y, r: r)
    print(c.map { "\($0.x) \($0.y) \($0.r)" } ?? "none")

default:
    fail("unknown command \(args[1])")
}
