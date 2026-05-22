# AGENTS.md

Contract for the seven managed Claude agents that build BabyLog. Every agent reads `CLAUDE.md` first, then this file, then its own role file. If a rule here conflicts with `CLAUDE.md`, **`CLAUDE.md` wins**.

## The team

| Role | File | Model | Triggered by |
|---|---|---|---|
| **PM / Orchestrator** | `pm.md` | Opus | Cron (every 30 min, 08:00–22:00 local) |
| **Designer** | `designer.md` | Opus | PM (on UI card with `needs:design`) |
| **Core Builder** | `core.md` | Sonnet | PM (on `agent:core` card in Todo) |
| **UI Builder** | `ui.md` | Sonnet | PM (on `agent:ui` card with `design:ready`) |
| **Code Reviewer** | `reviewer.md` | Opus | PM (on PR open / update) |
| **Security Reviewer** | `security.md` | Opus | PM (on PR open / update) |
| **Tester** | `tester.md` | Sonnet | PM (on PR open / update) |

Only **PM** moves cards between Stage columns and merges PRs. All other roles produce artifacts (specs, PRs, review comments) and exit.

## Why split Core and UI

The split is driven by **test execution speed**, not a web metaphor.

- **Core** lives in a pure Swift Package (`BabyLogCore/`). Tests run in the agent's Linux container via `swift test` in under a second. Strict red/green/refactor TDD is practical.
- **UI** lives in the iOS app target. Tests require `xcodebuild` on macOS, which only runs on GitHub Actions (~5–7 min per run). Strict red-first TDD is too slow to be useful at that cycle time.

Each builder role matches its test strategy to its feedback loop. Both produce tested code — the rigor model differs.

## The board

GitHub Projects board: `https://github.com/users/weewey/projects/1`

**Stage** field (single-select):

```
Backlog  →  Todo  →  In Progress  →  In Review  →  Done
```

**Labels**:

- Agent lanes: `agent:pm` · `agent:designer` · `agent:core` · `agent:ui` · `agent:reviewer` · `agent:security` · `agent:tester`
- Priority: `priority:high` · `priority:med` · `priority:low`
- Type: `type:feature` · `type:bug` · `type:chore`
- Design gating: `needs:design` (UI card has no spec) · `design:ready` (spec exists)
- Escalation: `needs:human` (PM stops touching this card)

## End-to-end flow

```
1. Human drops an epic into Backlog.
2. PM cron fires. PM inspects Backlog.
3. If epic: PM labels it `needs:human` for manual splitting. Phase 1 does not auto-split.
4. Human splits epic into child cards:
     - agent:core card for domain logic
     - agent:ui card labeled `needs:design` for view work
5. PM picks highest-priority Todo card.
6a. If agent:core → move to In Progress, dispatch Core builder.
6b. If agent:ui + `needs:design` → move to In Progress, dispatch Designer.
6c. If agent:ui + `design:ready` + upstream Core PR merged → dispatch UI builder.
7. Designer writes the design spec as a card comment, swaps `needs:design` → `design:ready`, exits.
   Card goes back to Todo; next PM tick picks it up.
8. Core/UI builder does the work on a `feat/<slug>` branch, opens a PR, exits.
9. PM moves the card to In Review, dispatches Reviewer + Security + Tester in parallel.
10. Each reviewer posts exactly one approval comment on the PR (see Approval counting).
11. PM counts approvals on next tick. All 3 APPROVE + CI green → squash-merge, move to Done.
    Any REQUEST_CHANGES or CI red → move to In Progress, re-dispatch the builder.
12. On merge, TestFlight workflow fires automatically.
```

## Test execution

Tests run in two places depending on what you're testing:

1. **`BabyLogCore` Swift Package (in-session, Linux)** — `swift test --package-path BabyLogCore`. Covers domain models, repositories, analytics, validation. Sub-second feedback. Core builder runs this every TDD cycle.
2. **GitHub Actions `macos-14` runner (via push)** — `xcodebuild test` on the iOS app target. Covers view models, SwiftData, SwiftUI, CloudKit glue. 5–7 min per run. UI builder and Tester rely on this.

Agents **do not run `xcodebuild` in their own container** — it is macOS-only and the container is Linux. The workflow for UI-layer changes is: push commit → poll `gh pr checks <PR#>` → read result → iterate.

**Rule: keep logic in `BabyLogCore` whenever possible.** If you find yourself writing a conditional, a computation, or a validation in a view or view model, stop and ask whether it belongs in Core. Reviewer enforces this with grep-based checks.

## Approval counting

All agents share one GitHub PAT, so all reviews appear as the same GitHub user. Branch protection's "require N reviewers" counts distinct users — unusable for us. **Authoritative approval signal is the comment trail.**

Each reviewer role posts **exactly one top-level comment per PR**:

```
[agent:reviewer] APPROVE
[agent:reviewer] REQUEST_CHANGES: <one-line reason>

[agent:security] APPROVE
[agent:security] REQUEST_CHANGES: <one-line reason>

[agent:tester] APPROVE
[agent:tester] REQUEST_CHANGES: <one-line reason>
```

Reviewers may also submit a GitHub review for UI, but the comment trail is authoritative.

**Merge gate (PM checks):** three APPROVE comments present, CI green, no subsequent REQUEST_CHANGES from the same role. If a reviewer changes its mind on re-review, it posts a new APPROVE or REQUEST_CHANGES comment — PM uses the **most recent** verdict per role.

## Hard rules (every agent)

1. **Read `CLAUDE.md` on every session start.** Rules change; don't rely on memory.
2. **Stay in your lane.** If a card is not labeled for your role, stop and comment on the card.
3. **Never modify off-limits files** (`CLAUDE.md`, `.agents/*`, `.github/workflows/*`, `fastlane/*`, `BabyLog.xcodeproj/*` except via Xcode-managed target membership). Escalate via `needs:human`.
4. **Test discipline matches your lane.** Core: strict red-first TDD with committed failing tests. UI: tests ship in the same commit as the code. Both: no PR without tests.
5. **Push passing commits to `main`.** Feature branches may carry red WIP commits (e.g., Core's red-first `test:` commit). `main` must always be green.
6. **`[agent:<role>]` prefix on every commit, comment, PR title, review.** Auditability is non-negotiable.
7. **No agent merges its own PR.** Only PM merges, and only when all three approval comments + CI green are present.
8. **If stuck, escalate.** `needs:human` label + comment with the specific question, exit. Do not guess on architecture.
9. **Never commit secrets or reference `.secrets/` paths in code.**
10. **PRs ≤ 400 lines changed.** If a card is bigger, stop and tell PM to split it.
11. **No persistent workdir.** Every session starts fresh. Clone, work, push, exit. State lives in GitHub.
12. **No rewriting git history** on pushed commits. No `rebase -i`, no `filter-branch`, no `--amend` after push.

## Session startup (every role)

1. Clone `git@github.com:weewey/BabyLog.git`
2. `cd BabyLog` (the Xcode project root)
3. Read `CLAUDE.md` → `.agents/AGENTS.md` → `.agents/<your-role>.md`
4. Read the assigned card in full (title, body, comments, labels, linked PR)
5. Post a plan comment on the card: `[agent:<role>] plan: ...` (≤ 10 bullets)
6. Do the work per your role file
7. Post results (PR, review comment, or escalation)
8. Exit cleanly

## Dispatch protocol (how PM triggers other agents)

PM does **not** directly spawn Managed Agent sessions. PM declares dispatch intent by:

1. Moving the card to the appropriate Stage column
2. Posting `[agent:pm] dispatch: <role> for card #<N>` on the card (or comma-separated for parallel reviewer dispatch)
3. Exiting

An external orchestrator (a small script running alongside the cron) reads PM's exit state, sees the dispatch comments, and calls the Anthropic Managed Agents API to spawn the target role's session with that role's system prompt and the card ID as input.

The orchestrator is out of scope for this document. Its behavior is: "for each new `[agent:pm] dispatch:` comment on any card, spawn the named role with the card ID." Failures in dispatch surface as orphans on the board, which PM detects and re-declares on the next tick.

## Failure handling

- **CI red on a PR**: PM comments `[agent:pm] CI failed, redispatching`, moves card to In Progress, re-dispatches the original builder with a link to the failing run.
- **REQUEST_CHANGES from any reviewer**: same pattern — card goes back to In Progress with the review comment linked.
- **Orphan detection**: card in In Progress for >2 hours with no branch pushed and no PR opened → assume the builder session died. Re-dispatch.
- **3 consecutive failures on one card**: PM labels `needs:human`, posts failure history, stops touching the card.

## What agents may NOT do

- Create new labels, board fields, or columns
- Change branch protection rules
- Rotate or read secrets
- Talk to any external service that is not GitHub, Apple Developer, or the Anthropic API
- Install new third-party Swift packages without a `needs:human` escalation
- Merge to `main` without all three approval comments + green CI
- Delete issues or PRs (close only)
- Rewrite git history on pushed commits
- Self-assign work outside their role's lane
