import SwiftUI

@main
struct ReolinkViewerApp: App {
    @StateObject private var session = CameraSession()

    var body: some Scene {
        WindowGroup("Reolink E1") {
            ContentView()
                .environmentObject(session)
        }
        .defaultSize(width: 1120, height: 660)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(session)
        }
    }
}
