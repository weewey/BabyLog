import SwiftUI
import BabyLogCore

/// Top-level pumping tab view.
///
/// Layout:
///   - Pink hero card with session count + % completion
///   - Progress bar
///   - Tip-of-day callout
///   - Segmented picker: Daily Log | Schedule Guide
///   - Tab body
struct PumpingHomeView: View {

    @Bindable var viewModel: PumpingViewModel
    var onSync: (() async -> Void)?

    @State private var selectedSegment: Segment = .dailyLog
    @State private var showForm: Bool = false
    @State private var editingSession: PumpingSession?

    enum Segment: String, CaseIterable, Identifiable {
        case dailyLog = "Daily Log"
        case scheduleGuide = "Schedule Guide"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    PumpingTimerCard(
                        summary: viewModel.summary,
                        template: viewModel.template,
                        lastSession: viewModel.todaysSessions.sorted { $0.startedAt > $1.startedAt }.first
                    ) {
                        viewModel.resetDraft()
                        editingSession = nil
                        showForm = true
                    }

                    Picker("View", selection: $selectedSegment) {
                        ForEach(Segment.allCases) { segment in
                            Text(segment.rawValue).tag(segment)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("pumpingSegmentedPicker")
                    .accessibilityHint("Switch between today's log and the schedule guide")

                    Group {
                        switch selectedSegment {
                        case .dailyLog:
                            PumpingDailyLogList(
                                sessions: viewModel.todaysSessions,
                                onDelete: { id in
                                    Task { await viewModel.delete(id: id) }
                                },
                                onEdit: { session in
                                    editingSession = session
                                    viewModel.beginEditing(session)
                                    showForm = true
                                }
                            )
                        case .scheduleGuide:
                            PumpingScheduleList(
                                template: viewModel.template,
                                sessions: viewModel.todaysSessions
                            )
                        }
                    }
                    .padding(.horizontal, 16)

                    NavigationLink {
                        PumpingHistoryView(viewModel: viewModel)
                    } label: {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.pink)
                            Text("View history")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("pumpingHistoryNavLink")
                    .accessibilityHint("Opens pumping history grouped by day with a 30-day trend chart.")

                    Color.clear.frame(height: 40)
                }
                .padding(.top, 8)
            }
            .navigationTitle("Pumping")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.resetDraft()
                        editingSession = nil
                        showForm = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .tint(Theme.pumping)
                    .accessibilityIdentifier("pumpingAddButton")
                    .accessibilityLabel("Add pumping session")
                    .accessibilityHint("Opens form to log a new pumping session")
                }
            }
            .sheet(isPresented: $showForm) {
                NavigationStack {
                    PumpingSessionFormView(
                        viewModel: viewModel,
                        onDismiss: { showForm = false }
                    )
                    .navigationTitle(editingSession == nil ? "New session" : "Edit session")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Cancel") {
                                viewModel.resetDraft()
                                showForm = false
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                showForm = false
                            }
                            .accessibilityIdentifier("pumpingFormDoneButton")
                        }
                    }
                }
                .tint(Theme.pumping)
            }
            .refreshable {
                await onSync?()
                await viewModel.load()
            }
            .task { await viewModel.load() }
            .accessibilityIdentifier("pumpingTabRoot")
        }
        .tint(Theme.pumping)
    }
}

// MARK: - Timer hero card

private struct PumpingTimerCard: View {
    let summary: PumpingAnalytics
    let template: PumpingScheduleTemplate
    let lastSession: PumpingSession?
    var onLogSession: () -> Void

    init(summary: PumpingAnalytics, template: PumpingScheduleTemplate,
         lastSession: PumpingSession?, onLogSession: @escaping () -> Void) {
        self.summary = summary
        self.template = template
        self.lastSession = lastSession
        self.onLogSession = onLogSession
    }

    private static let ringSize: CGFloat = 164

    var body: some View {
        let sessionCount = summary.sessionsLoggedToday
        let totalSlots = max(template.slots.count, 1)
        let ratio = min(Double(sessionCount) / Double(totalSlots), 1.0)

        VStack(spacing: 18) {
            Text("\(sessionCount) of \(totalSlots) sessions")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(Theme.pumping)

            // Progress ring with total ml in center
            ZStack {
                Circle()
                    .stroke(Theme.pumping.opacity(0.15), lineWidth: 6)
                    .frame(width: Self.ringSize, height: Self.ringSize)

                if ratio > 0 {
                    Circle()
                        .trim(from: 0, to: ratio)
                        .stroke(Theme.pumping, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: Self.ringSize, height: Self.ringSize)
                        .rotationEffect(.degrees(-90))
                }

                VStack(spacing: 2) {
                    Text("\(summary.totalVolumeMlToday)")
                        .font(.system(size: 44, design: .serif).italic())
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                    Text("ml today")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            // Log session button
            Button(action: onLogSession) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.semibold))
                    Text("Log session")
                        .font(.headline)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 36)
                .padding(.vertical, 14)
                .background(Theme.pumping, in: Capsule())
                .shadow(color: Theme.pumping.opacity(0.35), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pumpingAddButton")
            .accessibilityLabel("Log pumping session")
            .accessibilityHint("Opens form to log a new pumping session")

            // Last session info
            if let last = lastSession {
                let ago = RelativeTime.shortLabel(for: last.startedAt)
                let detail = last.milkVolumeMl.map { " · \($0) ml" } ?? ""
                Text("Last session \(ago) · \(last.durationMinutes) min\(detail)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pumpingHeroCard")
        .accessibilityLabel("Pumping: \(sessionCount) of \(totalSlots) sessions, \(summary.totalVolumeMlToday) millilitres today")
    }
}

// MARK: - Daily log list

private struct PumpingDailyLogList: View {
    let sessions: [PumpingSession]
    let onDelete: (UUID) -> Void
    let onEdit: (PumpingSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sessions.isEmpty {
                Text("No sessions logged today — tap + to log one.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
                    .accessibilityIdentifier("pumpingEmptyState")
            } else {
                ForEach(sessions) { session in
                    PumpingLogRow(session: session)
                        .contentShape(Rectangle())
                        .onTapGesture { onEdit(session) }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                onDelete(session.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .accessibilityIdentifier("pumpingLogRow")
                }
            }
        }
    }
}

private struct PumpingLogRow: View {
    let session: PumpingSession

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.timeFormatter.string(from: session.startedAt))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(sideLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(session.durationMinutes) min")
                    .font(.subheadline.weight(.semibold))
                if let vol = session.milkVolumeMl {
                    Text("\(vol) ml")
                        .font(.caption)
                        .foregroundStyle(.pink)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var sideLabel: String {
        switch session.side {
        case .left: return "Left"
        case .right: return "Right"
        case .both: return "Both"
        case .none: return "—"
        }
    }

    private var accessibilityText: String {
        var parts = ["\(Self.timeFormatter.string(from: session.startedAt)), \(session.durationMinutes) minutes, \(sideLabel)"]
        if let vol = session.milkVolumeMl { parts.append("\(vol) millilitres") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Schedule guide list

private struct PumpingScheduleList: View {
    let template: PumpingScheduleTemplate
    let sessions: [PumpingSession]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(template.slots) { slot in
                PumpingScheduleRow(
                    slot: slot,
                    isDone: isSlotCompleted(slot)
                )
            }
        }
    }

    /// Reuses Core's "±30min of slot start" matching (see
    /// `PumpingAnalytics.nextRecommendedSlot`). We don't extend Core for this
    /// — the rule is tiny and inlining keeps the Core surface minimal.
    private func isSlotCompleted(_ slot: PumpingScheduleSlot) -> Bool {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let slotDate = calendar.date(
            byAdding: .minute,
            value: slot.startMinuteOfDay,
            to: startOfToday
        ) else { return false }
        return sessions.contains { session in
            abs(session.startedAt.timeIntervalSince(slotDate)) <= 30 * 60
        }
    }
}

private struct PumpingScheduleRow: View {
    let slot: PumpingScheduleSlot
    let isDone: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(slot.emoji)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(slot.label)
                        .font(.subheadline.weight(.semibold))
                    if slot.isNight {
                        Image(systemName: "moon.fill")
                            .font(.caption2)
                            .foregroundStyle(.indigo)
                            .accessibilityLabel("Night session")
                    }
                }
                Text(timeRangeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            if isDone {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.pink)
                    .font(.title3)
                    .accessibilityLabel("Completed")
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary.opacity(0.5))
                    .font(.title3)
                    .accessibilityHidden(true)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isDone ? Color.pink.opacity(0.08) : Color(.secondarySystemBackground))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var timeRangeLabel: String {
        let start = String(format: "%02d:%02d", slot.startHour, slot.startMinute)
        let end = String(format: "%02d:%02d", slot.endHour, slot.endMinute)
        return "\(start) – \(end)"
    }

    private var accessibilityText: String {
        let status = isDone ? "completed" : "not yet done"
        return "\(slot.label), \(timeRangeLabel), \(status)"
    }
}

#Preview("Pumping home") {
    PumpingHomeView(viewModel: PumpingViewModel(
        repository: InMemoryPumpingSessionRepository(),
        clock: SystemClock()
    ))
}
