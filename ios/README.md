# Velocity iPhone app

Record a set at 240 fps with a live plate and level check, or pick a slow-motion video you
already have, and get set results (reps, mean and peak velocity, bar and system power, distance,
velocity loss). Peak velocity and peak power are tagged **Beta** until they are validated against
GymAware.

- Milestone 1 (done): analyze a recorded video from Photos or Files.
- Milestone 2: **Open camera** on the start screen. The chips on the preview show whether the
  plate is found (green ring), whether the phone is level, and the frame rate. Press the red
  button to record, press it again to stop; the set is analyzed straight away and the video is
  deleted unless Settings › Save set videos to Photos is on.
- Milestone 3: sets are saved on the phone. **Today** shows the exercise chips (each exercise
  remembers its load, target zone and loss cutoff), the next set and the sets done today.
  **History** lists exercises (best mean velocity at a chosen load over time) and sessions by day.
  Sets are stored as plate tracks, not videos, so they take little space.
- Milestone 4: **Strength profile** (History › exercise › Open profile, or the card on Today).
  Tag a ramp of 4–6 loads as **Profile test** (the set type on Today stays until you change it)
  and optionally a heavy single as **Max single**. The profile draws the load–velocity line from
  the latest test day, estimates 1RM at your 1RM velocity (your slowest Max single, else the
  editable group default), checks readiness from today's first set, and suggests a retest after
  4 weeks. Working sets never change it. Retag an old set with the tag button on its results.
- **Guided profile test** (button on Today and on the profile): enter a rough 1RM and the app
  plans 4–6 loads from about 40% to 90% (3, 2, then 1 fast rep), plus an optional max single.
  The camera stays on for the whole ramp: after each load is analyzed it shows that load's best
  mean velocity, a rest timer, the next load, and the 1RM so far. Loads can be changed or skipped.
  After each load its reps show under the step chips: tap a rep to leave it out or bring it back
  (tap any earlier load's chip to review it, or Details for the full results); the test re-plans
  from the edited sets.
  From the second load on, the loads still to come are re-planned from the line so far: a lower
  1RM is taken at once (protects against an overestimated guess), a higher one cautiously.
- **Live cues while recording**: the plate is tracked during the set (up to 120 times a second)
  and each rep is counted as it finishes: a tone per rep, a double tone for a likely bounce, and a
  falling three-tone stop when velocity loss (vs the fastest rep so far, bounces excluded) reaches
  the cutoff or the rep cap is reached. Optional: say each rep's velocity (Settings). The screen
  shows the live rep, velocity and loss. The after-set analysis stays the record.
- **Rep screening** (every set): movements under 70% of the set's typical range (a step back,
  settling, a partial) are left out and marked; reps over 25% faster than the set's median
  (bounce?) or under 60% followed by faster reps (stall?) are kept but marked for review.
- Milestone 5: **Program** tab. Build a block (3–10 weeks, 1–4 sessions a week, each day a main
  lift, a goal and accessories); the last week is a deload followed by a profile test. Each
  session: record the 60% warm-up for readiness, then the app gives each set's load and target
  zone from your profile, moves the next load a step by the first rep (within ±5% of plan), and
  stops the lift at the set count or session rep cap. Two Down sessions in a row start a deload;
  accessories progress when every set reaches the top of the range. All numbers are the
  programming spec's draft values.
  A lift with a 1RM tested outside the app can be programmed by entering it as **Known 1RM** (block
  builder or profile); loads then come from it. Velocity targets are learned from the program's
  own sets (60% warm-up plus working sets, last 3 sessions) from the next session on, or come from
  a profile test. They never change the entered 1RM; a 5% drift suggests a profile test.
  Accessories come from a library of about 60 exercises (including combos) tagged by movement
  pattern. Suggestions put one on the main lift's pattern and fill the rest from the patterns the
  week covers least; the builder shows weekly pattern balance and flags gaps. Each accessory set
  logs reps and RIR (prefilled with the target); the next load is set from them (Epley with RIR,
  ±15% per session), with double progression as the fallback.

## Build plan (next)

Agreed 2026-11-19 from the first full gym session. Mockups:
https://claude.ai/artifact/7nwYwVKwbHSP7Pd1UyBGXS

1. **Auto rest timer.** Starts when auto-stop ends a set. A slim banner on the camera screen
   shows rest time, the rest range and the next set (load, stop rule), without taking over the
   screen; tap it for a full rest screen with +30 s and Skip. Audio (each switchable): the next
   load and rep goal at the start of rest, a 30-second warning, and a tone when rest is done.
2. **Session debrief** after Finish session: one scrolling screen. Top: a one-line verdict,
   readiness and load-change labels, "How it went" and "What it means" in plain words. Middle:
   readiness, best rep, average loss and reps tiles, the estimated 1RM trend and the block
   progress strip. Then a link to the set-by-set view, the next session and recovery notes.
3. **Calendar button** on the debrief: names the next planned session ("Add Monday to
   Calendar"); "Schedule next session" with a suggested day when none is planned; shows
   "Thursday, 6:00 AM · in Calendar" once added or when Calendar sync is on. The event carries
   the session, main lift and expected load, and updates when the session moves or is skipped.
4. **Weekly schedule**: set up with "Plan my week" (training days, usual times, spacing check,
   keep in Calendar with a reminder); the everyday view is the week list (drag to move, add the
   week or the whole block to Calendar).
5. Later: review the accessory exercises with Jefferson.

## Updating to a new version

Quit Xcode, rename your old `velocity-app` folder (for example to `velocity-app-old`), unzip the
new zip in its place, open `ios/VelocityApp.xcodeproj`, choose your Team again under Signing &
Capabilities, and press Run. Delete the old folder once the new one runs.

```
ios/
  VelocityApp.xcodeproj   Xcode project (open this)
  VelocityApp/            app screens, Photos/Files import, video frame reader
  VelocityCore/           measurement engine (Swift package; also builds and tests on Linux)
  validation/             check of the engine against the Python prototype and GymAware
```

## Put it on your iPhone (first time, about 30 minutes plus the Xcode download)

1. **Install Xcode** from the Mac App Store (free). It's a large download (allow 40 GB of free
   space). Open it once and let it install its extra components. When it asks which platforms
   to download, choose iOS.
2. **Get the code.** Download `velocity-app-ios.zip` from the project files, double-click it
   to unzip, and move the `velocity-app` folder somewhere you'll keep it, such as Documents.
3. **Open the project.** Double-click `velocity-app/ios/VelocityApp.xcodeproj`. Xcode takes a
   minute to index the files.
4. **Sign in.** Xcode menu › Settings › Accounts › **+** › Apple ID, and sign in with your normal
   Apple ID. A free account works.
5. **Pick your team.** In the left sidebar click the blue **VelocityApp** project icon, select the
   **VelocityApp** target, open **Signing & Capabilities**, and choose your name (Personal Team) in
   **Team**. If Xcode says the bundle identifier is not available, change
   `com.jeffersonbrewer.velocity` to something unique, such as `com.jeffersonbrewer.velocity2`.
6. **Prepare the iPhone.** Plug it into the Mac with a cable and tap **Trust** on the phone. Then
   on the phone: Settings › Privacy & Security › **Developer Mode** › On, and restart when asked.
   (The Developer Mode switch only appears after the phone has been connected to Xcode once.)
7. **Run.** At the top of the Xcode window, choose your iPhone in the device menu, then press the
   **▶ Run** button. The first build takes a few minutes.
8. **Trust the app** the first time: on the phone, Settings › General › VPN & Device Management ›
   your Apple ID › Trust.

With a free Apple ID the app stops opening after 7 days; press Run in Xcode again to renew it.
The paid Apple Developer Program ($99 a year) removes that limit and allows TestFlight.

## First test

Your trap bar originals are still in Photos on the phone. In the app, tap **Choose from Photos**,
pick the 95 lb set (IMG_0563), choose **Trap bar deadlift**, enter **95 lb**, and tap **Analyze set**.
Expected mean velocities from the same engine on Linux: **0.74, 0.91, 0.92, 0.92, 0.88 m/s**
(GymAware: 0.75, 0.95, 0.98, 0.94, 0.94). The iPhone decodes video slightly differently, so expect differences of about ±0.01 m/s. Tap the share button on the results to export the reps
as CSV.

The app asks for photo library access because it needs the full-speed original of slow-motion
videos; the normal shared copy is slowed down to 30 fps and would give wrong velocities.

## Engine tests (any computer with Swift)

```
cd ios/VelocityCore
swift test
```
