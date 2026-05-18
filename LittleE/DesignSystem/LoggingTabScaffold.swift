import SwiftUI

/// Reusable tab chrome for the "analytics-first" logging tabs (Feed, Diaper,
/// Growth). Caller supplies the five content slots — scaffold owns the
/// `NavigationStack`, the `List` container, the floating `+` action button,
/// and the form sheet presentation.
///
/// Views are dumb: callers pass concrete subviews as `@ViewBuilder` closures.
/// `SecondaryChart == EmptyView` is used by tabs that only have one chart.
struct LoggingTabScaffold<
    Summary: View,
    TodayDetail: View,
    PrimaryChart: View,
    SecondaryChart: View,
    History: View,
    Form: View
>: View {

    let title: String
    let accent: Color
    let addButtonLabel: String
    let addButtonHint: String
    let addButtonIdentifier: String
    let formTitle: String
    let formDoneIdentifier: String
    let onSync: (() async -> Void)?
    let onRefresh: () async -> Void

    @ViewBuilder var summary: () -> Summary
    @ViewBuilder var todayDetail: () -> TodayDetail
    @ViewBuilder var primaryChart: () -> PrimaryChart
    @ViewBuilder var secondaryChart: () -> SecondaryChart
    @ViewBuilder var history: () -> History
    @ViewBuilder var form: () -> Form

    @State private var showForm = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    summary()
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                todayDetail()

                Section {
                    primaryChart()
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    secondaryChart()
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                history()
            }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
            .overlay(alignment: .bottomTrailing) { fab }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showForm) {
                NavigationStack {
                    form()
                        .navigationTitle(formTitle)
                        .navigationBarTitleDisplayMode(.inline)
                        .scrollDismissesKeyboard(.interactively)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Cancel") { showForm = false }
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showForm = false }
                                    .accessibilityIdentifier(formDoneIdentifier)
                            }
                        }
                }
                .tint(accent)
            }
            .task { await onRefresh() }
            .refreshable {
                await onSync?()
                await onRefresh()
            }
            .task(id: "scaffoldSyncObserver") {
                let stream = NotificationCenter.default.notifications(
                    named: .syncStoreDidChange
                )
                for await _ in stream {
                    await onRefresh()
                }
            }
        }
        .tint(accent)
    }

    private var fab: some View {
        Button {
            showForm = true
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .frame(width: 56, height: 56)
                .background(accent, in: Circle())
                .foregroundStyle(.white)
                .shadow(radius: 6, y: 2)
        }
        .padding(.trailing, 16)
        .padding(.bottom, 16)
        .accessibilityLabel(addButtonLabel)
        .accessibilityHint(addButtonHint)
        .accessibilityIdentifier(addButtonIdentifier)
    }
}

extension LoggingTabScaffold where TodayDetail == EmptyView, SecondaryChart == EmptyView {
    init(
        title: String,
        accent: Color,
        addButtonLabel: String,
        addButtonHint: String,
        addButtonIdentifier: String,
        formTitle: String,
        formDoneIdentifier: String,
        onSync: (() async -> Void)? = nil,
        onRefresh: @escaping () async -> Void,
        @ViewBuilder summary: @escaping () -> Summary,
        @ViewBuilder primaryChart: @escaping () -> PrimaryChart,
        @ViewBuilder history: @escaping () -> History,
        @ViewBuilder form: @escaping () -> Form
    ) {
        self.init(
            title: title,
            accent: accent,
            addButtonLabel: addButtonLabel,
            addButtonHint: addButtonHint,
            addButtonIdentifier: addButtonIdentifier,
            formTitle: formTitle,
            formDoneIdentifier: formDoneIdentifier,
            onSync: onSync,
            onRefresh: onRefresh,
            summary: summary,
            todayDetail: { EmptyView() },
            primaryChart: primaryChart,
            secondaryChart: { EmptyView() },
            history: history,
            form: form
        )
    }
}

extension LoggingTabScaffold where TodayDetail == EmptyView {
    init(
        title: String,
        accent: Color,
        addButtonLabel: String,
        addButtonHint: String,
        addButtonIdentifier: String,
        formTitle: String,
        formDoneIdentifier: String,
        onSync: (() async -> Void)? = nil,
        onRefresh: @escaping () async -> Void,
        @ViewBuilder summary: @escaping () -> Summary,
        @ViewBuilder primaryChart: @escaping () -> PrimaryChart,
        @ViewBuilder secondaryChart: @escaping () -> SecondaryChart,
        @ViewBuilder history: @escaping () -> History,
        @ViewBuilder form: @escaping () -> Form
    ) {
        self.init(
            title: title,
            accent: accent,
            addButtonLabel: addButtonLabel,
            addButtonHint: addButtonHint,
            addButtonIdentifier: addButtonIdentifier,
            formTitle: formTitle,
            formDoneIdentifier: formDoneIdentifier,
            onSync: onSync,
            onRefresh: onRefresh,
            summary: summary,
            todayDetail: { EmptyView() },
            primaryChart: primaryChart,
            secondaryChart: secondaryChart,
            history: history,
            form: form
        )
    }
}
