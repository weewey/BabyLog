import SwiftUI
import BabyLogCore

struct AppointmentTabView: View {

    @State var viewModel: MedicalAppointmentViewModel
    var onSync: (() async -> Void)?
    /// Builds a fresh visit-summary view model each time the sheet opens so it
    /// re-fetches the latest records. `nil` hides the "Prep for visit" action
    /// (e.g. in previews).
    var makeVisitSummary: (() -> VisitSummaryViewModel)?
    @State private var showForm = false
    @State private var showVisitSummary = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DailyTotalCard(
                        title: "Upcoming",
                        primary: "\(viewModel.upcoming.count) appointment\(viewModel.upcoming.count == 1 ? "" : "s")",
                        secondary: nextSummary(),
                        accent: Theme.appointment,
                        accentIcon: "calendar"
                    )
                    .accessibilityIdentifier("appointmentSummary")
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                AppointmentListView(
                    upcoming: viewModel.upcoming,
                    past: viewModel.past,
                    onDelete: { id in
                        Task { await viewModel.delete(id: id) }
                    }
                )
            }
            .navigationTitle("Appointments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if makeVisitSummary != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showVisitSummary = true
                        } label: {
                            Label("Prep for visit", systemImage: "doc.text.magnifyingglass")
                        }
                        .accessibilityLabel("Prepare a summary for the pediatrician visit")
                        .accessibilityIdentifier("appointmentPrepVisitButton")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showForm = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add appointment")
                    .accessibilityIdentifier("appointmentAddButton")
                }
            }
            .sheet(isPresented: $showForm) {
                NavigationStack {
                    AppointmentFormView(viewModel: viewModel)
                        .navigationTitle("New appointment")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showForm = false }
                                    .accessibilityIdentifier("appointmentFormDoneButton")
                            }
                        }
                }
                .tint(Theme.appointment)
            }
            .sheet(isPresented: $showVisitSummary) {
                if let makeVisitSummary {
                    VisitSummaryView(
                        viewModel: makeVisitSummary(),
                        onDismiss: { showVisitSummary = false }
                    )
                    .tint(Theme.appointment)
                }
            }
            .task { await viewModel.refreshEntries() }
            .refreshable {
                await onSync?()
                await viewModel.refreshEntries()
            }
        }
        .tint(Theme.appointment)
    }

    private func nextSummary() -> String {
        guard let next = viewModel.upcoming.first else { return "No upcoming appointments" }
        return "Next: \(next.title)"
    }
}

#Preview {
    AppointmentTabView(viewModel: MedicalAppointmentViewModel(
        repository: InMemoryMedicalAppointmentRepository(),
        clock: SystemClock()
    ))
}
