import SwiftUI
import LittleECore

struct GrowthMeasurementFormView: View {

    @Bindable var viewModel: GrowthMeasurementViewModel
    var onSaved: () -> Void = {}
    @State private var weightText = ""
    @State private var heightText = ""
    @State private var headText = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Form {
            Section("New Measurement") {
                DatePicker(
                    "Date",
                    selection: $viewModel.draftDate,
                    in: ...Date(),
                    displayedComponents: [.date]
                )
                .accessibilityIdentifier("growthDatePicker")

                HStack {
                    Text("Weight (g)")
                    Spacer()
                    TextField("optional", text: $weightText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                        .accessibilityIdentifier("weightField")
                        .focused($fieldFocused)
                        .onChange(of: weightText) { _, newValue in
                            viewModel.draftWeightGrams = Int(newValue)
                        }
                }

                HStack {
                    Text("Height (cm)")
                    Spacer()
                    TextField("optional", text: $heightText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                        .accessibilityIdentifier("heightField")
                        .focused($fieldFocused)
                        .onChange(of: heightText) { _, newValue in
                            viewModel.draftHeightCm = Double(newValue)
                        }
                }

                HStack {
                    Text("Head (cm)")
                    Spacer()
                    TextField("optional", text: $headText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                        .accessibilityIdentifier("headField")
                        .focused($fieldFocused)
                        .onChange(of: headText) { _, newValue in
                            viewModel.draftHeadCircumferenceCm = Double(newValue)
                        }
                }

                TextField("Notes (optional)", text: $viewModel.draftNotes)
                    .accessibilityIdentifier("growthNotesField")
                    .focused($fieldFocused)

                Button {
                    fieldFocused = false
                    Task {
                        await viewModel.save()
                        weightText = ""
                        heightText = ""
                        headText = ""
                        if viewModel.saveError == nil {
                            onSaved()
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        Text("Save").fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!viewModel.canSave)
                .accessibilityIdentifier("growthSaveButton")
                .accessibilityLabel("Save measurement")
            }

            if let error = viewModel.saveError {
                Section {
                    Label(String(describing: error), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("growthSaveError")
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
    @Previewable @State var vm = GrowthMeasurementViewModel(
        repository: InMemoryGrowthMeasurementRepository(),
        clock: SystemClock()
    )
    GrowthMeasurementFormView(viewModel: vm)
}
