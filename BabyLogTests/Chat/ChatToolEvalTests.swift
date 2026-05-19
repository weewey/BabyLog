import XCTest
import BabyLogCore
@testable import BabyLog

/// End-to-end evals for the chat tool pipeline.
///
/// Each test simulates one conversation turn where the "LLM" (a scripted
/// session) emits a `.toolCall` delta. The eval verifies that:
///   1. `ChatViewModel` dispatches the call to the correct `ChatTool`.
///   2. The tool writes the expected domain object to its in-memory repo.
///   3. The assistant's confirmation reply is rendered into the message list.
///
/// No real LLM is involved — the session is deterministically scripted via
/// `ScriptedSession` + `MultiTurnFactory` (same pattern as
/// `ChatViewModelParallelToolsTests`).
@MainActor
final class ChatToolEvalTests: XCTestCase {

    // MARK: - Test infrastructure

    private final class ScriptedSession: ChatSession, @unchecked Sendable {
        let deltas: [ChatDelta]
        init(_ deltas: [ChatDelta]) { self.deltas = deltas }

        func stream(_ text: String) -> AsyncThrowingStream<ChatDelta, Error> {
            AsyncThrowingStream { continuation in
                for delta in deltas { continuation.yield(delta) }
                continuation.finish()
            }
        }

        func cancel() {}
    }

    private final class MultiTurnFactory: ChatSessionFactory, @unchecked Sendable {
        var scripts: [[ChatDelta]]
        private var turn = 0
        init(_ scripts: [[ChatDelta]]) { self.scripts = scripts }
        func makeSession(for backend: ChatBackend) throws -> any ChatSession {
            defer { turn = min(turn + 1, scripts.count - 1) }
            return ScriptedSession(scripts[turn])
        }
    }

    private final class InMemoryPrefs: ChatBackendPreferenceStore, @unchecked Sendable {
        var storage: [String: String] = [:]
        func string(forKey key: String) -> String? { storage[key] }
        func set(_ value: String, forKey key: String) { storage[key] = value }
    }

    private func waitUntil(
        _ check: @escaping @MainActor () -> Bool,
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if check() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("waitUntil timed out", file: file, line: line)
    }

    /// Builds a two-turn conversation: turn 1 emits the given tool calls +
    /// `.done`, turn 2 emits a confirmation text + `.done`.
    private func twoTurnFactory(
        toolCalls: [ChatDelta],
        confirmation: String = "Done!"
    ) -> MultiTurnFactory {
        let turn1 = toolCalls + [.done]
        let turn2: [ChatDelta] = [.token(confirmation), .done]
        return MultiTurnFactory([turn1, turn2])
    }

    // MARK: - Feed logging evals

    func test_chatEval_createFeedLog_bottleFeed_createsCorrectEntry() async throws {
        let feedRepo = InMemoryFeedLogRepository()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_750_000_000))
        let tool = CreateFeedLogTool(repository: feedRepo, clock: clock)
        let vm = ChatViewModel(
            factory: twoTurnFactory(toolCalls: [
                .toolCall(id: "f1", name: "createFeedLog",
                          arguments: ToolArguments(["volumeMl": .int(120), "source": .string("bottle")])),
            ]),
            preferenceStore: InMemoryPrefs(),
            tools: ToolRegistry([tool])
        )

        vm.input = "log a 120ml bottle feed"
        vm.send()
        await waitUntil { !vm.isStreaming }

        let logs = try await feedRepo.all()
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0].volumeMl, 120)
        XCTAssertEqual(logs[0].source, .bottle)
        XCTAssertEqual(logs[0].loggedAt, clock.now())
    }

    func test_chatEval_createFeedLog_smallVolume_createsCorrectEntry() async throws {
        let feedRepo = InMemoryFeedLogRepository()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_750_000_000))
        let tool = CreateFeedLogTool(repository: feedRepo, clock: clock)
        let vm = ChatViewModel(
            factory: twoTurnFactory(toolCalls: [
                .toolCall(id: "f2", name: "createFeedLog",
                          arguments: ToolArguments(["volumeMl": .int(80)])),
            ]),
            preferenceStore: InMemoryPrefs(),
            tools: ToolRegistry([tool])
        )

        vm.input = "log an 80ml feed"
        vm.send()
        await waitUntil { !vm.isStreaming }

        let logs = try await feedRepo.all()
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0].volumeMl, 80)
        // source always defaults to .bottle (picker was removed from the tool schema)
        XCTAssertEqual(logs[0].source, .bottle)
    }

    func test_chatEval_updateFeedLog_changesVolume() async throws {
        let feedRepo = InMemoryFeedLogRepository()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_750_000_000))
        let createTool = CreateFeedLogTool(repository: feedRepo, clock: clock)
        let updateTool = UpdateFeedLogTool(repository: feedRepo)

        // Pre-seed a feed log entry.
        let seedArgs = ToolArguments(["volumeMl": .int(100), "source": .string("bottle")])
        let createResult = try await createTool.execute(arguments: seedArgs)
        let id = try XCTUnwrap(createResult.content.split(separator: "=").last.map(String.init))

        let vm = ChatViewModel(
            factory: twoTurnFactory(toolCalls: [
                .toolCall(id: "u1", name: "updateFeedLog",
                          arguments: ToolArguments(["id": .string(id), "volumeMl": .int(150)])),
            ]),
            preferenceStore: InMemoryPrefs(),
            tools: ToolRegistry([createTool, updateTool])
        )

        vm.input = "actually it was 150ml"
        vm.send()
        await waitUntil { !vm.isStreaming }

        let logs = try await feedRepo.all()
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0].volumeMl, 150)
    }

    func test_chatEval_deleteFeedLog_removesEntry() async throws {
        let feedRepo = InMemoryFeedLogRepository()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_750_000_000))
        let createTool = CreateFeedLogTool(repository: feedRepo, clock: clock)
        let deleteTool = DeleteFeedLogTool(repository: feedRepo)

        // Pre-seed a feed log entry.
        let createResult = try await createTool.execute(
            arguments: ToolArguments(["volumeMl": .int(60), "source": .string("bottle")])
        )
        let id = try XCTUnwrap(createResult.content.split(separator: "=").last.map(String.init))

        let vm = ChatViewModel(
            factory: twoTurnFactory(toolCalls: [
                .toolCall(id: "d1", name: "deleteFeedLog",
                          arguments: ToolArguments(["id": .string(id)])),
            ]),
            preferenceStore: InMemoryPrefs(),
            tools: ToolRegistry([createTool, deleteTool])
        )

        vm.input = "delete that feed"
        vm.send()
        await waitUntil { !vm.isStreaming }

        let logs = try await feedRepo.all()
        XCTAssertTrue(logs.isEmpty)
    }

    // MARK: - Diaper logging evals

    func test_chatEval_createDiaperLog_wet_createsCorrectEntry() async throws {
        let diaperRepo = InMemoryDiaperLogRepository()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_750_000_000))
        let tool = CreateDiaperLogTool(repository: diaperRepo, clock: clock)
        let vm = ChatViewModel(
            factory: twoTurnFactory(toolCalls: [
                .toolCall(id: "dp1", name: "createDiaperLog",
                          arguments: ToolArguments(["type": .string("wet")])),
            ]),
            preferenceStore: InMemoryPrefs(),
            tools: ToolRegistry([tool])
        )

        vm.input = "wet diaper"
        vm.send()
        await waitUntil { !vm.isStreaming }

        let logs = try await diaperRepo.all()
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0].type, .wet)
        XCTAssertEqual(logs[0].loggedAt, clock.now())
    }

    func test_chatEval_createDiaperLog_dirty_createsCorrectEntry() async throws {
        let diaperRepo = InMemoryDiaperLogRepository()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_750_000_000))
        let tool = CreateDiaperLogTool(repository: diaperRepo, clock: clock)
        let vm = ChatViewModel(
            factory: twoTurnFactory(toolCalls: [
                .toolCall(id: "dp2", name: "createDiaperLog",
                          arguments: ToolArguments(["type": .string("dirty")])),
            ]),
            preferenceStore: InMemoryPrefs(),
            tools: ToolRegistry([tool])
        )

        vm.input = "dirty diaper"
        vm.send()
        await waitUntil { !vm.isStreaming }

        let logs = try await diaperRepo.all()
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0].type, .dirty)
    }

    func test_chatEval_createDiaperLog_both_createsCorrectEntry() async throws {
        let diaperRepo = InMemoryDiaperLogRepository()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_750_000_000))
        let tool = CreateDiaperLogTool(repository: diaperRepo, clock: clock)
        let vm = ChatViewModel(
            factory: twoTurnFactory(toolCalls: [
                .toolCall(id: "dp3", name: "createDiaperLog",
                          arguments: ToolArguments(["type": .string("both")])),
            ]),
            preferenceStore: InMemoryPrefs(),
            tools: ToolRegistry([tool])
        )

        vm.input = "wet and dirty diaper"
        vm.send()
        await waitUntil { !vm.isStreaming }

        let logs = try await diaperRepo.all()
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0].type, .both)
    }

    // MARK: - Growth measurement evals

    func test_chatEval_createGrowthMeasurement_weightOnly_createsEntry() async throws {
        let growthRepo = InMemoryGrowthMeasurementRepository()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_750_000_000))
        let tool = CreateGrowthMeasurementTool(repository: growthRepo, clock: clock)
        let vm = ChatViewModel(
            factory: twoTurnFactory(toolCalls: [
                .toolCall(id: "g1", name: "createGrowthMeasurement",
                          arguments: ToolArguments(["weightGrams": .int(4200)])),
            ]),
            preferenceStore: InMemoryPrefs(),
            tools: ToolRegistry([tool])
        )

        vm.input = "Ethan weighs 4.2 kg"
        vm.send()
        await waitUntil { !vm.isStreaming }

        let measurements = try await growthRepo.all()
        XCTAssertEqual(measurements.count, 1)
        XCTAssertEqual(measurements[0].weightGrams, 4200)
        XCTAssertNil(measurements[0].heightCm)
        XCTAssertNil(measurements[0].headCircumferenceCm)
    }

    func test_chatEval_createGrowthMeasurement_fullMeasurement_createsEntry() async throws {
        let growthRepo = InMemoryGrowthMeasurementRepository()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_750_000_000))
        let tool = CreateGrowthMeasurementTool(repository: growthRepo, clock: clock)
        let vm = ChatViewModel(
            factory: twoTurnFactory(toolCalls: [
                .toolCall(id: "g2", name: "createGrowthMeasurement",
                          arguments: ToolArguments([
                              "weightGrams": .int(5100),
                              "heightCm": .double(56.5),
                              "headCircumferenceCm": .double(38.0),
                          ])),
            ]),
            preferenceStore: InMemoryPrefs(),
            tools: ToolRegistry([tool])
        )

        vm.input = "1-month checkup: 5.1 kg, 56.5 cm, head 38 cm"
        vm.send()
        await waitUntil { !vm.isStreaming }

        let measurements = try await growthRepo.all()
        XCTAssertEqual(measurements.count, 1)
        XCTAssertEqual(measurements[0].weightGrams, 5100)
        XCTAssertEqual(measurements[0].heightCm, 56.5)
        XCTAssertEqual(measurements[0].headCircumferenceCm, 38.0)
    }

    // MARK: - Milestone evals

    func test_chatEval_createMilestone_firstSmile_createsEntry() async throws {
        let milestoneRepo = InMemoryMilestoneRepository()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_750_000_000))
        let tool = CreateMilestoneTool(repository: milestoneRepo, clock: clock, birthDate: nil)
        let vm = ChatViewModel(
            factory: twoTurnFactory(toolCalls: [
                .toolCall(id: "m1", name: "createMilestone",
                          arguments: ToolArguments(["title": .string("First smile")])),
            ]),
            preferenceStore: InMemoryPrefs(),
            tools: ToolRegistry([tool])
        )

        vm.input = "Ethan smiled for the first time!"
        vm.send()
        await waitUntil { !vm.isStreaming }

        let milestones = try await milestoneRepo.all()
        XCTAssertEqual(milestones.count, 1)
        XCTAssertEqual(milestones[0].title, "First smile")
        XCTAssertEqual(milestones[0].achievedAt, clock.now())
    }

    func test_chatEval_createMilestone_withNotes_storesNotes() async throws {
        let milestoneRepo = InMemoryMilestoneRepository()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_750_000_000))
        let tool = CreateMilestoneTool(repository: milestoneRepo, clock: clock, birthDate: nil)
        let vm = ChatViewModel(
            factory: twoTurnFactory(toolCalls: [
                .toolCall(id: "m2", name: "createMilestone",
                          arguments: ToolArguments([
                              "title": .string("Rolled over"),
                              "notes": .string("Tummy to back on the playmat"),
                          ])),
            ]),
            preferenceStore: InMemoryPrefs(),
            tools: ToolRegistry([tool])
        )

        vm.input = "he just rolled over on the playmat!"
        vm.send()
        await waitUntil { !vm.isStreaming }

        let milestones = try await milestoneRepo.all()
        XCTAssertEqual(milestones.count, 1)
        XCTAssertEqual(milestones[0].title, "Rolled over")
        XCTAssertEqual(milestones[0].notes, "Tummy to back on the playmat")
    }

    // MARK: - Multi-domain eval

    func test_chatEval_parallelFeedAndDiaper_bothCreated() async throws {
        let feedRepo = InMemoryFeedLogRepository()
        let diaperRepo = InMemoryDiaperLogRepository()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_750_000_000))
        let feedTool = CreateFeedLogTool(repository: feedRepo, clock: clock)
        let diaperTool = CreateDiaperLogTool(repository: diaperRepo, clock: clock)
        let vm = ChatViewModel(
            factory: twoTurnFactory(toolCalls: [
                .toolCall(id: "p1", name: "createFeedLog",
                          arguments: ToolArguments(["volumeMl": .int(100), "source": .string("bottle")])),
                .toolCall(id: "p2", name: "createDiaperLog",
                          arguments: ToolArguments(["type": .string("wet")])),
            ]),
            preferenceStore: InMemoryPrefs(),
            tools: ToolRegistry([feedTool, diaperTool])
        )

        vm.input = "100ml bottle and a wet diaper"
        vm.send()
        await waitUntil { !vm.isStreaming }

        let feeds = try await feedRepo.all()
        let diapers = try await diaperRepo.all()
        XCTAssertEqual(feeds.count, 1)
        XCTAssertEqual(feeds[0].volumeMl, 100)
        XCTAssertEqual(diapers.count, 1)
        XCTAssertEqual(diapers[0].type, .wet)
    }

    // MARK: - Confirmation reply eval

    func test_chatEval_afterToolCall_confirmationAppearsInMessages() async throws {
        let feedRepo = InMemoryFeedLogRepository()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_750_000_000))
        let tool = CreateFeedLogTool(repository: feedRepo, clock: clock)
        let vm = ChatViewModel(
            factory: twoTurnFactory(
                toolCalls: [
                    .toolCall(id: "c1", name: "createFeedLog",
                              arguments: ToolArguments(["volumeMl": .int(90), "source": .string("bottle")])),
                ],
                confirmation: "Logged 90 ml bottle feed."
            ),
            preferenceStore: InMemoryPrefs(),
            tools: ToolRegistry([tool])
        )

        vm.input = "log 90ml"
        vm.send()
        await waitUntil { !vm.isStreaming }

        let assistantReplies = vm.messages.filter { $0.role == .assistant && !$0.text.isEmpty }
        XCTAssertTrue(
            assistantReplies.contains { $0.text.contains("90 ml") },
            "expected confirmation message to contain '90 ml', got: \(assistantReplies.map(\.text))"
        )
    }
}
