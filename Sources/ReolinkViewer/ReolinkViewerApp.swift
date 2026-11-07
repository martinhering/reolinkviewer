import SwiftUI

@main
struct ReolinkViewerApp: App {
    @StateObject private var store = CameraStore()

    var body: some Scene {
        WindowGroup("Reolink Viewer") {
            ContentView()
                .environmentObject(store)
        }
        .defaultSize(width: 1120, height: 660)
        .windowResizability(.contentMinSize)
        // Left to macOS the toolbar starts compact and grows when the items change; keep it big.
        .windowToolbarStyle(.unified)
        .commands {
            CameraCommands(store: store)
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

/// The Camera menu: one entry per camera (⌘1 … ⌘9), the grid (⌘0), next/previous and reconnect.
struct CameraCommands: Commands {
    @ObservedObject var store: CameraStore

    var body: some Commands {
        CommandMenu("Camera") {
            ForEach(Array(store.cameras.prefix(9).enumerated()), id: \.element.id) { index, camera in
                Button(camera.displayName) { store.show(camera.id) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
            if store.cameras.count > 9 {
                ForEach(store.cameras.dropFirst(9)) { camera in
                    Button(camera.displayName) { store.show(camera.id) }
                }
            }
            if store.cameras.count > 1 {
                Button("All Cameras") { store.layout = .grid }
                    .keyboardShortcut("0")
                Divider()
                Button("Next Camera") { store.selectNext() }
                    .keyboardShortcut("]")
                Button("Previous Camera") { store.selectPrevious() }
                    .keyboardShortcut("[")
            }
            Divider()
            Button("Reconnect") { store.reconnect() }
                .keyboardShortcut("r")
                .disabled(store.cameras.isEmpty)
        }
    }
}
