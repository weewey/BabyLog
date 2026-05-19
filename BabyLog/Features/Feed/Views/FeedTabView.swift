import SwiftUI
import LittleECore

enum FeedSection: String, CaseIterable, Identifiable {
    case today = "Today"
    case trends = "Trends"
    case history = "History"

    var id: String { rawValue }
}

struct FeedTabView: View {

    @State var viewModel: FeedLogViewModel
    var onSync: (() async -> Void)?
    @State private var selectedSection: FeedSection = .today
    @State private var showForm = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section {
                    summaryCard
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                Section {
                    Picker("Section", selection: $selectedSection) {
                        ForEach(FeedSection.allCases) { section in
                            Text(section.rawValue).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("feedSectionPicker")
                }

                switch selectedSection {
                case .today:
                    FeedTodayLogSection(
                        entries: viewModel.todayEntries,
                        onDelete: { id in
                            Task { await viewModel.delete(id: id) }
                        }
                    )
                case .trends:
                    Section {
                        FeedVolumeTrendChartView(
                            feeds: viewModel.allEntries,
                            pumpingSessions: viewModel.allPumpingSessions,
                            now: viewModel.now
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                        FeedClusterHeatmapView(
                            feeds: viewModel.allEntries,
                            now: viewModel.now
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                case .history:
                    FeedLogHistoryView(
                        groupedEntries: viewModel.groupedEntriesExcludingToday,
                        onDelete: { id in
                            Task { await viewModel.delete(id: id) }
                        }
                    )
                }
            }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
            .overlay(alignment: .bottomTrailing) { fab }
            .navigationTitle("Feeds")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showForm) {
                NavigationStack {
                    FeedLogFormView(viewModel: viewModel)
                        .navigationTitle("New feed")
                        .navigationBarTitleDisplayMode(.inline)
                        .scrollDismissesKeyboard(.interactively)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Cancel") { showForm = false }
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showForm = false }
                                    .accessibilityIdentifier("feedFormDoneButton")
                            }
                        }
                }
                .tint(Theme.feed)
            }
            .task { await viewModel.refreshEntries() }
            .refreshable {
                await onSync?()
                await viewModel.refreshEntries()
            }
        }
        .tint(Theme.feed)
        .onAppear {
            Task { await viewModel.refreshEntries() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await viewModel.refreshEntries() }
            }
        }
        .task(id: "feedPeriodicRefresh") {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await viewModel.refreshEntries()
            }
        }
    }

    private var fab: some View {
        Button {
            showForm = true
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .frame(width: 56, height: 56)
                .background(Theme.feed, in: Circle())
                .foregroundStyle(.white)
                .shadow(radius: 6, y: 2)
        }
        .padding(.trailing, 16)
        .padding(.bottom, 16)
        .accessibilityLabel("Add feed")
        .accessibilityHint("Opens form to log a new feed")
        .accessibilityIdentifier("feedAddButton")
    }

    @ViewBuilder
    private var summaryCard: some View {
        let _ = viewModel.lastRefreshed
        let total = viewModel.totalToday
        DailyTotalCard(
            title: "Today",
            primary: "\(total.volumeMl) ml",
            secondary: cardSecondary(total: total, avg: viewModel.averageFeedInterval),
            accent: Theme.feed,
            accentIcon: "waterbottle.fill"
        ) {
            if let last = viewModel.timeSinceLastFeed {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("LAST")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(formatInterval(last))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                }
            }
        }
        .accessibilityIdentifier("feedDailyTotal")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(total: total, last: viewModel.timeSinceLastFeed))
    }

    private func formatInterval(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total < 60 { return "<1m" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rem = minutes % 60
        return rem == 0 ? "\(hours)h" : "\(hours)h \(rem)m"
    }

    private func cardSecondary(total: FeedLogAnalytics.DailyTotal, avg: TimeInterval?) -> String {
        let feeds = "\(total.count) feed\(total.count == 1 ? "" : "s")"
        if let avg {
            return "\(feeds) · avg every \(formatInterval(avg))"
        }
        return feeds
    }

    private func accessibilityLabel(total: FeedLogAnalytics.DailyTotal, last: TimeInterval?) -> String {
        var base = "Today: \(total.volumeMl) millilitres across \(total.count) feeds"
        if let last {
            base += ". Last feed \(formatInterval(last)) ago."
        }
        return base
    }
}

#Preview("Feed tab") {
    FeedTabView(viewModel: FeedLogViewModel(
        repository: InMemoryFeedLogRepository(),
        clock: SystemClock()
    ))
}
