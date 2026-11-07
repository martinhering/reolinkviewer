import Baichuan
import SwiftUI

/// Camera list on the left, the selected camera's details on the right. Nothing is saved
/// until Apply.
struct SettingsView: View {
    @EnvironmentObject private var store: CameraStore
    @State private var draft: [CameraSettings] = []
    @State private var selection: UUID?
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                cameraList
                    .frame(width: 200)
                Divider()
                if let selection, draft.contains(where: { $0.id == selection }) {
                    CameraForm(camera: binding(for: selection)) { newPassword in
                        // The camera already has the new password: store it right away so the
                        // running session reconnects with it, and keep the draft in step.
                        binding(for: selection).wrappedValue.password = newPassword
                        store.passwordChanged(on: selection, to: newPassword)
                    }
                } else {
                    Text(draft.isEmpty ? "Click + to add a camera." : "Select a camera.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Text(validationHint).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || !isDirty)
            }
            .padding(12)
        }
        .frame(width: 640, height: 420)
        .onAppear {
            if !loaded {
                draft = store.cameras
                selection = store.selectedID ?? draft.first?.id
                loaded = true
            }
        }
    }

    private var cameraList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(draft) { camera in
                    Label(camera.displayName, systemImage: "video")
                        .tag(camera.id)
                }
                .onMove { from, to in draft.move(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 0) {
                Button { add() } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                    .help("Add a camera")
                Divider().frame(height: 16)
                Button { remove() } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                    .disabled(selection == nil)
                    .help("Remove the selected camera")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(4)
        }
    }

    private func binding(for id: UUID) -> Binding<CameraSettings> {
        Binding(
            get: { draft.first { $0.id == id } ?? CameraSettings() },
            set: { new in
                if let i = draft.firstIndex(where: { $0.id == id }) { draft[i] = new }
            })
    }

    private func add() {
        var camera = CameraSettings()
        camera.name = "Camera \(draft.count + 1)"
        if let template = draft.first { camera.username = template.username }
        draft.append(camera)
        selection = camera.id
    }

    private func remove() {
        guard let selection, let i = draft.firstIndex(where: { $0.id == selection }) else { return }
        draft.remove(at: i)
        self.selection = draft.indices.contains(i) ? draft[i].id : draft.last?.id
    }

    private var trimmed: [CameraSettings] {
        draft.map { camera in
            var c = camera
            c.name = c.name.trimmingCharacters(in: .whitespaces)
            c.host = c.host.trimmingCharacters(in: .whitespaces)
            return c
        }
    }

    private var isValid: Bool { trimmed.allSatisfy(\.isComplete) }
    private var isDirty: Bool { trimmed != store.cameras }

    private var validationHint: String {
        let incomplete = trimmed.filter { !$0.isComplete }
        if incomplete.isEmpty { return "" }
        return "Address and username are needed for \(incomplete.map(\.displayName).joined(separator: ", "))."
    }

    private func apply() {
        draft = trimmed
        store.apply(draft)
    }
}

struct CameraForm: View {
    @Binding var camera: CameraSettings
    /// Called after the camera accepted a new password.
    let onPasswordChanged: (String) -> Void
    @State private var changingPassword = false

    var body: some View {
        Form {
            Section("Camera") {
                TextField("Name", text: $camera.name, prompt: Text("Living room"))
                TextField("Address", text: $camera.host, prompt: Text("192.168.1.20"))
                TextField("Port", value: $camera.port, format: .number.grouping(.never), prompt: Text("9000"))
                TextField("Username", text: $camera.username)
                SecureField("Password", text: $camera.password, prompt: Text("empty for a camera not yet set up"))
                HStack {
                    Text(camera.password.isEmpty ? "This camera has no password yet." : "Change the password stored on the camera.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(camera.password.isEmpty ? "Set Password on Camera…" : "Change Password on Camera…") {
                        changingPassword = true
                    }
                    .disabled(camera.host.trimmingCharacters(in: .whitespaces).isEmpty || camera.username.isEmpty)
                }
            }
            Section("Pan / tilt") {
                Slider(value: $camera.ptzSpeed, in: 1...64, step: 1) {
                    Text("Speed: \(Int(camera.ptzSpeed))")
                }
                Text("32 is what the Reolink app uses.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $changingPassword) {
            ChangePasswordSheet(camera: camera) { newPassword in
                changingPassword = false
                onPasswordChanged(newPassword)
            } onCancel: {
                changingPassword = false
            }
        }
    }
}

/// Logs in with the form's current credentials, changes the password on the camera (Baichuan
/// messages 58 and 59), and checks that the new one works before reporting success.
struct ChangePasswordSheet: View {
    let camera: CameraSettings
    let onDone: (String) -> Void
    let onCancel: () -> Void

    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(camera.password.isEmpty ? "Set Password" : "Change Password").font(.headline)
            Text("For \(camera.username) on \(camera.displayName) (\(camera.host)). The camera keeps running; the app reconnects with the new password.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                SecureField("New password", text: $newPassword)
                SecureField("Confirm", text: $confirmation)
            }
            .disabled(working)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !confirmation.isEmpty && newPassword != confirmation {
                Text("The passwords do not match.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button(camera.password.isEmpty ? "Set Password" : "Change Password") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || newPassword.isEmpty || newPassword != confirmation)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func submit() {
        working = true
        error = nil
        let camera = camera
        let host = camera.host.trimmingCharacters(in: .whitespaces)
        let newPassword = newPassword
        Task {
            do {
                let session = BaichuanCamera(host: host, port: camera.port, username: camera.username, password: camera.password)
                try await session.connect()
                do {
                    try await session.changePassword(to: newPassword)
                } catch {
                    await session.disconnect()
                    throw error
                }
                await session.disconnect()
                let check = BaichuanCamera(host: host, port: camera.port, username: camera.username, password: newPassword)
                do {
                    try await check.connect()
                    await check.disconnect()
                } catch {
                    throw PasswordChangeError.unverified("\(error)")
                }
                working = false
                onDone(newPassword)
            } catch {
                working = false
                self.error = describe(error)
            }
        }
    }

    private func describe(_ error: Error) -> String {
        if case PasswordChangeError.unverified(let why) = error {
            return "The camera took the request, but logging in with the new password failed (\(why)). The old password may still be in effect."
        }
        if case BCError.loginFailed = error {
            return "Could not log in with the current password. Check it in the form first."
        }
        return "\(error)"
    }
}

private enum PasswordChangeError: Error {
    case unverified(String)
}
