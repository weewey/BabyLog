import SwiftUI
import LittleECore

struct DiaperLogFormView: View {

    @Bindable var viewModel: DiaperLogViewModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Form {
            Section("New Diaper Change") {
                Picker("Type", selection: $viewModel.draftType) {
                    Text("Wet").tag(DiaperType.wet)
                    Text("Dirty").tag(DiaperType.dirty)
                    Text("Both").tag(DiaperType.both)
                }
                .accessibilityIdentifier("typePicker")
                .accessibilityLabel("Diaper type")

                TextField("Notes (optional)", text: $viewModel.draftNotes)
                    .accessibilityIdentifier("notesField")
                    .accessibilityLabel("Notes")
                    .focused($fieldFocused)

                DatePicker(
                    "Time",
                    selection: $viewModel.draftLoggedAt,
                    in: ...Date(),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .accessibilityIdentifier("timePicker")

                Button {
                    fieldFocused = false
                    Task {
                        await viewModel.save()
                    }
                } label: {
                    HStack {
                        Spacer()
                        Text("Save")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!viewModel.canSave)
                .accessibilityIdentifier("saveButton")
                .accessibilityLabel("Save diaper change")
            }

            if let error = viewModel.saveError {
                Section {
                    Label(String(describing: error), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("saveError")
                        .accessibilityLabel("Save error")
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
    @Previewable @State var vm = DiaperLogViewModel(
        repository: InMemoryDiaperLogRepository(),
        clock: SystemClock()
    )
    DiaperLogFormView(viewModel: vm)
}
