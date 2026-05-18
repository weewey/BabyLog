import SwiftUI
import LittleECore

struct SettingsView: View {

    @Bindable var viewModel: SettingsViewModel
    @FocusState private var fieldFocused: Bool
    @State private var showClaudeKeySheet: Bool = false
    @State private var claudeKeyIsSet: Bool = ClaudeAPIKeyStore.load() != nil
    @State private var claudeKeyError: String?
    @State private var showSyncSheet: Bool = false
    @State private var syncConfigured: Bool = GitHubSyncTokenStore.load() != nil
    @State private var gemmaDownloadProgress: Double?
    @State private var gemmaDownloadError: String?
    @State private var qwenDownloadProgress: Double?
    @State private var qwenDownloadError: String?

    /// Optional — when nil the pill isn't shown (e.g. previews that
    /// don't want to stand up a full sync stack).
    var syncStatus: SyncStatus? = nil

    /// Invoked after the user saves a new repo+token in the sync sheet so
    /// the presenter can kick `GitHubSyncService` into reloading config.
    var onSyncConfigChanged: (() -> Void)? = nil

    /// Called when the user picks a new poll cadence in the Sync section.
    /// The presenter writes this through to `GitHubSyncService`.
    var onSyncIntervalChanged: ((TimeInterval) -> Void)? = nil

    /// Called when the user taps "Sync now". The presenter kicks a manual
    /// push+pull on `GitHubSyncService`.
    var onSyncNow: (() -> Void)? = nil

    @AppStorage("sync.pollIntervalSeconds") private var pollIntervalSeconds: Double = 30
    @AppStorage("chat.enableThinking") private var enableThinking: Bool = false
    @AppStorage("chat.qwenEnabled") private var qwenEnabled: Bool = false
    @AppStorage("tabs.diapersEnabled") private var diapersEnabled: Bool = false
    @AppStorage("tabs.appointmentsEnabled") private var appointmentsEnabled: Bool = false
    @AppStorage("notifications.feedReminderEnabled") private var feedReminderEnabled: Bool = false

    var body: some View {
        Form {
            if let syncStatus {
                Section("Sync") {
                    SyncStatusPillView(status: syncStatus, now: Date())
                        .accessibilityIdentifier("settingsSyncPill")

                    Button {
                        showSyncSheet = true
                    } label: {
                        HStack {
                            Text("GitHub repo")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(syncConfigured ? "Configured" : "Not set")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("settingsSyncRepoRow")
                    .accessibilityLabel("Sync repository, \(syncConfigured ? "configured" : "not set")")
                    .accessibilityHint("Opens the sync repo and token entry sheet.")

                    Picker("Poll interval", selection: $pollIntervalSeconds) {
                        Text("10 sec").tag(10.0)
                        Text("30 sec").tag(30.0)
                        Text("1 min").tag(60.0)
                        Text("5 min").tag(300.0)
                        Text("15 min").tag(900.0)
                    }
                    .onChange(of: pollIntervalSeconds) { _, new in
                        onSyncIntervalChanged?(new)
                    }
                    .accessibilityIdentifier("settingsSyncIntervalPicker")
                    .accessibilityHint("How often the app checks the repo for peer updates.")

                    Button {
                        onSyncNow?()
                    } label: {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!syncConfigured)
                    .accessibilityIdentifier("settingsSyncNowButton")
                    .accessibilityHint("Pushes local changes and pulls peer updates immediately.")
                }
            }

            Section("Child") {
                HStack(spacing: 12) {
                    Image("EthanAvatar")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                        .overlay(
                            Circle().stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.savedProfile?.name ?? viewModel.draftName)
                            .font(.subheadline.weight(.semibold))
                        if let age = viewModel.ageLabel {
                            Text(age)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("childAvatarHeader")

                TextField("Name", text: $viewModel.draftName)
                    .textContentType(.givenName)
                    .accessibilityIdentifier("childNameField")
                    .focused($fieldFocused)

                DatePicker(
                    "Date of Birth",
                    selection: $viewModel.draftDOB,
                    in: ...Date(),
                    displayedComponents: [.date]
                )
                .accessibilityIdentifier("childDOBPicker")

                if let age = viewModel.ageLabel, let profile = viewModel.savedProfile {
                    HStack {
                        Text("Age")
                        Spacer()
                        Badge(systemImage: "figure.and.child.holdinghands", text: age, tint: .indigo)
                    }
                    .accessibilityIdentifier("childAgeRow")
                    .accessibilityLabel("\(profile.name) is \(age) old")
                }
            }

            Section("Tracking") {
                Toggle(isOn: $diapersEnabled) {
                    Label("Diapers", systemImage: "drop.fill")
                }
                .accessibilityIdentifier("settingsDiapersToggle")
                .accessibilityHint("Show or hide the Diapers tab and related features.")

                Toggle(isOn: $appointmentsEnabled) {
                    Label("Appointments", systemImage: "calendar")
                }
                .accessibilityIdentifier("settingsAppointmentsToggle")
                .accessibilityHint("Show or hide medical appointments in the More tab.")
            }

            Section("Notifications") {
                Toggle(isOn: $feedReminderEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Feed reminder", systemImage: "bell.fill")
                        Text("Notifies when it's been over 3 hours since the last feed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("settingsFeedReminderToggle")
                .accessibilityHint("Turns the feed reminder notification on or off.")
                .onChange(of: feedReminderEnabled) { _, enabled in
                    if !enabled {
                        UNUserNotificationCenter.current()
                            .removePendingNotificationRequests(withIdentifiers: ["littlee.feed.reminder"])
                    }
                }
            }

            Section("Chat") {
                Toggle(isOn: $enableThinking) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show thinking")
                        Text("Stream the assistant's chain-of-thought in a collapsible block. Slower replies.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("settingsThinkingToggle")
                .accessibilityHint("Toggles chain-of-thought reasoning for both Gemma and Claude backends.")

                Button {
                    showClaudeKeySheet = true
                } label: {
                    HStack {
                        Text("Claude API key")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(claudeKeyIsSet ? "Set" : "Not set")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityIdentifier("settingsClaudeKeyRow")
                .accessibilityLabel("Claude API key, \(claudeKeyIsSet ? "set" : "not set")")
                .accessibilityHint("Opens the Claude API key entry sheet.")

                if claudeKeyIsSet {
                    Button(role: .destructive) {
                        do {
                            try ClaudeAPIKeyStore.deleteKeychain()
                            claudeKeyIsSet = false
                            claudeKeyError = nil
                        } catch {
                            claudeKeyError = "Couldn’t clear the key. Please try again."
                        }
                    } label: {
                        Text("Clear Claude API key")
                    }
                    .accessibilityIdentifier("settingsClaudeKeyClearButton")
                }

                if let claudeKeyError {
                    Text(claudeKeyError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("settingsClaudeKeyError")
                }

                Button {
                    downloadGemma()
                } label: {
                    HStack {
                        Text("Gemma 4 model")
                            .foregroundStyle(.primary)
                        Spacer()
                        if let p = gemmaDownloadProgress {
                            Text("\(Int(p * 100))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else {
                            Text("~1.5 GB")
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "arrow.down.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .disabled(gemmaDownloadProgress != nil)
                .accessibilityIdentifier("settingsGemmaDownloadRow")
                .accessibilityLabel("Download Gemma 4 on-device model, about 1.5 gigabytes")
                .accessibilityHint("Downloads the on-device chat model so it can run without network.")

                if let p = gemmaDownloadProgress {
                    ProgressView(value: p)
                        .accessibilityIdentifier("settingsGemmaDownloadProgress")
                }

                if let gemmaDownloadError {
                    Text(gemmaDownloadError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("settingsGemmaDownloadError")
                }

                Toggle(isOn: $qwenEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Qwen3.5 4B")
                        Text("Experimental. Device-only, ~2.5 GB download. Shows the Qwen option in the chat backend picker.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("settingsQwenEnabledToggle")
                .accessibilityHint("Shows or hides Qwen in the chat backend picker.")

                if qwenEnabled {
                    Button {
                        downloadQwen()
                    } label: {
                        HStack {
                            Text("Qwen3.5 4B model")
                                .foregroundStyle(.primary)
                            Spacer()
                            if let p = qwenDownloadProgress {
                                Text("\(Int(p * 100))%")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            } else {
                                Text("~2.5 GB")
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "arrow.down.circle")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .disabled(qwenDownloadProgress != nil)
                    .accessibilityIdentifier("settingsQwenDownloadRow")
                    .accessibilityLabel("Download Qwen 3.5 4B on-device model, about 2.5 gigabytes")
                    .accessibilityHint("Downloads the Qwen GGUF weights. Resumes automatically if interrupted.")

                    if let p = qwenDownloadProgress {
                        ProgressView(value: p)
                            .accessibilityIdentifier("settingsQwenDownloadProgress")
                    }

                    if let qwenDownloadError {
                        Text(qwenDownloadError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("settingsQwenDownloadError")
                    }
                }

                NavigationLink {
                    GemmaTelemetryView(telemetry: GemmaTelemetry.shared)
                } label: {
                    HStack {
                        Text("Gemma latency")
                        Spacer()
                        if let ttf = GemmaTelemetry.shared.medianFirstTokenSeconds {
                            Text(String(format: "%.2fs TTF", ttf))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else {
                            Text("No data")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("settingsGemmaLatencyRow")
                .accessibilityHint("Opens the Gemma generation latency dashboard.")
            }

            Section {
                Button {
                    fieldFocused = false
                    Task { await viewModel.save() }
                } label: {
                    HStack {
                        Spacer()
                        Text("Save").fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!viewModel.canSave)
                .accessibilityIdentifier("settingsSaveButton")
            }

            if let err = viewModel.saveError {
                Section {
                    Label(String(describing: err), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("settingsSaveError")
                }
            }
        }
        .navigationTitle("Settings")
        .tint(Theme.settings)
        .task { await viewModel.load() }
        .sheet(isPresented: $showClaudeKeySheet) {
            ClaudeAPIKeySheet { saved in
                if saved != nil {
                    claudeKeyIsSet = true
                    claudeKeyError = nil
                }
            }
        }
        .sheet(isPresented: $showSyncSheet) {
            GitHubSyncSettingsSheet { saved in
                if saved != nil {
                    syncConfigured = true
                    onSyncConfigChanged?()
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { fieldFocused = false }
                    .accessibilityIdentifier("keyboardDoneButton")
            }
        }
    }

    private func downloadGemma() {
        gemmaDownloadError = nil
        gemmaDownloadProgress = 0
        Task {
            let loader = LiveGemma4ModelLoader()
            do {
                _ = try await loader.loadContainer { p in
                    Task { @MainActor in
                        gemmaDownloadProgress = p
                    }
                }
                await MainActor.run {
                    gemmaDownloadProgress = nil
                }
            } catch {
                await MainActor.run {
                    gemmaDownloadError = "Download failed: \(error.localizedDescription)"
                    gemmaDownloadProgress = nil
                }
            }
        }
    }

    private func downloadQwen() {
        qwenDownloadError = nil
        qwenDownloadProgress = 0
        Task {
            do {
                _ = try await LiveQwenModelLoader.ensureWeightsOnDisk { p in
                    Task { @MainActor in
                        qwenDownloadProgress = p
                    }
                }
                await MainActor.run {
                    qwenDownloadProgress = nil
                }
            } catch {
                await MainActor.run {
                    qwenDownloadError = "Download failed: \(error.localizedDescription)"
                    qwenDownloadProgress = nil
                }
            }
        }
    }
}
