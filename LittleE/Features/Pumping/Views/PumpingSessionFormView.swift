import SwiftUI
import LittleECore

/// Form sheet for creating or editing a `PumpingSession`.
struct PumpingSessionFormView: View {

    @Bindable var viewModel: PumpingViewModel
    var onDismiss: () -> Void = {}

    @State private var showSaveError: Bool = false
    @FocusState private var focusedField: Field?

    private enum Field { case volume, notes }

    private var isEditing: Bool { viewModel.editingId != nil }

    var body: some View {
        Form {
            Section("When") {
                DatePicker(
                    "Started at",
                    selection: $viewModel.draftStartedAt,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .accessibilityIdentifier("pumpingStartedAtField")
            }

            Section("Duration") {
                Stepper(
                    value: $viewModel.draftDurationMinutes,
                    in: 1...120,
                    step: 1
                ) {
                    Text("\(viewModel.draftDurationMinutes) min")
                        .monospacedDigit()
                }
                .accessibilityIdentifier("pumpingDurationStepper")
                .accessibilityLabel("Duration in minutes")
                .accessibilityValue("\(viewModel.draftDurationMinutes) minutes")
            }

            Section("Volume") {
                HStack {
                    TextField(
                        "Milk volume (ml)",
                        text: Binding(
                            get: {
                                viewModel.draftMilkVolumeMl == 0 ? "" : String(viewModel.draftMilkVolumeMl)
                            },
                            set: { newValue in
                                let digits = newValue.filter(\.isNumber)
                                viewModel.draftMilkVolumeMl = Int(digits) ?? 0
                            }
                        )
                    )
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .volume)
                    .accessibilityIdentifier("pumpingVolumeField")
                    .accessibilityLabel("Milk volume in millilitres")
                    Text("ml")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Side") {
                Picker("Side", selection: $viewModel.draftSide) {
                    ForEach(PumpingSide.allCases, id: \.self) { side in
                        Text(sideLabel(side)).tag(side)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("pumpingSidePicker")
                .accessibilityHint("Which breast was pumped")
            }

            Section("Notes") {
                TextField("Optional", text: $viewModel.draftNotes, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($focusedField, equals: .notes)
                    .accessibilityIdentifier("pumpingNotesField")
                    .accessibilityLabel("Session notes")
            }

            Section {
                Button {
                    focusedField = nil
                    Task {
                        if isEditing {
                            await viewModel.update()
                        } else {
                            await viewModel.save()
                        }
                        if viewModel.saveError == nil {
                            onDismiss()
                        } else {
                            showSaveError = true
                        }
                    }
                } label: {
                    Text(isEditing ? "Update session" : "Save session")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .disabled(!viewModel.canSave)
                .accessibilityIdentifier("pumpingSaveButton")
                .accessibilityHint(isEditing ? "Save edits to this pumping session" : "Save this new pumping session")
            }
        }
        .alert(
            "Could not save session",
            isPresented: $showSaveError,
            presenting: viewModel.saveError
        ) { _ in
            Button("OK", role: .cancel) { }
        } message: { error in
            Text(errorMessage(error))
        }
    }

    private func sideLabel(_ side: PumpingSide) -> String {
        switch side {
        case .left: return "Left"
        case .right: return "Right"
        case .both: return "Both"
        }
    }

    private func errorMessage(_ error: PumpingSessionError) -> String {
        switch error {
        case .durationOutOfRange: return "Duration must be between 1 and 120 minutes."
        case .volumeOutOfRange: return "Volume must be between 0 and 500 ml."
        case .notesTooLong: return "Notes must be 500 characters or fewer."
        case .brandEmpty: return "Pump brand cannot be empty."
        }
    }
}

#Preview("Pumping form") {
    NavigationStack {
        PumpingSessionFormView(
            viewModel: PumpingViewModel(
                repository: InMemoryPumpingSessionRepository(),
                clock: SystemClock()
            )
        )
        .navigationTitle("New session")
        .navigationBarTitleDisplayMode(.inline)
    }
}
