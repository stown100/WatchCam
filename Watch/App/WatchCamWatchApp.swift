import SwiftUI

@main
struct WatchCamWatchApp: App {
    @State private var model = WatchModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.isAppActive = phase == .active
        }
    }
}
