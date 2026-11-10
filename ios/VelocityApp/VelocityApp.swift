import SwiftUI

@main
struct VelocityApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "waveform.path.ecg") }
            HistoryView()
                .tabItem { Label("History", systemImage: "chart.line.uptrend.xyaxis") }
            SettingsView(showsDone: false)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
