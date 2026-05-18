import SwiftUI
import SwiftData
import UIKit
import LittleECore

struct RootTabView: View {

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var voiceTelemetry = VoiceTelemetry()
    @State private var chatViewModel: ChatViewModel?
    @State private var sync: SyncComposition?
    @State private var settingsViewModel: SettingsViewModel?
    @State private var updateChecker = UpdateChecker()
    @State private var showUpdateAlert = false
    @State private var selectedTab: Int = 0
    @AppStorage("tabs.diapersEnabled") private var diapersEnabled: Bool = false
    @AppStorage("tabs.appointmentsEnabled") private var appointmentsEnabled: Bool = false

    private static let chatTabTag = 0
    private static let feedTabTag = 1
    private static let diaperTabTag = 2
    private static let pumpingTabTag = 3
    private static let moreTabTag = 4

    var body: some View {
        Group {
            if let chatViewModel, let sync, let settingsViewModel {
                tabs(chatViewModel: chatViewModel, sync: sync, settingsViewModel: settingsViewModel)
            } else {
                Color.clear
                    .onAppear {
                        if self.sync == nil {
                            self.sync = SyncComposition(context: context)
                        }
                        if self.chatViewModel == nil, let sync = self.sync {
                            self.chatViewModel = Self.makeChatViewModel(
                                context: context,
                                sync: sync,
                                diapersEnabled: diapersEnabled,
                                appointmentsEnabled: appointmentsEnabled
                            )
                        }
                        if self.settingsViewModel == nil {
                            self.settingsViewModel = SettingsViewModel(
                                repository: SwiftDataChildProfileRepository(context: context),
                                clock: SystemClock()
                            )
                        }
                    }
            }
        }
    }

    /// If the user's last-selected chat backend is Gemma, kick off a
    /// background model load at launch so the first turn doesn't pay
    /// the cold-start penalty. No-op on simulator (Gemma throws
    /// `unsupportedDevice`) and no-op if the user was last on Claude —
    /// don't burn battery or 1.5 GB of RAM on a backend they don't use.
    private static func warmUpGemmaIfSelected() {
        #if !targetEnvironment(simulator)
        let raw = UserDefaults.standard.string(forKey: "chat.selectedBackend")
        guard raw == "gemma" else { return }
        Task.detached(priority: .utility) {
            await Gemma4MLXChatSession.warmUp()
        }
        #endif
    }

    private static func makeChatViewModel(
        context: ModelContext,
        sync: SyncComposition,
        diapersEnabled: Bool,
        appointmentsEnabled: Bool
    ) -> ChatViewModel {
        let args = ProcessInfo.processInfo.arguments
        let forceFake = args.contains("-UITEST_FAKE_CHAT") || args.contains("--ui-testing")
        let suite = args.contains("-UITEST_FAKE_CHAT")
            ? UserDefaults(suiteName: "chat.uitest") ?? .standard
            : .standard
        if args.contains("-UITEST_RESET_CHAT") {
            suite.removeObject(forKey: "chat.selectedBackend")
        }
        let factory: any ChatSessionFactory = forceFake
            ? FakeChatSessionFactory()
            : LiveChatSessionFactory()

        let feedRepo: any FeedLogRepository = sync.makeFeedLogRepository()
        let diaperRepo: any DiaperLogRepository = sync.makeDiaperLogRepository()
        let growthRepo: any GrowthMeasurementRepository = sync.makeGrowthMeasurementRepository()
        let milestoneRepo: any MilestoneRepository = sync.makeMilestoneRepository()
        let appointmentRepo: any MedicalAppointmentRepository = sync.makeMedicalAppointmentRepository()
        let pumpingRepo: any PumpingSessionRepository = sync.makePumpingSessionRepository()
        let clock = SystemClock()
        let calendarSync: any CalendarSyncing = EventKitCalendarSync()
        let feedReminder: any FeedReminderNotifying = LocalFeedReminderNotifier()

        var toolList: [any ChatTool] = [
            CreateFeedLogTool(repository: feedRepo, clock: clock, reminder: feedReminder),
            UpdateFeedLogTool(repository: feedRepo, reminder: feedReminder),
            DeleteFeedLogTool(repository: feedRepo, reminder: feedReminder),
            ListRecentFeedLogsTool(repository: feedRepo),
            GetTodayFeedSummaryTool(repository: feedRepo, clock: clock),
        ]
        if diapersEnabled {
            toolList += [
                CreateDiaperLogTool(repository: diaperRepo, clock: clock),
                UpdateDiaperLogTool(repository: diaperRepo),
                DeleteDiaperLogTool(repository: diaperRepo),
                ListRecentDiaperLogsTool(repository: diaperRepo),
            ] as [any ChatTool]
        }
        toolList += [
            CreateGrowthMeasurementTool(repository: growthRepo, clock: clock),
            UpdateGrowthMeasurementTool(repository: growthRepo),
            DeleteGrowthMeasurementTool(repository: growthRepo),
            ListRecentGrowthMeasurementsTool(repository: growthRepo),
            CreateMilestoneTool(
                repository: milestoneRepo,
                clock: clock,
                birthDate: DateComponents(
                    calendar: .current,
                    year: 2026, month: 4, day: 7
                ).date
            ),
            UpdateMilestoneTool(repository: milestoneRepo),
            DeleteMilestoneTool(repository: milestoneRepo),
            ListRecentMilestonesTool(repository: milestoneRepo),
        ] as [any ChatTool]
        if appointmentsEnabled {
            toolList += [
                CreateMedicalAppointmentTool(repository: appointmentRepo, calendar: calendarSync),
                UpdateMedicalAppointmentTool(repository: appointmentRepo, calendar: calendarSync),
                DeleteMedicalAppointmentTool(repository: appointmentRepo, calendar: calendarSync),
                ListRecentMedicalAppointmentsTool(repository: appointmentRepo),
            ] as [any ChatTool]
        }
        toolList += [
            CreatePumpingSessionTool(repository: pumpingRepo, clock: clock),
            UpdatePumpingSessionTool(repository: pumpingRepo),
            DeletePumpingSessionTool(repository: pumpingRepo),
            ListRecentPumpingSessionsTool(repository: pumpingRepo),
            GetTodayPumpingSummaryTool(repository: pumpingRepo, clock: clock),
        ] as [any ChatTool]
        let tools = ToolRegistry(toolList)

        let recognizer: (any SpeechRecognizing)?
        #if canImport(Speech)
        recognizer = forceFake ? nil : SpeechInputPipeline()
        #else
        recognizer = nil
        #endif

        return ChatViewModel(
            factory: factory,
            preferenceStore: UserDefaultsChatBackendStore(defaults: suite),
            tools: tools,
            speechRecognizer: recognizer
        )
    }

    @ViewBuilder
    private func tabs(chatViewModel: ChatViewModel, sync: SyncComposition, settingsViewModel: SettingsViewModel) -> some View {
        TabView(selection: $selectedTab) {
            ChatTabView(
                viewModel: chatViewModel,
                emptyStateViewModel: ChatEmptyStateViewModel(
                    feedRepository: sync.makeFeedLogRepository(),
                    diaperRepository: diapersEnabled ? sync.makeDiaperLogRepository() : InMemoryDiaperLogRepository(),
                    profileLoader: { [context] in
                        try? SwiftDataChildProfileRepository(context: context).load()
                    },
                    diapersEnabled: diapersEnabled
                ),
                onNavigateToFeeds: { selectedTab = Self.feedTabTag },
                onNavigateToDiapers: diapersEnabled ? { selectedTab = Self.diaperTabTag } : nil
            )
            .tag(Self.chatTabTag)
            .tabItem {
                Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
            }
            .accessibilityIdentifier("chatTab")

            FeedTabView(
                viewModel: FeedLogViewModel(
                    repository: sync.makeFeedLogRepository(),
                    clock: SystemClock(),
                    reminder: LocalFeedReminderNotifier(),
                    pumpingRepository: sync.makePumpingSessionRepository()
                ),
                onSync: { await sync.transport.syncNow() }
            )
            .tag(Self.feedTabTag)
            .tabItem {
                Label("Feeds", systemImage: "waterbottle.fill")
            }
            .accessibilityIdentifier("feedTab")

            if diapersEnabled {
                DiaperTabView(
                    viewModel: DiaperLogViewModel(
                        repository: sync.makeDiaperLogRepository(),
                        clock: SystemClock()
                    ),
                    onSync: { await sync.transport.syncNow() }
                )
                .tag(Self.diaperTabTag)
                .tabItem {
                    Label("Diapers", systemImage: "drop.fill")
                }
                .accessibilityIdentifier("diaperTab")
            }

            PumpingHomeView(
                viewModel: PumpingViewModel(
                    repository: sync.makePumpingSessionRepository(),
                    clock: SystemClock(),
                    template: .medelaEightSessionNewborn
                ),
                onSync: { await sync.transport.syncNow() }
            )
            .tag(Self.pumpingTabTag)
            .tabItem {
                Label("Pumping", systemImage: "drop.triangle.fill")
            }
            .accessibilityIdentifier("pumpingTab")

            MoreTabView(
                summaryViewModel: MoreTabSummaryViewModel(
                    feedRepository: sync.makeFeedLogRepository(),
                    diaperRepository: diapersEnabled ? sync.makeDiaperLogRepository() : InMemoryDiaperLogRepository(),
                    clock: SystemClock(),
                    diapersEnabled: diapersEnabled
                ),
                onSync: { await sync.transport.syncNow() },
                onNavigateToFeeds: { selectedTab = Self.feedTabTag },
                onNavigateToDiapers: diapersEnabled ? { selectedTab = Self.diaperTabTag } : nil,
                appointmentsEnabled: appointmentsEnabled,
                appointmentsDestination: {
                    AppointmentTabView(
                        viewModel: MedicalAppointmentViewModel(
                            repository: sync.makeMedicalAppointmentRepository(),
                            clock: SystemClock(),
                            calendar: EventKitCalendarSync()
                        ),
                        onSync: { await sync.transport.syncNow() }
                    )
                },
                milestonesDestination: {
                    MilestoneTabView(
                        viewModel: MilestoneViewModel(
                            repository: sync.makeMilestoneRepository(),
                            clock: SystemClock()
                        ),
                        onSync: { await sync.transport.syncNow() }
                    )
                },
                growthDestination: {
                    GrowthTabView(
                        viewModel: GrowthMeasurementViewModel(
                            repository: sync.makeGrowthMeasurementRepository(),
                            clock: SystemClock()
                        ),
                        onSync: { await sync.transport.syncNow() }
                    )
                },
                settingsDestination: {
                    SettingsView(
                        viewModel: settingsViewModel,
                        syncStatus: sync.transport.status,
                        onSyncConfigChanged: { sync.transport.reloadConfig() },
                        onSyncIntervalChanged: { sync.transport.setPollInterval($0) },
                        onSyncNow: { Task { await sync.transport.syncNow() } }
                    )
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            NavigationLink {
                                VoiceTelemetryView(telemetry: voiceTelemetry)
                            } label: {
                                Image(systemName: "waveform")
                            }
                            .accessibilityLabel("Voice debug log")
                        }
                    }
                }
            )
            .tag(Self.moreTabTag)
            .tabItem {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("moreTab")
        }
        .task {
            await LocalFeedReminderNotifier().requestAuthorization()
            sync.transport.start()
            LittleEApp.registerBackgroundFeedRefresh(sync: sync)
            Self.warmUpGemmaIfSelected()
            await updateChecker.check()
            if updateChecker.isUpdateAvailable {
                showUpdateAlert = true
            }
        }
        .alert("Update available", isPresented: $showUpdateAlert) {
            Button("Open TestFlight") {
                if let url = URL(string: "itms-beta://") {
                    UIApplication.shared.open(url)
                }
            }
            Button("Later", role: .cancel) { }
        } message: {
            if let latest = updateChecker.latestBuild {
                Text("A newer LittleE build (#\(latest)) is on TestFlight. Open TestFlight to install it.")
            } else {
                Text("A newer LittleE build is on TestFlight.")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                sync.transport.start()
            case .background:
                sync.transport.stop()
                BackgroundTaskRegistrar.scheduleRefresh()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}

#Preview {
    RootTabView()
        .modelContainer(for: [
            FeedLogModel.self,
            DiaperLogModel.self,
            GrowthMeasurementModel.self,
            MedicalAppointmentModel.self,
            MilestoneModel.self,
            ChildProfileModel.self,
            PumpingSessionModel.self,
        ], inMemory: true)
}
