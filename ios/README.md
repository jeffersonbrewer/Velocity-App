# Velocity iPhone app

Milestone 1: pick a slow-motion set video, enter the exercise and load, and get set results
(reps, mean and peak velocity, bar and system power, distance, velocity loss). Peak velocity and
peak power are tagged **Beta** until they are validated against GymAware.

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
