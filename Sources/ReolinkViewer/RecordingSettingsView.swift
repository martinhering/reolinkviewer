import AppKit
import Baichuan
import Recording
import SwiftUI

/// The Recording tab: one set of settings for all cameras. Every change is saved at once and
/// passed on to the background recorder.
struct RecordingSettingsView: View {
    @EnvironmentObject private var store: CameraStore
    @State private var settings = RecordingSettings.load()
    @State private var agentStatus = RecorderAgent.statusText
    @State private var agentError: String?
    @State private var storage = StorageSettings.load()
    @State private var settingUpStorage = false

    var body: some View {
        Form {
            Section {
                Toggle("Record all cameras", isOn: $settings.enabled)
                DatePicker("Start", selection: time(\.startMinute, fallback: 22 * 60), displayedComponents: .hourAndMinute)
                DatePicker("Stop", selection: time(\.stopMinute, fallback: 6 * 60), displayedComponents: .hourAndMinute)
            } footer: {
                footnote(windowHint)
            }

            Section {
                Picker("Stream", selection: $settings.stream) {
                    Text("Clear").tag(StreamKind.main)
                    Text("Fluent").tag(StreamKind.sub)
                }
                Toggle("Sound", isOn: $settings.audio)
                Picker("Keep", selection: $settings.keep) {
                    Text("Motion only").tag(RecordingSettings.Keep.motionOnly)
                    Text("Everything").tag(RecordingSettings.Keep.everything)
                }
                Stepper("File length: \(settings.segmentLength) s", value: $settings.segmentLength, in: 10...600, step: 10)
                Stepper("Keep \(settings.paddingBefore) s before motion", value: $settings.paddingBefore, in: 0...120, step: 5)
                Stepper("Keep \(settings.paddingAfter) s after motion", value: $settings.paddingAfter, in: 0...120, step: 5)
            } footer: {
                footnote("A file is kept if motion, widened by these seconds, touches it. The camera's own motion detector decides what motion is.")
            }

            Section {
                Stepper("Keep files on this Mac for \(settings.localCacheDays) day\(settings.localCacheDays == 1 ? "" : "s")",
                        value: $settings.localCacheDays, in: 1...365)
                LabeledContent("Folder") {
                    Button("Show in Finder") { showFolder() }
                }
                LabeledContent("Log") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([RecorderLog.url]) }
                }
            }

            Section {
                if storage.isConfigured {
                    LabeledContent("Bucket", value: "\(storage.bucket) at \(storage.configuration?.endpoint.host ?? storage.endpoint)")
                    LabeledContent("Deleted there after", value: "\(storage.retentionDays) days")
                }
                LabeledContent(storage.isConfigured ? "Keys, retention, passphrase" : "Not set up") {
                    Button(storage.isConfigured ? "Set Up Again…" : "Set Up…") { settingUpStorage = true }
                }
            } header: {
                Text("Off-site storage")
            } footer: {
                footnote(storage.isConfigured
                         ? "Kept files are encrypted on this Mac and uploaded. The bucket deletes them when the retention period ends."
                         : "Without off-site storage the kept files stay on this Mac only, unencrypted.")
            }

            Section {
                footnote(agentStatus)
                if let agentError {
                    footnote(agentError).foregroundStyle(.red)
                }
                if RecorderAgent.isAvailable && RecorderAgent.isAdHocSigned {
                    footnote("This build is signed ad-hoc. The background recorder cannot read the camera passwords from the keychain after the next build; sign with a certificate (see build-app.sh).")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Background recorder")
            }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 680)
        .onChange(of: settings) { old, new in
            var saved = new
            // Switching on without a window would record nothing: take the times on display.
            if saved.enabled && !old.enabled {
                saved.startMinute = saved.startMinute ?? 22 * 60
                saved.stopMinute = saved.stopMinute ?? 6 * 60
            }
            if saved != new {
                settings = saved
                return  // the corrected value comes round again
            }
            saved.save()
            SettingsStore.notifyRecorder()
            if new.enabled != old.enabled { updateAgent() }
        }
        .sheet(isPresented: $settingUpStorage) {
            StorageSetupView {
                settingUpStorage = false
                storage = StorageSettings.load()
            }
        }
        .onAppear {
            storage = StorageSettings.load()
            settings = RecordingSettings.load()
            agentStatus = RecorderAgent.statusText
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var windowHint: String {
        guard let window = settings.window else {
            return "Choose a start and a stop time. The cameras are recorded every day between them."
        }
        if !settings.enabled { return "Recording is switched off." }
        let count = store.cameras.count
        let span = window.startMinute == window.stopMinute ? "around the clock"
            : window.startMinute < window.stopMinute ? "every day between these times" : "every night between these times"
        return "\(count == 1 ? "The camera is" : "All \(count) cameras are") recorded \(span), also while this app is closed. The Mac stays awake meanwhile."
    }

    /// A time of day as a `Date` for the picker, stored as minutes after midnight.
    private func time(_ keyPath: WritableKeyPath<RecordingSettings, Int?>, fallback: Int) -> Binding<Date> {
        Binding(
            get: {
                let minute = settings[keyPath: keyPath] ?? fallback
                return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                settings[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                // Choosing one time fixes the other as shown, so the window is complete.
                if settings.startMinute == nil { settings.startMinute = 22 * 60 }
                if settings.stopMinute == nil { settings.stopMinute = 6 * 60 }
            })
    }

    private func updateAgent() {
        agentError = nil
        if RecorderAgent.isAvailable {
            do {
                try RecorderAgent.setRegistered(settings.enabled)
            } catch {
                agentError = "The background recorder could not be \(settings.enabled ? "installed" : "removed"): \(error.localizedDescription)"
            }
        }
        agentStatus = RecorderAgent.statusText
    }

    private func showFolder() {
        let folder = RecordingStore.defaultDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
