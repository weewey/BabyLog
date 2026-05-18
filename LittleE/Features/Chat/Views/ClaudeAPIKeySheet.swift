import SwiftUI

/// Modal sheet that lets the owner paste in an Anthropic API key for the
/// Claude chat backend. Persists to `ClaudeAPIKeyStore` (Keychain, device-only).
///
/// Presented from the Chat tab when the user selects the Claude backend and
/// `ClaudeAPIKeyStore.load()` returns nil, or from Settings → Chat.
struct ClaudeAPIKeySheet: View {

    /// Closure invoked with the saved key after a successful write so the
    /// presenter can retry the in-flight chat turn. Called with `nil` if the
    /// user cancels.
    var onDismiss: (String?) -> Void

    @State private var apiKey: String = ""
    @State private var errorMessage: String?
    @State private var isSaving: Bool = false
    @Environment(\.dismiss) private var dismiss

    private static let consoleURL: URL = {
        guard let url = URL(string: "https://console.anthropic.com/settings/keys") else {
            fatalError("invalid console URL literal — unreachable")
        }
        return url
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-…", text: $apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel("Anthropic API key")
                        .accessibilityHint("Paste your Claude API key here. It is stored only on this device.")
                } header: {
                    Text("API key")
                } footer: {
                    Text("Stored in the iOS Keychain, device-only. Never leaves your phone.")
                }

                Section {
                    Link(destination: Self.consoleURL) {
                        Label("Where to get one", systemImage: "arrow.up.right.square")
                    }
                    .accessibilityLabel("Where to get an Anthropic API key")
                    .accessibilityHint("Opens the Anthropic console in your browser.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Error: \(errorMessage)")
                    }
                }
            }
            .navigationTitle("Claude API key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismiss(nil)
                        dismiss()
                    }
                    .accessibilityHint("Cancel without saving the key.")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                    .accessibilityHint("Save the key to the device Keychain.")
                }
            }
        }
    }

    private func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try ClaudeAPIKeyStore.writeKeychain(trimmed)
            errorMessage = nil
            onDismiss(trimmed)
            dismiss()
        } catch {
            errorMessage = "Couldn’t save the key to the Keychain. Please try again."
        }
    }
}

#Preview("Empty") {
    ClaudeAPIKeySheet(onDismiss: { _ in })
}
