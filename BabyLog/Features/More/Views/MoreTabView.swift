import SwiftUI
import LittleECore

/// Custom "More" tab — replaces iOS's auto-generated overflow sheet that
/// appears when a `TabView` has more than five items. Hosts a compact
/// "Today at a glance" card and a list of secondary destinations
/// (Appointments, Milestones, Settings).
///
/// Destination views are injected as `@ViewBuilder` closures so
/// `RootTabView` stays the composition root and `MoreTabView` doesn't have
/// to know how to wire repos, sync, or voice telemetry.
struct MoreTabView<Appointments: View, Milestones: View, Growth: View, Settings: View>: View {

    @Bindable var summaryViewModel: MoreTabSummaryViewModel
    var onSync: (() async -> Void)?
    var onNavigateToFeeds: (() -> Void)?
    var onNavigateToDiapers: (() -> Void)?
    var appointmentsEnabled: Bool = true

    @ViewBuilder var appointmentsDestination: () -> Appointments
    @ViewBuilder var milestonesDestination: () -> Milestones
    @ViewBuilder var growthDestination: () -> Growth
    @ViewBuilder var settingsDestination: () -> Settings

    var body: some View {
        NavigationStack {
            List {
                if let summary = summaryViewModel.summary {
                    Section {
                        TodayGlanceCard(
                            summary: summary,
                            diapersEnabled: summaryViewModel.diapersEnabled,
                            onTapFeeds: onNavigateToFeeds,
                            onTapDiapers: onNavigateToDiapers
                        )
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                    }
                }

                Section {
                    if appointmentsEnabled {
                        NavigationLink {
                            appointmentsDestination()
                        } label: {
                            Label("Appointments", systemImage: "calendar")
                        }
                        .accessibilityIdentifier("moreRowAppointments")
                        .accessibilityHint("Opens medical appointments")
                    }

                    NavigationLink {
                        milestonesDestination()
                    } label: {
                        Label("Milestones", systemImage: "star.fill")
                    }
                    .accessibilityIdentifier("moreRowMilestones")
                    .accessibilityHint("Opens developmental milestones")

                    NavigationLink {
                        growthDestination()
                    } label: {
                        Label("Growth", systemImage: "chart.line.uptrend.xyaxis")
                    }
                    .accessibilityIdentifier("moreRowGrowth")
                    .accessibilityHint("Opens growth measurements")

                    NavigationLink {
                        settingsDestination()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("moreRowSettings")
                    .accessibilityHint("Opens app settings")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("moreTabRoot")
            .task { await summaryViewModel.refresh() }
            .refreshable {
                await onSync?()
                await summaryViewModel.refresh()
            }
        }
    }
}

// MARK: - Today at a glance card

private struct TodayGlanceCard: View {

    let summary: ChatEmptyStateSummary
    var diapersEnabled: Bool = true
    var onTapFeeds: (() -> Void)?
    var onTapDiapers: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(.orange)
                Text("Today at a glance")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            if isEmpty {
                Text("No activity yet today")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 10) {
                    statTile(
                        icon: "waterbottle.fill",
                        tint: .pink,
                        title: "Feeds",
                        value: "\(summary.todayFeedCount)",
                        subtitle: "\(summary.todayFeedVolumeMl) ml",
                        action: onTapFeeds,
                        identifier: "moreSummaryFeedsTile"
                    )
                    if diapersEnabled {
                        statTile(
                            icon: "drop.fill",
                            tint: .blue,
                            title: "Diapers",
                            value: "\(summary.todayDiaperCount)",
                            subtitle: summary.todayDiaperCount == 1 ? "change" : "changes",
                            action: onTapDiapers,
                            identifier: "moreSummaryDiapersTile"
                        )
                    }
                }

                if let last = summary.lastFeed {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                        Text("Last feed ")
                            .foregroundStyle(.secondary)
                        + Text(RelativeTime.shortLabel(for: last.loggedAt))
                            .fontWeight(.semibold)
                        + Text(" · \(last.volumeMl) ml")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .font(.footnote)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.pink.opacity(0.15), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("moreSummaryCard")
    }

    private var isEmpty: Bool {
        summary.todayFeedCount == 0 && (!diapersEnabled || summary.todayDiaperCount == 0)
    }

    @ViewBuilder
    private func statTile(
        icon: String,
        tint: Color,
        title: String,
        value: String,
        subtitle: String,
        action: (() -> Void)?,
        identifier: String
    ) -> some View {
        Button {
            action?()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon).foregroundStyle(tint)
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if action != nil {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(value)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.tertiarySystemBackground))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("\(title): \(value) \(subtitle)")
    }
}

#Preview("MoreTab") {
    MoreTabView(
        summaryViewModel: MoreTabSummaryViewModel(
            feedRepository: InMemoryFeedLogRepository(),
            diaperRepository: InMemoryDiaperLogRepository()
        ),
        onNavigateToFeeds: {},
        onNavigateToDiapers: {},
        appointmentsDestination: { Text("Appointments") },
        milestonesDestination: { Text("Milestones") },
        growthDestination: { Text("Growth") },
        settingsDestination: { Text("Settings") }
    )
}
