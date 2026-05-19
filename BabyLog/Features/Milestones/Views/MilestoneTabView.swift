import SwiftUI
import LittleECore

struct MilestoneTabView: View {

    @State var viewModel: MilestoneViewModel
    var onSync: (() async -> Void)?
    @State private var showForm = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DailyTotalCard(
                        title: "Milestones",
                        primary: "\(viewModel.entries.count) logged",
                        secondary: latestSummary(),
                        accent: Theme.milestone,
                        accentIcon: "star.fill"
                    )
                    .accessibilityIdentifier("milestoneSummary")
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                MilestoneListView(entries: viewModel.entries) { id in
                    Task { await viewModel.delete(id: id) }
                }
            }
            .navigationTitle("Milestones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showForm = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add milestone")
                    .accessibilityIdentifier("milestoneAddButton")
                }
            }
            .sheet(isPresented: $showForm) {
                NavigationStack {
                    MilestoneFormView(viewModel: viewModel)
                        .navigationTitle("New milestone")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showForm = false }
                                    .accessibilityIdentifier("milestoneFormDoneButton")
                            }
                        }
                }
                .tint(Theme.milestone)
            }
            .task { await viewModel.refreshEntries() }
            .refreshable {
                await onSync?()
                await viewModel.refreshEntries()
            }
        }
        .tint(Theme.milestone)
    }

    private func latestSummary() -> String {
        guard let latest = viewModel.entries.first else { return "No milestones yet" }
        return "Latest: \(latest.title)"
    }
}

#Preview {
    MilestoneTabView(viewModel: MilestoneViewModel(
        repository: InMemoryMilestoneRepository(),
        clock: SystemClock()
    ))
}
