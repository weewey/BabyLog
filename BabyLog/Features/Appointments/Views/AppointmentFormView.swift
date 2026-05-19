import SwiftUI
import BabyLogCore

struct AppointmentFormView: View {

    @Bindable var viewModel: MedicalAppointmentViewModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("Title (e.g. Pediatrician)", text: $viewModel.draftTitle)
                    .accessibilityIdentifier("apptTitleField")
                    .focused($fieldFocused)

                DatePicker(
                    "When",
                    selection: $viewModel.draftScheduledAt,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .accessibilityIdentifier("apptDatePicker")

                TextField("Location (optional)", text: $viewModel.draftLocation)
                    .accessibilityIdentifier("apptLocationField")
                    .focused($fieldFocused)

                TextField("Notes (optional)", text: $viewModel.draftNotes, axis: .vertical)
                    .lineLimit(1...3)
                    .accessibilityIdentifier("apptNotesField")
                    .focused($fieldFocused)

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
                .accessibilityIdentifier("apptSaveButton")
                .accessibilityLabel("Save appointment")
            }

            if let error = viewModel.saveError {
                Section {
                    Label(String(describing: error), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("apptSaveError")
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
}

#Preview {
    @Previewable @State var vm = MedicalAppointmentViewModel(
        repository: InMemoryMedicalAppointmentRepository(),
        clock: SystemClock()
    )
    AppointmentFormView(viewModel: vm)
}
