import SwiftUI
import LittleECore

struct FeedLogFormView: View {

    @Bindable var viewModel: FeedLogViewModel
    @State private var volumeText = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Volume (ml)")
                    Spacer()
                    TextField("0", text: $volumeText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .accessibilityIdentifier("volumeField")
                        .focused($fieldFocused)
                        .onChange(of: volumeText) { _, newValue in
                            viewModel.draftVolume = Int(newValue) ?? 0
                        }
                }

                DatePicker(
                    "Time",
                    selection: $viewModel.draftLoggedAt,
                    in: ...Date(),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .accessibilityIdentifier("timePicker")

                TextField("Notes (optional)", text: $viewModel.draftNotes, axis: .vertical)
                    .lineLimit(1...2)
                    .accessibilityIdentifier("feedNotesField")
                    .focused($fieldFocused)

                Button {
                    fieldFocused = false
                    Task {
                        await viewModel.save()
                        volumeText = ""
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
            }

            if let error = viewModel.saveError {
                Section {
                    Label(String(describing: error), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("saveError")
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
    @Previewable @State var vm = FeedLogViewModel(
        repository: InMemoryFeedLogRepository(),
        clock: SystemClock()
    )
    FeedLogFormView(viewModel: vm)
}
