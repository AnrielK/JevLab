import SwiftUI

@main
struct JevLabApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.jev)
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        #endif
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            LoopView()
                .tabItem { Label("Smyčka", systemImage: "waveform.path.ecg") }
            NewsroomView()
                .tabItem { Label("Newsroom", systemImage: "newspaper") }
            StrategyView()
                .tabItem { Label("Strategie", systemImage: "slider.horizontal.3") }
            SettingsView()
                .tabItem { Label("Nastavení", systemImage: "key") }
        }
        .onChange(of: model.strategy) {
            model.strategyChanged()
        }
    }
}
