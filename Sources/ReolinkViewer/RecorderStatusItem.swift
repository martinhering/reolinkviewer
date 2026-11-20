import AppKit
import Recording

/// The background recorder's icon in the menu bar: an outlined camera while it waits for the
/// recording period, a red one while it records. Its menu says what the recorder is doing.
@MainActor
final class RecorderStatusItem: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem?
    private var status = RecordingService.Status()
    private let headline = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let detail = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon. Set here as well: set before launch alone, it does not hold.
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        headline.isEnabled = false
        detail.isEnabled = false
        menu.addItem(headline)
        menu.addItem(detail)
        menu.addItem(.separator())
        for (title, action) in [("Open Reolink Viewer", #selector(openViewer)), ("Show Recorder Log", #selector(showLog))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        item.menu = menu
        self.item = item
        refresh()
    }

    /// The app was opened while only the recorder runs, and macOS handed the request to the
    /// recorder because it belongs to the same bundle: start the viewer.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openViewer()
        stayOutOfDock()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        stayOutOfDock()
    }

    /// Being opened like an app turns the recorder into one with a Dock icon; turn it back.
    private func stayOutOfDock() {
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.setActivationPolicy(.accessory) }
    }

    func show(_ status: RecordingService.Status) {
        self.status = status
        refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    private func refresh() {
        let settings = RecordingSettings.load()
        let text = Self.text(status: status, settings: settings)
        headline.title = text.headline
        detail.title = text.detail
        detail.isHidden = text.detail.isEmpty

        guard let button = item?.button else { return }
        let name = status.recording ? "video.fill" : "video"
        var image = NSImage(systemSymbolName: name, accessibilityDescription: text.headline)
        if status.recording {
            image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
        }
        image?.isTemplate = !status.recording
        button.image = image
        button.toolTip = "Reolink Viewer: \(text.headline)"
    }

    /// The two lines at the top of the menu.
    static func text(status: RecordingService.Status, settings: RecordingSettings) -> (headline: String, detail: String) {
        func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
        guard settings.enabled else { return ("Recording is switched off", "") }
        guard let window = settings.window else { return ("No recording times set", "") }
        let wholeDay = window.startMinute == window.stopMinute
        if status.recording {
            let count = status.cameras.count
            let headline = count == 0 ? "Recording" : "Recording \(count) camera\(count == 1 ? "" : "s")"
            return (wholeDay ? headline : "\(headline) until \(clock(window.stopMinute))", status.cameras.joined(separator: ", "))
        }
        return ("Waiting", "Records from \(clock(window.startMinute)) to \(clock(window.stopMinute))")
    }

    @objc private func openViewer() {
        let me = NSRunningApplication.current
        let viewer = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first { $0 != me && $0.activationPolicy == .regular }
        if let viewer {
            NSApp.yieldActivation(to: viewer)
            viewer.activate()
            return
        }
        // A new instance: without this macOS would only bring the recorder to the front.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, _ in
            DispatchQueue.main.async {
                guard let app else { return }
                NSApp.yieldActivation(to: app)
                app.activate()
            }
        }
    }

    @objc private func showLog() {
        NSWorkspace.shared.open(RecorderLog.url)
    }
}
