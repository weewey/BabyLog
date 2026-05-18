import SwiftUI

/// Modal sheet for entering the GitHub sync PAT. The repo slug is
/// hard-coded in `GitHubSyncTokenStore.repoSlug` so the user only ever
/// needs to paste a token.
struct GitHubSyncSettingsSheet: View {

    /// Closure invoked when the user successfully saves so the presenter
    /// can kick the sync service to reload its config. Called with `nil`
    /// on cancel.
    var onSave: (GitHubSyncConfig?) -> Void

    @State private var token: String = ""
    @State private var errorMessage: String?
    @State private var isSaving: Bool = false
    @Environment(\.dismiss) private var dismiss

    private static let docsURL: URL = {
        guard let url = URL(string: "https://github.com/settings/personal-access-tokens") else {
            fatalError("invalid github settings URL literal")
        }
        return url
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Repository")
                        Spacer()
                        Text(GitHubSyncTokenStore.repoSlug)
                            .foregroundStyle(.secondary)
                            .monospaced()
                    }
                } footer: {
                    Text("Both devices share one private repo. Each device only writes its own event-log file, so there are no merge conflicts.")
                }

                Section {
                    SecureField("github_pat_…", text: $token)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel("GitHub fine-grained token")
                        .accessibilityHint("Paste a fine-grained PAT scoped to the sync repo with Contents: read & write.")
                        .accessibilityIdentifier("syncTokenField")
                } header: {
                    Text("Token")
                } footer: {
                    Text("Stored in the iOS Keychain, device-only. Never leaves your phone.")
                }

                Section {
                    Link(destination: Self.docsURL) {
                        Label("Generate a fine-grained token", systemImage: "arrow.up.right.square")
                    }
                    .accessibilityHint("Opens the GitHub fine-grained PAT page in your browser.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Error: \(errorMessage)")
                    }
                }
            }
            .navigationTitle("Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onSave(nil)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave || isSaving)
                        .accessibilityIdentifier("syncSettingsSaveButton")
                }
            }
        }
    }

    private var canSave: Bool {
        !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        let tok = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tok.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try GitHubSyncTokenStore.writeToken(tok)
            errorMessage = nil
            onSave(GitHubSyncConfig(repoSlug: GitHubSyncTokenStore.repoSlug, token: tok))
            dismiss()
        } catch {
            errorMessage = "Couldn’t save the token to the Keychain (\(String(describing: error))). Please try again."
        }
    }
}

#Preview("Empty") {
    GitHubSyncSettingsSheet(onSave: { _ in })
}
