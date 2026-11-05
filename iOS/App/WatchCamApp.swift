import SwiftUI

@main
struct WatchCamApp: App {
    @State private var coordinator = RecordingCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .environment(coordinator)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    coordinator.scenePhaseChanged(phase)
                }
                .onChange(of: coordinator.settings.values) {
                    coordinator.settingsChanged()
                }
        }
    }
}
