import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: CameraSession
    @State private var draft = CameraSettings()
    @State private var portText = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section("Camera") {
                TextField("Address", text: $draft.host, prompt: Text("192.168.178.140"))
                TextField("Port", text: $portText, prompt: Text("9000"))
                TextField("Username", text: $draft.username)
                SecureField("Password", text: $draft.password)
            }
            Section("Pan / tilt") {
                Slider(value: $draft.ptzSpeed, in: 1...64, step: 1) {
                    Text("Speed: \(Int(draft.ptzSpeed))")
                }
                Text("32 is what the Reolink app uses.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(.bottom, 8)
        .onAppear {
            if !loaded {
                draft = session.settings
                portText = String(draft.port)
                loaded = true
            }
        }
    }

    private var isValid: Bool {
        !draft.host.trimmingCharacters(in: .whitespaces).isEmpty && !draft.username.isEmpty && !draft.password.isEmpty
            && (portText.isEmpty || UInt16(portText) != nil)
    }

    private func apply() {
        var s = draft
        s.host = s.host.trimmingCharacters(in: .whitespaces)
        s.port = UInt16(portText) ?? 9000
        session.applySettings(s)
    }
}
