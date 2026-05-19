import SwiftUI
import BabyLogCore

struct SettingsView: View {

    @Bindable var viewModel: SettingsViewModel
    @FocusState private var fieldFocused: Bool
    @State private var gemmaDownloadProgress: Double?
    @State private var gemmaDownloadError: String?

    @AppStorage("chat.enableThinking") private var enableThinking: Bool = false
    @AppStorage("tabs.diapersEnabled") private var diapersEnabled: Bool = false
    @AppStorage("tabs.appointmentsEnabled") private var appointmentsEnabled: Bool = false
    @AppStorage("notifications.feedReminderEnabled") private var feedReminderEnabled: Bool = false

    var body: some View {
        Form {
            Section("Child") {
                HStack(spacing: 12) {
                    Image(systemName: "figure.and.child.holdinghands")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                        .foregroundStyle(.pink)
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
                            .removePendingNotificationRequests(withIdentifiers: ["babylog.feed.reminder"])
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
                .accessibilityHint("Toggles chain-of-thought reasoning for the Gemma backend.")

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
}
