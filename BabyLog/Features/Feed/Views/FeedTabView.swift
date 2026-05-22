import SwiftUI
import BabyLogCore

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
                        .listRowSpacing(0)
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
        let nightDay = FeedLogAnalytics.nightDaySplit(feeds: viewModel.allEntries, on: viewModel.now)
        let totalVol = nightDay.night.volumeMl + nightDay.day.volumeMl
        let lastEntry = viewModel.allEntries.max(by: { $0.loggedAt < $1.loggedAt })

        VStack(alignment: .leading, spacing: 14) {
            // Top: big number (left) + last feed (right)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TODAY")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .tracking(0.5)
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text("\(total.volumeMl)")
                            .font(.system(size: 52, design: .serif).italic())
                            .fontWeight(.medium)
                            .foregroundStyle(Theme.feed)
                            .monospacedDigit()
                        Text("ml")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.feed.opacity(0.85))
                    }
                    Text(cardSecondary(total: total, avg: viewModel.averageFeedInterval))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if let interval = viewModel.timeSinceLastFeed, let entry = lastEntry {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("LAST FEED")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .tracking(0.5)
                        (Text(formatInterval(interval))
                            .font(.system(size: 22, design: .serif).italic())
                            .fontWeight(.medium)
                         + Text(" ago")
                            .font(.caption)
                            .foregroundStyle(.secondary))
                        .foregroundStyle(.primary)
                        Text("\(Self.feedTimeFormatter.string(from: entry.loggedAt)) · \(entry.volumeMl) ml")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Night / day split bar
            if totalVol > 0 {
                VStack(spacing: 6) {
                    GeometryReader { proxy in
                        let nightRatio = CGFloat(nightDay.night.volumeMl) / CGFloat(totalVol)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.feed)
                            Capsule()
                                .fill(Color(red: 0.38, green: 0.59, blue: 0.81))
                                .frame(width: max(0, proxy.size.width * nightRatio))
                        }
                    }
                    .frame(height: 6)
                    HStack {
                        Text("Night · \(nightDay.night.volumeMl) ml")
                        Spacer()
                        Text("Day · \(nightDay.day.volumeMl) ml")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .accessibilityIdentifier("feedDailyTotal")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(total: total, last: viewModel.timeSinceLastFeed))
    }

    private static let feedTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()

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
