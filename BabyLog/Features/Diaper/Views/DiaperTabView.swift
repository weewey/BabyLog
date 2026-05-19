import SwiftUI
import BabyLogCore

struct DiaperTabView: View {

    @State var viewModel: DiaperLogViewModel
    var onSync: (() async -> Void)?

    var body: some View {
        LoggingTabScaffold(
            title: "Diapers",
            accent: Theme.diaper,
            addButtonLabel: "Add diaper change",
            addButtonHint: "Opens form to log a new diaper change",
            addButtonIdentifier: "diaperAddButton",
            formTitle: "New diaper change",
            formDoneIdentifier: "diaperFormDoneButton",
            onSync: onSync,
            onRefresh: { await viewModel.refreshEntries() },
            summary: { summaryCard },
            primaryChart: {
                DiaperCountsChartView(logs: viewModel.allEntries, now: viewModel.now)
            },
            history: {
                DiaperLogHistoryView(
                    groupedEntries: viewModel.groupedEntries,
                    onDelete: { id in
                        Task { await viewModel.delete(id: id) }
                    }
                )
            },
            form: {
                DiaperLogFormView(viewModel: viewModel)
            }
        )
    }

    @ViewBuilder
    private var summaryCard: some View {
        let counts = viewModel.countsToday
        DailyTotalCard(
            title: "Today",
            primary: "\(counts.total) change\(counts.total == 1 ? "" : "s")",
            secondary: "\(counts.wet) wet · \(counts.dirty) dirty · \(counts.both) both",
            accent: Theme.diaper,
            accentIcon: "drop.fill"
        )
        .accessibilityIdentifier("diaperDailyTotal")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Today: \(counts.wet) wet, \(counts.dirty) dirty, \(counts.both) both")
    }
}

#Preview {
    DiaperTabView(viewModel: DiaperLogViewModel(
        repository: InMemoryDiaperLogRepository(),
        clock: SystemClock()
    ))
}
