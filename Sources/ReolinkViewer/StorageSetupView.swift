import AppKit
import Recording
import SwiftUI

/// The storage setup sheet: bucket, keys, retention and passphrase, entered together.
/// Retention is fixed here because only the setup key, which is not stored, may change the
/// bucket's lifecycle rule; changing it later means running setup again.
struct StorageSetupView: View {
    let onDone: () -> Void
    @State private var input: StorageStore.SetupInput = {
        var input = StorageStore.SetupInput()
        input.settings = StorageSettings.load()
        return input
    }()
    @State private var running = false
    @State private var failure: String?
    @State private var result: StorageStore.SetupResult?
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            if let result {
                finished(result)
            } else {
                form
            }
        }
        .frame(width: 560)
    }

    private var form: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Endpoint", text: $input.settings.endpoint, prompt: Text("s3.eu-central-1.amazonaws.com"))
                    TextField("Region", text: $input.settings.region, prompt: Text("eu-central-1"))
                    TextField("Bucket", text: $input.settings.bucket)
                } header: {
                    Text("Bucket")
                } footer: {
                    note("Any S3-compatible service. The bucket must exist already.")
                }
                Section {
                    TextField("Key ID", text: $input.settings.uploadKeyID)
                    SecureField("Secret", text: $input.uploadSecret)
                } header: {
                    Text("Upload key")
                } footer: {
                    note("Stored in the keychain and used by the recorder. Give it the right to upload and nothing else, so a stolen Mac cannot delete recordings.")
                }
                Section {
                    TextField("Key ID", text: $input.setupKeyID)
                    SecureField("Secret", text: $input.setupSecret)
                } header: {
                    Text("Setup key")
                } footer: {
                    note("Used now and not stored. It must be able to read and write objects and to change the bucket's lifecycle rule.")
                }
                Section {
                    Stepper("Delete recordings after \(input.settings.retentionDays) days", value: $input.settings.retentionDays, in: 1...3650)
                    Toggle("Write the bucket's lifecycle rule", isOn: $input.writeLifecycleRule)
                } header: {
                    Text("Retention")
                } footer: {
                    note("The bucket deletes the recordings itself, also while this Mac is off. Writing the rule replaces the lifecycle rules the bucket has. To change the period later, run this setup again.")
                }
                Section {
                    SecureField("Passphrase", text: $input.passphrase, prompt: Text("Leave empty to generate one"))
                } header: {
                    Text("Encryption")
                } footer: {
                    note("Recordings are encrypted on this Mac before upload. For a bucket that already holds recordings, enter its passphrase.")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if running { ProgressView().controlSize(.small) }
                Text(failure ?? "").font(.caption).foregroundStyle(.red).lineLimit(4).textSelection(.enabled)
                Spacer()
                Button("Cancel") { onDone() }.keyboardShortcut(.cancelAction)
                Button("Set Up") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || !input.isComplete)
            }
            .padding(12)
        }
        .frame(height: 720)
    }

    private func finished(_ result: StorageStore.SetupResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Storage is set up", systemImage: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
            if let passphrase = result.generatedPassphrase {
                Text("This is the passphrase that protects your recordings. It is shown only now.")
                Text(passphrase)
                    .font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Text("Save it in a password manager. It is also in this Mac's keychain, but if this Mac is lost, the recordings in the bucket can only be opened with a second copy.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(copied ? "Copied" : "Copy Passphrase") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(passphrase, forType: .string)
                    copied = true
                }
            } else if result.joinedExistingBucket {
                Text("The passphrase opened the bucket's key file. New recordings join the ones already there.")
            } else {
                Text("The recordings are encrypted with your passphrase. Keep a second copy of it outside this Mac.")
            }
            HStack {
                Spacer()
                Button("Done") { onDone() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func run() {
        running = true
        failure = nil
        var input = self.input
        input.settings.endpoint = input.settings.endpoint.trimmingCharacters(in: .whitespaces)
        input.settings.region = input.settings.region.trimmingCharacters(in: .whitespaces)
        input.settings.bucket = input.settings.bucket.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                result = try await StorageStore.runSetup(input)
            } catch {
                failure = error.localizedDescription
            }
            running = false
        }
    }
}
