import SwiftUI
import BabyLogCore

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
    var childProfile: ChildProfile? = nil
    var onSync: (() async -> Void)?
    var onNavigateToFeeds: (() -> Void)?
    var onNavigateToDiapers: (() -> Void)?
    var appointmentsEnabled: Bool = true

    @ViewBuilder var appointmentsDestination: () -> Appointments
    @ViewBuilder var milestonesDestination: () -> Milestones
    @ViewBuilder var growthDestination: () -> Growth
    @ViewBuilder var settingsDestination: () -> Settings

    private var displayName: String { childProfile?.name ?? "Baby" }

    private var ageString: String? {
        guard let dob = childProfile?.dateOfBirth else { return nil }
        return ChildAge.shortLabel(dateOfBirth: dob, now: Date()) + " old"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let summary = summaryViewModel.summary {
                        TodayGlanceCard(
                            summary: summary,
                            diapersEnabled: summaryViewModel.diapersEnabled,
                            onTapFeeds: onNavigateToFeeds,
                            onTapDiapers: onNavigateToDiapers
                        )
                        .padding(.horizontal, 16)
                    }

                    // Profile strip
                    HStack(spacing: 14) {
                        Circle()
                            .fill(LinearGradient(
                                colors: [Theme.assistant, Theme.assistant.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 52, height: 52)
                            .overlay(
                                Text(String(displayName.prefix(1)))
                                    .font(.system(size: 22, design: .serif).italic())
                                    .fontWeight(.medium)
                                    .foregroundStyle(.white)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName)
                                .font(.headline)
                            if let age = ageString {
                                Text(age)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)

                    // 2×2 feature grid (domain features only)
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 12
                    ) {
                        NavigationLink { growthDestination() } label: {
                            MoreFeatureCard(
                                title: "Growth",
                                icon: "chart.line.uptrend.xyaxis",
                                tint: Theme.growth,
                                subtitle: "Weight, height & curves"
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("moreRowGrowth")
                        .accessibilityHint("Opens growth measurements")

                        NavigationLink { milestonesDestination() } label: {
                            MoreFeatureCard(
                                title: "Milestones",
                                icon: "star.fill",
                                tint: Theme.milestone,
                                subtitle: "Firsts & achievements"
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("moreRowMilestones")
                        .accessibilityHint("Opens developmental milestones")

                        if appointmentsEnabled {
                            NavigationLink { appointmentsDestination() } label: {
                                MoreFeatureCard(
                                    title: "Appointments",
                                    icon: "calendar",
                                    tint: Theme.medical,
                                    subtitle: "Upcoming checkups"
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("moreRowAppointments")
                            .accessibilityHint("Opens medical appointments")
                        }
                    }
                    .padding(.horizontal, 16)

                    // Secondary list: Settings
                    VStack(spacing: 0) {
                        NavigationLink { settingsDestination() } label: {
                            HStack(spacing: 14) {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Theme.settings.opacity(0.14))
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Image(systemName: "gearshape")
                                            .foregroundStyle(Theme.settings)
                                            .font(.system(size: 15, weight: .semibold))
                                    )
                                Text("Settings")
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .accessibilityIdentifier("moreRowSettings")
                        .accessibilityHint("Opens app settings")
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .padding(.horizontal, 16)

                    Color.clear.frame(height: 24)
                }
                .padding(.top, 16)
            }
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

// MARK: - Feature grid card

private struct MoreFeatureCard: View {
    let title: String
    let icon: String
    let tint: Color
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.14))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                        .font(.system(size: 18, weight: .semibold))
                )
                .accessibilityHidden(true)
            Spacer(minLength: 10)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
