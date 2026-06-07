# CLAUDE.md

This file is loaded by every Claude agent (managed or local) that works on this repo. Keep it short, current, and actionable. If a rule isn't here, it isn't enforced — add it when you learn it.

## Project

**BabyLog** — native iOS app to track baby Ethan. Users: two humans (the owner and his wife). Built autonomously by a team of seven managed Claude agents (see `.agents/`).

Tracked domains: milk intake, growth, diapers, photos, medical appointments, developmental milestones, cluster-feed analytics.

## Decision-making policy

Default to **deciding and executing**, not asking. The owner's time is the scarce resource; pausing for a thumbs-up on every call wastes it. Escalate only when the cost of being wrong is high.

**Always escalate to the human owner** (ask first, then act):
- Architecture choices that shape the codebase long-term (module boundaries, data model, persistence/sync strategy, framework selection)
- Risky / hard-to-reverse actions (force push, history rewrites, secrets handling, delete/drop operations, production deploys, credential rotation, anything touching CloudKit schema)
- Cost or external commitments (paid services, third-party dependencies, new accounts)
- Off-limits files (`CLAUDE.md`, `.agents/*`, `.github/workflows/*`, `fastlane/*`, `BabyLog.xcodeproj/*`, `.secrets/*`)
- Scope expansions beyond the current task

**Decide and execute autonomously** for everything else: file layout within an existing module, language/tooling details, test structure, refactors that don't cross module boundaries, dependency versions, script mechanics, local tooling. This includes committing, pushing, dispatching agents, creating cards, running the orchestrator, and any other low-risk reversible action. Don't pause to ask "want me to continue?" — just continue.

**How to decide** when there are multiple options:
1. List the viable options (usually 2–4; don't invent more than exist).
2. For each, weigh against four axes: **time to ship**, **simplicity**, **code cleanliness**, **long-term quality**.
3. State the pick in one sentence, then execute. No need to narrate the full analysis unless asked.
4. If time-to-ship and long-term quality conflict, prefer the option that ships now *and* can be refactored later without throwing code away. "Start simple, graduate cleanly" beats "get it perfect up front".
5. If the options are genuinely close (within ~20% on all axes), pick the simpler one and move on. Reversibility is cheap; indecision is not.

## Parallelize work whenever possible

Every time you're about to make tool calls, ask: "are any of these independent of each other?" If yes, batch them into a single message. This applies to reads (multi-file context gathering), searches (Glob + Grep on different queries), edits across unrelated files, and subagent dispatches. A sequential loop of N independent reads costs N round-trips; a parallel batch costs 1. The only reason to serialize is a genuine dependency — "I need the output of A to know what B should do." Otherwise default to parallel.

When you do pause for the owner, frame it as: "Here are the 2–3 options, here's what I'd pick and why, say no if you disagree." Not: "What should I do?"

## Bootstrap progress

The autonomous build pipeline is being stood up incrementally. Agents reading this file: use this section to know what exists, what doesn't, and what you can rely on. Update this section any time you complete one of the items below.

**Last updated:** 2026-06-07 (lock-crash mitigation: disable auto-lock while a reply streams)

> **Progress-updates policy:** The `### ✅ Done` list below is **not** off-limits. Agents (managed or local) **must** append a bullet under `### ✅ Done` whenever they land a merged feature, infra change, or bootstrap step, and bump `**Last updated:**` to today's date in the same edit. Keep each bullet one line, prefix with the epic/issue number if applicable. Everything else in CLAUDE.md remains off-limits unless the owner says otherwise.

### ✅ Done

- **Lock-during-generation crash — disable auto-lock while streaming** (2026-06-07): build 24 still `SIGABRT`'d on `com.Metal.CompletionQueueDispatch` with `isLocked=1` (crash report `BabyLog-2026-06-03-235320.ips`). Root cause confirmed structural, not a bug in the build-23/24 fix: when the screen locks mid-reply iOS revokes GPU access *before/while* our main-thread `.inactive` handler runs, so `drainGPU()` (`Stream.gpu.synchronize()`) can't help — it only *waits for* the in-flight buffer, which completes **with error**, and MLX rethrows from Metal's own completion-queue thread (off any Swift stack → uncatchable). Mitigation A (owner-approved, can't be fully killed app-side): `ChatViewModel` now keeps the screen awake while `isStreaming` via an injected `IdleTimerControlling` seam (`UIApplicationIdleTimer` in prod, `didSet` on `isStreaming` toggles it, restored on done/cancel/suspend). Kills the auto-lock trigger (phone set down, sleeps mid-reply — the common case); a deliberate power-button lock can still crash (only fully fixable MLX-side). 2 new `ChatViewModelTests`.
- **Repo**: `weewey/BabyLog` private, `main` branch, local working copy at `/Users/yewwee/localdev/BabyLog/BabyLog`, all commits pushed to origin
- **Xcode skeleton**: `BabyLog.xcodeproj` + `BabyLog/`, `BabyLogTests/`, `BabyLogUITests/` (default SwiftUI app template)
- **Fastlane**: `fastlane/Fastfile` with `test` + `beta` lanes, `Gemfile` with `gem "fastlane"`
- **CI**: `.github/workflows/ci.yml` — `core-tests` job (ubuntu, `swift test --package-path BabyLogCore`, ~30s) + `test` job (macos-14, `xcodebuild test` on iPhone 16 simulator)
- **TestFlight pipeline**: `.github/workflows/testflight.yml` (Fastlane beta on merge to main) — NOT yet smoke-tested end-to-end (fails on every push so far, expected until ASC API key is wired up)
- **`BabyLogCore` Swift Package**: created, Swift 6 mode, iOS 26 / macOS 26 platforms, `Clock` / `SystemClock` / `TestClock` primitive in place with 4 passing tests (~1ms). Wired into `BabyLog` app target via `XCLocalSwiftPackageReference` — see commit `f12bc77`.
- **Phase 1 managed agents provisioned**: PM (Opus), Core (Sonnet), Reviewer (Opus) created via `scripts/setup_agents.py` + one cloud environment. IDs persisted in `scripts/agents.json` (committed — opaque IDs are not secrets). PM smoke test green: session lifecycle end-to-end (7 events, ~3s).
- **Orchestrator iteration 1** (`scripts/orchestrator.py`): gathers board state via `gh`, spawns PM session, parses `LABEL/UNLABEL/STAGE/DISPATCH` action lines from PM's reply, applies label actions, posts tick summary to issue #2. `STAGE` and `DISPATCH` stubbed for iteration 2. First real tick landed: PM correctly labeled epic #3 `needs:human`.
- **Autopilot smoke test**: 3 consecutive local ticks at 60s intervals, fully unattended. PM was idempotent (0 actions on ticks 2 & 3 because #3 was already escalated). Proves the loop is safe to trigger repeatedly.
- **Event-driven orchestrator workflow** (`.github/workflows/orchestrator.yml`): fires on `issues`, `pull_request`, `issue_comment`, `workflow_dispatch`. Replaces the originally planned 30-min cron — avoids burning tokens on quiet ticks. `github.actor != 'github-actions[bot]'` filter prevents self-trigger loops. `ANTHROPIC_API_KEY` added to Actions secrets — workflow is **live** and verified (first remote tick landed on issue #2).
- **Iteration 2 orchestrator** (`scripts/orchestrator.py`): STAGE (GraphQL mutation), DISPATCH (spawn child session + post reply as card comment), Core + Reviewer prompt builders. Board context includes authoritative Stage field. First PM→Core dispatch completed end-to-end: PM moved #4 to In Progress, Core agent produced full FeedLog implementation.
- **Epic #3 decomposed**: 4 child cards created (#4 core, #5 VM, #6 views+a11y, #7 SwiftData), added to project board with stages. #4 dispatched, #5/#7 in Todo, #6 blocked on Phase 2 Designer.
- **Agent contracts**: `.agents/AGENTS.md` + `pm.md`, `designer.md`, `core.md`, `ui.md`, `reviewer.md`, `security.md`, `tester.md` — seven roles
- **GitHub Project #1**: `https://github.com/users/weewey/projects/1` — custom `Stage` field (Backlog / Todo / In Progress / In Review / Done), agent/priority/type/needs labels created
- **Standing issues**: `#2` pm-log (PM posts tick summaries as comments)
- **First epic**: `#3` "Log a feed with volume and timestamp" — labels `type:feature`, `priority:high`, `needs:design`, Stage = Backlog
- **GitHub PAT**: rotated 2026-04-11 after earlier version was surfaced via Read tool during bootstrap
- **Epic #21 (B) — feed volume trend chart**: `FeedLogAnalytics.dailyVolumes` + `FeedVolumeTrendChartView` shipped, merged to main 2026-04-13 (5 tests).
- **Epic #22 (C) — cluster feed heatmap**: `FeedLogAnalytics.clusterHeatmap` / `feedsInBucket` + `FeedClusterHeatmapView` with bucket drill-down shipped, merged 2026-04-13 (9 tests).
- **Epic #23 (E) — device-to-device sync**: append-only event log (`DomainEvent`, `EventStore`, `FeedLogProjection`, `EventSourcedFeedLogRepository`, `SyncEngine`) in Core + `MultipeerSyncService` + `SyncStatusPillView` in app. Merged 2026-04-13 (22 tests). SwiftData-backed store + other domains tracked in #27/#28.
- **Epic #24 (A) — voice capture**: `ParsedIntent` / `IntentRouter` / `FakeIntentRouter` in Core + `AppleSpeechTranscriber` / `ClaudeIntentRouter` (Haiku 4.5 tool-use) / `ClaudeAPIKeyStore` (Keychain) / `VoiceMicOverlay` / confirmation sheets, merged 2026-04-13. "App Secret Key" UX refactor still pending (#29).
- **Info.plist usage descriptions**: `NSBluetoothAlwaysUsageDescription` + `NSLocalNetworkUsageDescription` wired into pbxproj for Multipeer (2026-04-13).
- **#42/#43/#44 — Core chat tool foundation**: `ChatTool` protocol, `ToolRegistry`, `ToolInputSchema`/`ToolArguments`/`JSONValue`/`ToolResult`/`ChatToolError`, `ChatDelta.toolCall`/`.toolResult`, `ChatSessionParityHarness` invariants, plus 5 logging tools (`CreateFeedLogTool`, `UpdateFeedLogTool`, `CreateDiaperLogTool`, `CreateGrowthMeasurementTool`, `CreateMilestoneTool`) — landed 2026-04-13 (29 new tests).
- **Post-review slices** (2026-04-13): Slice 1 — FeedTabView analytics moved behind nav-bar sheet (fixes `volumeField` clipping) + EventKit sync short-circuit under `--ui-testing`. Slice 2 — voice tap-to-toggle + retry path + a11y hints on confirmation sheets. Slice 3 — `ClaudeAPIKeyStore` `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, typed `ClaudeAPIKeyStoreError` / `IntentRouterError`, `ClaudeIntentRouter` converted to `actor`, 9 new URLProtocol-mocked router tests. Slice 4 — `SyncStateMachine` actor wires `MultipeerSyncService` through typed codec errors + transferring pill state.
- **Chat tool-calling wired end-to-end** (2026-04-13): production `ChatViewModel` in `RootTabView` now constructs a `ToolRegistry` with the 5 SwiftData-backed logging tools; Claude backend verified via idb smoke (`createFeedLog` → 120 ml bottle feed lands in Feeds tab). `ToolArguments.parseISO8601` now accepts naive ISO8601 strings without timezone (`ffeda21`, +3 tests).
- **Full chat CRUD across 5 domains** (2026-04-13): 20 chat tools now wired (Create/Update/Delete/ListRecent × Feed/Diaper/Growth/Milestone/MedicalAppointment). Today's date injected into Claude system prompt as uncached block. Anthropic 400 errors now surface the real `error.message` body via `ChatSessionError.invalidResponse(status:message:) + CustomStringConvertible`. Create tool results now include `id=<uuid>` so the model can target update/delete without a separate lookup.
- **Chat tools wired to calendar + feed reminder side effects** (2026-04-13): `CreateMedicalAppointmentTool` / `UpdateMedicalAppointmentTool` / `DeleteMedicalAppointmentTool` now take an optional `CalendarSyncing` and call `upsert` / `remove` after the repo write; `CreateFeedLogTool` / `UpdateFeedLogTool` / `DeleteFeedLogTool` take an optional `FeedReminderNotifying` + threshold and reschedule the local reminder after write. Wired through `RootTabView.makeChatViewModel`. Verified end-to-end on sim: chat-created appointment lands in `Calendar.sqlitedb` with `Alarm.trigger_interval=-900` (15-min pre-alarm), and chat-logged feed adds a SpringBoard pending notification with trigger 3h in the future. Closes coverage gap where chat writes bypassed EventKit + `UNUserNotificationCenter`.
- **Chat mic deadlock fixed** (2026-04-13): `SpeechInputPipeline.start()` now runs audio setup off the main actor (async protocol + DispatchQueue continuation), uses `.playAndRecord` / `.spokenAudio`, lazy `AVAudioEngine` created *after* `AVAudioSession` activation, and drops `requiresOnDeviceRecognition`. Resolves CoreAudio `AURemoteIO Initialize` RPC deadlock that hard-aborted the app when the mic button was tapped. Sim now surfaces clean error alerts for missing Siri assets instead of crashing.
- **GitHub-backed sync transport** (2026-04-13): replaced `MultipeerSyncService` with `GitHubSyncService` (Contents API push + Trees API pull), `GitHubSyncTokenStore` (Keychain w/ DEBUG env-var fallback for unsigned sims), `GitHubSyncSettingsSheet` (token-only entry, repo slug hardcoded to `weewey/littlee-sync`), and `SyncComposition` wiring. JSONL peer files validated on read (size cap, timestamp bounds, payload size, schema version) — corrupt lines are dropped, never crash. DEBUG builds write under `events-test/`, Release under `events/`, so test sims never pollute the prod feed. E2E verified across two sims: 200 ml feed on sim A surfaced on sim B within ~60 s.
- **Gemma 4 E2B backend wired** (2026-04-13): replaced the `.unavailable` stub with a real `Gemma4MLXChatSession` driving `MLXLMCommon.ChatSession.streamDetails` against `LLMRegistry.gemma4_e2b_it_4bit` via `#huggingFaceLoadModelContainer`. New `Gemma4ToolMapping` (ChatTool↔ToolSpec + JSONValue converters) and `Gemma4ModelLoader` protocol seam. Pulled in `swift-transformers` 1.3.0 (Tokenizers, Hub) + `swift-huggingface` 0.9.0 (HuggingFace) to satisfy the macro's `HubClient`/`AutoTokenizer` references — mlx-swift-lm doesn't transitively provide them. `ChatTabView` now renders `modelLoadProgress` as an inline progress bar. Sim path throws `.unsupportedDevice` cleanly (verified via idb on iPhone 16); on-device download/generation smoke still pending hardware. Commit `815bcbf`.
- **Parallel tool_use bundling fix** (2026-04-13): `ClaudeChatSession.anthropicMessages` now re-groups `ChatViewModel`'s interleaved `.call`/`.result` tool messages into one assistant turn (all `tool_use` blocks) + one user turn (all matching `tool_result` blocks). Fixes HTTP 400 "unexpected tool_use_id in tool_result blocks" when the model emits parallel tool calls (e.g. "log a feed, a diaper, and a weight" → 3 tool_use in one assistant message).
- **Chat suggestion chip strip + Gemma lifecycle fixes** (2026-04-14): `ChatTabView` gains an always-visible horizontal chip strip above the composer with four tappable starters (60 ml feed, dirty/wet diaper, today's feed total); write-intent chips populate the input and focus it for review, the read-only total query auto-sends. Composer `TextField` dropped from `.roundedBorder` to `.plain` inside a `tertiarySystemBackground` capsule so the tap target stays visible without a hard outline. Empty state now defers to the strip instead of duplicating a vertical prompt list. `Gemma4MLXChatSession` rewritten to fix three regressions surfaced on TestFlight: (a) `cachedContainer` + `inFlightTask` moved to static `NSLock`-guarded storage so the ModelContainer survives the fresh-session-per-turn pattern `ChatViewModel` uses — the "Loading Gemma 4…" bar now only shows on first use per launch; (b) MLX generation is serialized process-wide (new `stream()` awaits the prior task from shared state before touching the container), fixing a crash when switching Gemma→Claude mid-reply stomped Metal state; (c) added `GemmaToolCallStreamParser`, a sliding-window parser that buffers `<|tool_call>...<tool_call|>` markers out of the chunk stream, parses `call:NAME{k:v}` bodies with `<|"|>` string quoting + nested depth tracking, and emits them as real `.toolCall` deltas — raw tool-call text no longer leaks as assistant bubbles when `GemmaFunctionParser` misses Gemma 4's `model_type`. Commits `602cb87`, `79d47f5`.
- **Gemma reliability + TestFlight update prompt + feed add simplification** (2026-04-14): `LiveGemma4ModelLoader` now builds a custom `HubClient(session:)` with 600s/3600s timeouts + `waitsForConnectivity` to survive large shard fetches (`4aa4cbc`), and pre-sets `configuration.toolCallFormat = .gemma` so `GemmaFunctionParser` wires up correctly (`ToolCallFormat.infer()` exact-matches `"gemma"` and misses Gemma 4's `"gemma4_text"`) — raw `<|tool_call>` tokens no longer leak as plain text. `Gemma4MLXChatSession.splitHistory` now injects `ClaudeChatSession.systemPrompt(today:)` at index 0 and projects prior tool calls as `call:NAME{k:v}` assistant turns so multi-turn context rehydrates (`fdb6804`). New launch-time `UpdateChecker` reads `release/latest-build.json` from `weewey/littlee-sync` via GitHub Contents API and, when the manifest build > `CFBundleVersion`, `RootTabView` shows an "Update available" alert that deep-links to `itms-beta://` (`7414a10`). `FeedLogFormView` drops the bottle/breast picker and `CreateFeedLogTool`/`UpdateFeedLogTool` schemas no longer expose `source` — defaults to `.bottle` on create, preserves existing on update (`3d26b9a`).
- **Qwen 2.5 llama.cpp chat backend scaffold** (2026-04-15): new `.qwen` case on `ChatBackend`, `QwenLlamaCppChatSession` + `LiveQwenModelLoader` wired through `LiveChatSessionFactory` behind `#if canImport(llama)`, plus `QwenToolCallStreamParser` (pure-Swift streaming parser for Qwen's native `<tool_call>` XML envelopes — handles parallel calls, partial-chunk buffering, malformed JSON recovery, 10 tests). Session throws `.llamaDependencyMissing` until the human owner adds the llama.cpp SPM dep to `BabyLog.xcodeproj`; picker now shows Claude / Gemma / Qwen.
- **Growth analytics-first migration** (2026-04-14): new `GrowthAnalytics.summary` (latest weight/height/head + 7–30d weight delta, 7 Linux tests) + `GrowthMeasurementViewModel.summary` passthrough; `GrowthTabView` rewritten onto `LoggingTabScaffold` and now delegates charting to existing `GrowthChartView` instead of duplicating it inline. Summary card shows e.g. "8.20 kg · +120 g this week". All `GrowthUITests` green.
- **Feeds night/day analytics redesign** (2026-04-14): replaced broken 7×24 weekday heatmap with a single compact card. New Core API in `FeedLogAnalytics`: `isNightHour` (22:00–06:59 local per owner preference), `nightDaySplit`, `detectNightCluster` (≥3 night feeds, median gap ≤90min), `hourlyHeatmap` (rolling 7d), `peakHours`, `longestStretch` — 16 new Linux tests. `FeedClusterHeatmapView` now renders: header + "Night cluster" badge, NIGHT/DAY halfColumns (ml / count / %), today's longest stretch, top-3 peak-hour capsule pills, and a collapsed 24-cell hourly disclosure. Design reviewed by designer subagent (dropped daytime cluster, patronizing tip, and per-hour ml). Compact layout (~200pt collapsed) keeps history rows inside SwiftUI List's lazy-render window — fixes regression where a taller prototype broke `testLogMultipleFeeds_allAppearInList`. Full xcodebuild suite green.
- **Lock-during-generation crash — cancel on `.inactive` + GPU drain** (2026-06-02): build 23 still `SIGABRT`'d on `com.Metal.CompletionQueueDispatch` but with `isLocked=1` — the lock case. Our cancel fired (a thread was tearing down MLX) yet an already-committed Metal command buffer completed-with-error once the lock revoked GPU access, and MLX rethrew uncatchably. Cancelling a Swift task can't abort a buffer already on the GPU. Fix: `RootTabView` now cancels on `.inactive` (earliest resign signal, before GPU is revoked) in addition to `.background`, and `MLXMemoryTuning.drainGPU()` (`Stream.gpu.synchronize()`) is called from `Gemma4MLXChatSession.cancel()` / `QwenMLXChatSession.cancel()` to block until in-flight GPU work completes *while still foreground-eligible*. Trade-off (owner-approved): pulling Control Center / a banner mid-reply also cancels it. Residual: a buffer submitted in the instant between cancel and drain can still slip — not 100% eliminable without MLX-side changes. Build 24.
- **MLX GPU memoryLimit cap — foreground crash fix** (2026-05-29): TestFlight build 22 still crashed (`SIGABRT` on `com.Metal.CompletionQueueDispatch`) but **in the foreground, mid-generation** (`isLocked=0`, main thread in the normal run loop, `GemmaToolCallStreamParser` running on a worker) — a different cause than the lock/background crash. MLX's default `Memory.memoryLimit` is *1.5× the device's recommended GPU working set*, which overshoots the GPU ceiling on iOS; an allocation past it fails the Metal command buffer and MLX rethrows uncatchably. New `MLXMemoryTuning.apply()` caps `Memory.memoryLimit` to 0.8× `recommendedMaxWorkingSetSize` (and keeps the 20 MB cacheLimit); both `LiveGemma4ModelLoader` and `LiveQwenMLXModelLoader` call it at load. 3 new tests on the pure limit computation. Independent of turn count (owner reproduced at ~5–6 turns). Build 23.
- **Chat empty-bubble + id-leak fixes** (2026-05-29): first-prompt blank assistant bubble fixed — `ChatViewModel.runToolLoop`'s `.done` branch now *removes* a fully-empty assistant turn (kept only if it carries reasoning/intent) instead of sealing it, and `ChatTabView.shouldSuppressBubble` hides any whitespace-only finished assistant bubble (was gated on `reasoning != nil`, so plain empty turns from a flaky cold first generation rendered as a grey blob). Both on-device system prompts (`gemmaSystemPrompt` + `qwenSystemPrompt`) now instruct the model to never surface internal `id=…` record ids to the user (the id stays in tool-result content for update/delete chaining). Multi-turn confirmed wired (whole `messages` array → `splitHistory` → system + history + lastUser). 2 new tests. Build 22.
- **Background-crash fix — cancel MLX generation on resign-active** (2026-05-29): TestFlight build 19 crashed (`SIGABRT` on `com.Metal.CompletionQueueDispatch`, `isLocked=1`) when the phone locked mid-Gemma-reply — MLX kept submitting Metal command buffers that iOS fails once backgrounded, and MLX's completion handler throws an uncatchable C++ exception. New `ChatViewModel.suspendForBackground()` cancels in-flight streaming; `RootTabView` scene-phase handler calls it on `.background` only (deliberately not `.inactive`, so transient foreground interruptions — Control Center, banners, app switcher — don't kill an in-flight reply). 2 new `ChatViewModelTests`. A residual single-buffer race remains (not fully eliminable without MLX-side changes); the model warm-up/load path is unguarded but lower-risk.
- **BabyLog Assistant chat rebrand + Gemma 4 in-app download** (2026-04-13): `ClaudeChatSession.systemPromptBody` rewritten to introduce as "the BabyLog Assistant" anchored on Ethan Chua (born 2026-04-07) with list-tool-before-answer rules + unit/tone guidance; `ChatTabView` empty-state greeting matches; chat keyboard Done button removed (overlapped mic/send) and tap-on-background now dismisses; `SettingsView` Chat section gains a Gemma 4 download row that calls `LiveGemma4ModelLoader.loadContainer` with inline percent + `ProgressView`; `EthanAvatar.imageset` finally staged into git so the Settings child header renders. `SettingsUITests.testLaunch_showsSettingsForm` now scrolls if the Save button is below the lazy Form window.

### ❌ Not done (tracked in session task list)

- `ANTHROPIC_API_KEY` added to GitHub Actions repo secrets (blocks the event-driven orchestrator workflow from running)
- End-to-end smoke test of `.github/workflows/orchestrator.yml` (manual `workflow_dispatch` → PM tick runs in Actions → comment lands on #2)
- Iteration 2 orchestrator: implement `STAGE` (project board writes) and `DISPATCH` (spawn Core/Reviewer child sessions) actions
- Phase 2 agents live: **Designer, UI, Security, Tester** (added after the 3-agent loop is green on a real card — reaches the full 7-agent target from the Project section)
- Decomposition of epic `#3` into child cards (happens after Designer flips `needs:design` → `design:ready` — blocked until Phase 2)
- End-to-end smoke test of the TestFlight pipeline (needs ASC API key)

**Goal state:** 7 agents (PM, Designer, Core, UI, Reviewer, Security, Tester) as described in the Project section and `.agents/`. Phased rollout is a time-to-first-dispatch optimization, not a scope cut. Do not delete agent contracts in `.agents/` — they are the target.

### 🔑 GitHub Project IDs (use these, don't re-discover)

- Project id: `PVT_kwHOALfRGc4BUXhq`
- Stage field id: `PVTSSF_lAHOALfRGc4BUXhqzhBgKZ8`
- Stage option ids: Backlog=`a9c19639`, Todo=`5b29433f`, In Progress=`f976f276`, In Review=`21fe405d`, Done=`293c559f`

### 📓 Findings from bootstrap (learn from these, don't re-learn)

- **Add `BabyLogCore` via `File → Add Package Dependencies… → Add Local…`, NOT by drag-drop.** Drag-drop creates a yellow folder group that exposes `.build/`, `Sources/`, `Tests/` as raw files. The correct result is a single `BabyLogCore local` node under **Package Dependencies** with the package cube icon.
- **`gh project field-edit` doesn't exist.** The built-in `Status` field can't be edited via API. That's why we use a custom `Stage` single-select field instead.
- **Shared PAT breaks GitHub's native "N distinct reviewers" approval count.** Approvals are counted via the comment trail (`[agent:<role>] APPROVE`), not via GitHub's review system. See `.agents/AGENTS.md`.
- **Linux `swift test` on `BabyLogCore` runs in <1s.** This is the fast-feedback loop Core agents TDD against. iOS tests only run on CI macos-14 (~5–7min cycle).
- **CLAUDE.md off-limits list applies to managed agents, not the human owner's local Claude Code.** The owner can edit `.github/workflows/*.yml`, `fastlane/*`, `CLAUDE.md`, `.agents/*`, and `BabyLog.xcodeproj/*`; agents cannot.

## Tech stack

- **iOS 26+**, **Swift 6**, **SwiftUI**
- **`BabyLogCore` Swift Package** — pure Swift, cross-platform, holds all domain logic. Tests run on Linux in sub-seconds. This is where the majority of TDD cycles happen.
- **`BabyLog` iOS app target** — imports `BabyLogCore`, adds SwiftUI views, `@Observable` view models, SwiftData `@Model` types, CloudKit sync. Tests run only on macOS via GitHub Actions.
- **SwiftData** for local persistence, **CloudKit** for two-device sync (owner ↔ wife)
- **XCTest** for unit + UI tests
- **Fastlane** → TestFlight for delivery
- **GitHub Actions** on `macos-14` runners for CI

No third-party dependencies unless a PR explicitly justifies one. Prefer the standard library and Apple frameworks.

**Typed throws** (Swift 6) are used for domain errors: `func save() throws(FeedLogError)`.

## Commands

Run from repo root (`BabyLog/`).

```bash
# Run all tests on iPhone 16 simulator
xcodebuild test \
  -project BabyLog.xcodeproj \
  -scheme BabyLog \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO | xcpretty

# Build only
xcodebuild build \
  -project BabyLog.xcodeproj \
  -scheme BabyLog \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO

# Fastlane (if bundle installed)
bundle exec fastlane test        # run test lane
bundle exec fastlane beta        # ship to TestFlight (CI only)
```

Always run the full test suite before opening a PR. A failing suite is a hard stop — never mark work complete on red.

## TDD is mandatory — red / green / refactor

**Every feature, bug fix, and behavior change ships test-first. No exceptions.**

The loop:

1. **RED** — write the smallest failing test that expresses the new behavior. Run it. Confirm it fails *for the expected reason* (not a compile error from a missing symbol — that's a stub, not a test).
2. **GREEN** — write the minimum production code to make the test pass. Resist adding anything beyond what the test requires. Ugly is fine at this step.
3. **REFACTOR** — with the test green, clean up the code *and the test*. Remove duplication, rename, extract. Re-run tests after every small change. Commit at green only.

**Rules the agents must follow:**

- **One failing test at a time.** Do not write three tests and then three implementations. One test → one impl → refactor → commit.
- **Commit on green.** Every commit must leave the suite passing. Never push red.
- **Test names describe behavior, not implementation.** `test_feedLog_rejectsVolumeGreaterThan500ml` — not `test_saveFunction`.
- **Arrange / Act / Assert structure** in every test, with blank lines between sections.
- **Test the public surface, not private internals.** If you need to test a private, the public API is probably wrong.
- **No test is allowed to depend on another test, wall-clock time, network, or the host filesystem** outside the test bundle's temp dir. Inject clocks, inject dependencies.
- **Coverage is a lagging indicator, not a goal.** Don't write tests to chase a number — write them to pin behavior you care about.
- **If you can't write a failing test first, stop and ask why.** Usually the design is forcing you into a test-hostile shape; fix the design.

**What *not* to test:**
- SwiftUI view bodies directly — test the view models / state, not the view tree.
- Apple framework behavior (don't test that `Date` works).
- Generated code.

## Swift & SwiftUI conventions

- **Swift API Design Guidelines** are authoritative: https://www.swift.org/documentation/api-design-guidelines/
- Prefer **`struct` over `class`**. Reach for `class` only when identity or reference semantics are required (e.g., `ObservableObject` when `@Observable` macro isn't suitable).
- **`@Observable` macro** for view models, not `ObservableObject` + `@Published`.
- **`let` by default**, `var` only when mutation is required.
- **No force unwraps (`!`) and no force-try (`try!`) in production code.** `fatalError` is only for genuinely unreachable invariants, with a message explaining why. Tests may use `XCTUnwrap` or `try` that throws.
- **Avoid `@MainActor` on everything.** Mark only what must run on the main actor. Keep models and business logic actor-agnostic and testable off-main.
- **`async/await` over completion handlers.** `Task` over `DispatchQueue`.
- **Error handling:** typed `Error` enums per domain (e.g., `FeedLogError.volumeOutOfRange`). No throwing generic `NSError`.
- **No singletons** (`.shared`) for anything the agents write. Inject dependencies via initializer. Use a lightweight DI container only if more than three layers deep.
- **Naming:**
  - Types: `UpperCamelCase`
  - Methods, properties, cases: `lowerCamelCase`
  - Files: match the primary type (`FeedLog.swift` contains `struct FeedLog`)
  - Test files: `<TypeName>Tests.swift`
- **Access control:** start `internal` (default). Mark `private` when nothing outside the file uses it. `public` is only for deliberate module boundaries.
- **SwiftUI views**: small, composable, parameterized. No view over ~150 lines — split or extract subviews.
- **State ownership:** source of truth lives in a view model or SwiftData model. Views are pure projections.
- **Previews required** for every new view (`#Preview { ... }`).
- **Accessibility**: every interactive element has an `.accessibilityLabel` and, where relevant, `.accessibilityHint`. This is non-negotiable — the app is used one-handed while holding a baby.

## Architecture

```
BabyLog/                              (Xcode project root)
├── BabyLogCore/                      (local Swift Package — pure Swift, no iOS frameworks)
│   ├── Package.swift
│   ├── Sources/BabyLogCore/
│   │   ├── Models/                   (Feed, Diaper, Growth, Milestone, typed errors)
│   │   ├── Repositories/             (protocols + in-memory impls)
│   │   ├── Analytics/                (cluster feed, trends, aggregations)
│   │   ├── Validation/               (invariants at construction)
│   │   └── Clock/                    (injected time primitives)
│   └── Tests/BabyLogCoreTests/       (runs on Linux via `swift test`)
│
├── BabyLog/                          (iOS app target — imports BabyLogCore)
│   ├── App/                          (entry point, navigation, composition)
│   ├── Features/
│   │   └── <Feature>/
│   │       ├── Views/                (SwiftUI, no logic, projects VM state)
│   │       ├── ViewModels/           (@Observable, thin over BabyLogCore services)
│   │       └── Persistence/          (SwiftData @Model + CloudKit adapters)
│   └── DesignSystem/                 (reusable styled components, tokens)
│
├── BabyLogTests/                     (iOS-only tests: VMs, SwiftData round-trips)
└── BabyLogUITests/                   (XCUITest — used sparingly)
```

**Hard rules:**

- **`BabyLogCore` is pure Swift.** No `import UIKit`, `SwiftUI`, `SwiftData`, `CloudKit`, or `CoreLocation` anywhere under `BabyLogCore/`. Reviewer enforces this with grep.
- **Logic lives in Core.** Any conditional on domain state, any derived value, any validation — it belongs in `BabyLogCore`, not in a view or a view model. If you're tempted to put an `if` on a domain value in a VM, stop and move it to Core.
- **View models are thin.** They wrap `BabyLogCore` services and expose `@Observable` state. They do not contain business logic.
- **Views are dumb.** They project VM state into SwiftUI. No conditionals on domain state; no derived strings; no side effects in view bodies.
- **SwiftData `@Model` classes stay in `BabyLog/Features/*/Persistence/`.** They are wrapped by adapter classes that implement `BabyLogCore` repository protocols, translating `@Model` ↔ domain types.
- **Features do not import each other.** Cross-feature communication goes through `BabyLogCore` protocols.
- **A feature is "done" only when**: Core types + Core tests + VM + VM tests + View + `#Preview` + accessibility + design spec implementation are all present and CI is green.

## Git & PR hygiene

- **Branch naming**: `feat/<scope>/<short-name>`, `fix/<scope>/<short-name>`, `chore/<scope>/<short-name>`.
- **Commits are small, atomic, and on green.** Conventional commits: `feat:`, `fix:`, `test:`, `refactor:`, `chore:`, `docs:`.
- **Agent attribution**: every commit message and PR comment must include `[agent:<role>]` prefix (e.g., `[agent:fe] feat: add FeedLog entry form`). This makes the audit trail legible.
- **PR size cap: 400 lines changed.** If a task requires more, split it.
- **PR description template**: What changed · Why · How tested (list of new tests) · Screenshots for UI changes.
- **Definition of Done for a PR:** all tests green in CI, reviewer agent ✅, security agent ✅, tester agent ✅, PR description filled in, linked to the board card.
- **No agent merges its own PR.** Only PM merges after all three approvals land.
- **Never force-push `main`.** Feature branches may be force-pushed before review only.
- **Never commit secrets.** `.secrets/` is outside the repo; if you see a token in code, stop and alert the user.

## Files and areas that are off-limits to agents

These can only be changed by the human owner:

- `.github/workflows/*.yml` — CI pipelines
- `fastlane/*` — delivery config
- `BabyLog.xcodeproj/*` — project file (except target membership for new source files, which Xcode manages)
- `.agents/*` — agent system prompts (prevents self-rewriting)
- `CLAUDE.md` — this file, **except** the `### ✅ Done` bullet list and the `**Last updated:**` line under *Bootstrap progress*, which agents must keep current (see policy note at top of that section)
- `.secrets/*` — doesn't live in repo, but mentioned for completeness

Agents may **propose** changes to these by opening an issue tagged `needs:human`.

## Things that bite

- **Simulator selection in CI vs local**: CI pins `iPhone 16`. If you add a test that only passes on a specific OS, pin the runtime too.
- **CloudKit schema changes are one-way in production.** Plan migrations deliberately. Never rename a field that's shipped.
- **SwiftData + CloudKit** requires all `@Model` fields to have defaults or be optional. CloudKit doesn't allow required new fields on existing records.
- **`@MainActor` + async tests** can deadlock if you block the main thread. Keep test bodies non-blocking.
- **Snapshot tests** are brittle across Xcode versions. Prefer behavior tests on view models.
- **Photos**: baby photos are sensitive. Never log image data, never send to third-party services, store encrypted at rest where possible.

## When in doubt

1. Write the failing test first.
2. Read this file again.
3. Read `.agents/<your-role>.md`.
4. If still stuck, open an issue tagged `needs:human` and stop. Do not guess on architecture.
