import SwiftUI
import LittleECore

struct MilestoneFormView: View {

    @Bindable var viewModel: MilestoneViewModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("Title (e.g. First smile)", text: $viewModel.draftTitle)
                    .accessibilityIdentifier("milestoneTitleField")
                    .focused($fieldFocused)

                DatePicker(
                    "Date",
                    selection: $viewModel.draftAchievedAt,
                    in: ...Date(),
                    displayedComponents: [.date]
                )
                .accessibilityIdentifier("milestoneDatePicker")

                TextField("Notes (optional)", text: $viewModel.draftNotes, axis: .vertical)
                    .lineLimit(1...3)
                    .accessibilityIdentifier("milestoneNotesField")
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
                .accessibilityIdentifier("milestoneSaveButton")
                .accessibilityLabel("Save milestone")
            }

            if let error = viewModel.saveError {
                Section {
                    Label(String(describing: error), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("milestoneSaveError")
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
