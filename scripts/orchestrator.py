#!/usr/bin/env python3
"""
BabyLog orchestrator — iteration 3.

Fully autonomous pipeline: PM tick → agent dispatch → branch/PR creation →
reviewer dispatch → auto-merge → card moves to Done.

Two phases per tick:
  Phase 1 (PM): gather context → PM session → parse actions → apply
  Phase 2 (PR lifecycle): for each open PR, advance it one step:
    - CI pending → skip
    - CI green + no review → dispatch reviewer
    - Reviewer APPROVE + CI green → merge → move card to Done
    - Reviewer REQUEST_CHANGES → post comment, label needs:human
    - CI failed → post comment

Usage:
  python scripts/orchestrator.py               # full tick
  python scripts/orchestrator.py --dry-run     # don't post or apply
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import anthropic

REPO_ROOT = Path(__file__).resolve().parent.parent
SECRETS = REPO_ROOT.parent / ".secrets" / "agents.env"
AGENTS_FILE = REPO_ROOT / "scripts" / "agents.json"
REPO = os.environ.get("GITHUB_REPOSITORY", "weewey/BabyLog")
PM_LOG_ISSUE = 2

PROJECT_ID = "PVT_kwHOALfRGc4BUXhq"
STAGE_FIELD_ID = "PVTSSF_lAHOALfRGc4BUXhqzhBgKZ8"
STAGE_OPTIONS = {
    "Backlog": "a9c19639",
    "Todo": "5b29433f",
    "In Progress": "f976f276",
    "In Review": "21fe405d",
    "Done": "293c559f",
}


def load_env() -> str:
    if SECRETS.exists():
        for line in SECRETS.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        sys.exit("ANTHROPIC_API_KEY not set (either in env or .secrets/agents.env)")
    return key


def gh(*args: str) -> str:
    result = subprocess.run(
        ["gh", *args], check=True, capture_output=True, text=True,
    )
    return result.stdout


def run_cmd(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(args, check=check, capture_output=True, text=True)


# ---------------------------------------------------------------------------
# Board context
# ---------------------------------------------------------------------------

def resolve_item_id(issue_number: int) -> str | None:
    query = (
        '{user(login:"weewey"){projectV2(number:1){items(first:100)'
        '{nodes{id content{...on Issue{number}}}}}}}'
    )
    raw = gh("api", "graphql", "--raw-field", f"query={query}",
             "--jq", f'.data.user.projectV2.items.nodes[] | select(.content.number == {issue_number}) | .id')
    return raw.strip() or None


def get_board_stages() -> dict[int, str]:
    try:
        raw = gh(
            "project", "item-list", "1", "--owner", "weewey",
            "--format", "json",
        )
    except subprocess.CalledProcessError:
        return {}
    items = json.loads(raw).get("items", [])
    return {
        item["content"]["number"]: item.get("stage") or "none"
        for item in items
        if item.get("content", {}).get("number")
    }


def gather_context() -> str:
    issues = json.loads(gh(
        "issue", "list", "-R", REPO,
        "--state", "all",
        "--json", "number,title,labels,body,state",
        "--limit", "50",
    ))

    stages = get_board_stages()

    try:
        prs = json.loads(gh(
            "pr", "list", "-R", REPO, "--state", "open",
            "--json", "number,title,headRefName",
            "--limit", "20",
        ))
    except subprocess.CalledProcessError:
        prs = []

    comments = json.loads(gh(
        "issue", "view", str(PM_LOG_ISSUE), "-R", REPO,
        "--json", "comments",
    )).get("comments", [])
    last_3 = comments[-3:] if comments else []

    lines = ["## Open issues on the board\n"]
    for i in issues:
        stage = stages.get(i["number"])
        if not stage:
            continue
        labels = ", ".join(l["name"] for l in i.get("labels", []))
        state = i.get("state", "OPEN")
        lines.append(f"### #{i['number']}: {i['title']}")
        lines.append(f"Stage: **{stage}** | State: {state}")
        if labels:
            lines.append(f"Labels: {labels}")
        body = (i.get("body") or "").strip()
        if body:
            snippet = body[:500] + ("…" if len(body) > 500 else "")
            lines.append(f"Body: {snippet}")
        lines.append("")

    if prs:
        lines.append("## Open PRs\n")
        for pr in prs:
            lines.append(f"- PR #{pr['number']}: {pr['title']} (branch: {pr['headRefName']})")
        lines.append("")

    lines.append("## Last 3 pm-log comments\n")
    if not last_3:
        lines.append("(none — this is the first tick)")
    else:
        for c in last_3:
            author = c.get("author", {}).get("login", "?")
            created = c.get("createdAt", "")
            lines.append(f"- **{author}** at {created}:")
            lines.append(f"  {(c.get('body') or '').strip()[:500]}")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Session prompts
# ---------------------------------------------------------------------------

def build_pm_prompt(context: str) -> str:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return f"""This is a PM tick at {ts}. You are running in **Option A mode**: the orchestrator is the only thing that touches GitHub. You do not have the repo cloned, no gh CLI, no network. All actions you want the orchestrator to take must be declared in your reply text in the format shown below.

Below is the current state of the board. Read it, then reply with:

1. A short markdown tick summary, starting with: `[agent:pm] tick {ts}`
2. Zero or more action lines, each on its own line at the end of the reply:
   - `LABEL #<issue> <label>` — add a label
   - `UNLABEL #<issue> <label>` — remove a label
   - `STAGE #<issue> <Backlog|Todo|In Progress|In Review|Done>` — move card to stage
   - `DISPATCH <role> #<issue>` — dispatch a downstream agent

Available roles for DISPATCH: **core, ui, designer**. Reviewer, Security, and Tester are dispatched automatically by the PR lifecycle — do NOT dispatch them manually.

Design gating: cards labeled `agent:ui` whose title/body mentions "views", "form", "entry view", "list view" need a design spec first. If such a card has `needs:design`, dispatch **designer** for it. VM-only cards and persistence/adapter cards do NOT need design specs — dispatch `ui` directly.

**Epics** (issues whose title starts with "Epic:") are tracking issues, NOT actionable cards. Do NOT add `needs:human` to epics. If an epic currently has `needs:human`, emit `UNLABEL #N needs:human` to remove it. Do NOT dispatch agents for epics. Epics stay in Backlog until all child cards are Done, then move to Done.

Cards that already have an open PR (listed in the Open PRs section) are being handled by the automated PR lifecycle. Do NOT re-dispatch them. Do NOT move them. The orchestrator handles PR review, merge, and stage transitions automatically.

The Stage field shown below is the AUTHORITATIVE board state. Trust Stage over prior pm-log comments if they conflict — prior tick actions may have been stubbed.

If there is nothing to do this tick, say so and emit no action lines.

--- BEGIN BOARD STATE ---
{context}
--- END BOARD STATE ---

Now produce the tick comment and any action lines. Be concise. Do not use any tools."""


def build_core_prompt(card: dict) -> str:
    labels = ", ".join(card.get("labels", [])) or "(none)"
    return f"""MODE: Core Builder, sandboxed. No gh, no git, no network, no repo clone. The orchestrator owns all GitHub I/O — you only produce text.

You are the BabyLog Core agent. Normally you clone, run `swift test --package-path BabyLogCore`, TDD red/green/refactor, push, open a PR. In this session you cannot do any of that. Instead you emit file contents and the orchestrator commits + pushes them on your behalf.

Contract you must honour:
- Lane: only files under `BabyLogCore/Sources/BabyLogCore/` and `BabyLogCore/Tests/BabyLogCoreTests/`. Nothing under `BabyLog/`, `.agents/`, `.github/`, `BabyLog.xcodeproj/`, `CLAUDE.md`, `fastlane/`.
- ZERO iOS imports in BabyLogCore: no UIKit, SwiftUI, SwiftData, CloudKit, CoreLocation, Combine.
- Strict TDD: for every production type, include a `<TypeName>Tests.swift` file with behaviour tests (AAA-style). Both the test and the impl must be present.
- Domain rules: struct-first, failable/throwing init with typed errors (Swift 6 `throws(FooError)`), inject a `Clock` (never call `Date()`), `let`-by-default, no singletons, no force unwraps.
- PR size cap: ≤400 changed lines total across all FILE blocks.
- If the card needs any iOS framework type, a new SwiftPM dependency, or the spec is ambiguous — STOP and escalate.

Card context:
  #{card['number']} — {card['title']}
  Labels: {labels}
  Body:
  \"\"\"
  {card.get('body') or '(empty)'}
  \"\"\"

REPLY FORMAT (parsed literally by the orchestrator):

Line 1: `[agent:core] plan:` followed by ≤10 semicolon-separated bullets.

Then one or more file blocks:

FILE <repo-relative path starting with BabyLogCore/>
<full file contents, no fences, no line numbers>
FILE <next path>
<full file contents>
...
FILES_END

Paths MUST start with `BabyLogCore/`. Contents are the COMPLETE file as it should exist on disk. The final line must be `FILES_END`.

Escalation: if you cannot do the card within your lane, reply with:
  [agent:core] plan: <why this needs to escalate>
  ESCALATE needs:human: <one-line reason>
  FILES_END

Do not reference gh, git, branches, or PRs. Do not use any tools."""


def build_reviewer_prompt(card: dict, pr_diff: str) -> str:
    labels = ", ".join(card.get("labels", [])) or "(none)"
    return f"""MODE: Code Reviewer, sandboxed. No gh, no git, no network, no checkout. Review from the pre-fetched diff below.

You are the BabyLog Code Reviewer. You do not write code; you APPROVE or REQUEST_CHANGES.

What you review for:
1. Architecture boundaries — BabyLogCore must not import UIKit/SwiftUI/SwiftData/CloudKit. Logic in Core, not views/VMs. Off-limits files untouched.
2. TDD compliance — every new production type has a corresponding *Tests.swift with behaviour tests. AAA, no Date(), no network, no filesystem.
3. Swift correctness — no force unwraps, no try!, typed errors, @Observable not ObservableObject, let-by-default, #Preview on every new view, .accessibilityLabel on every interactive element.
4. Simplicity and scope — diff does only what the card asks, ≤400 lines, naming describes behaviour.

Card context:
  #{card['number']} — {card['title']}
  Labels: {labels}
  Body:
  \"\"\"
  {card.get('body') or '(empty)'}
  \"\"\"

PR diff:
<<<DIFF
{pr_diff}
DIFF>>>

REPLY FORMAT:

Line 1: `[agent:reviewer] plan:` followed by ≤10 semicolon-separated bullets of what you checked.

Then zero or more inline comments:
  INLINE <path>:<line> — <comment>

Then exactly one verdict line:
  [agent:reviewer] APPROVE
  <one-line summary>

OR

  [agent:reviewer] REQUEST_CHANGES: <headline>

  must:
  1. <file:line> — <issue> — <rule violated>

  should:
  1. ...

  nit:
  1. ...

Only `must:` items block approval. If zero must items, you MUST APPROVE.
Do not reference gh, git, or posting. Do not use any tools."""


def build_ui_prompt(card: dict) -> str:
    labels = ", ".join(card.get("labels", [])) or "(none)"
    return f"""MODE: UI Builder, sandboxed. No gh, no git, no network, no repo clone. The orchestrator owns all GitHub I/O — you only produce text.

You are the BabyLog UI agent. You build @Observable view models, SwiftData @Model types, CloudKit adapters, and SwiftUI views. In this session you cannot clone, build, or push. Instead you emit file contents and the orchestrator commits + pushes them on your behalf.

Contract you must honour:
- Lane: only files under `BabyLog/Features/`, `BabyLog/App/`, `BabyLog/DesignSystem/`, `BabyLogTests/`. Nothing under `BabyLogCore/`, `.agents/`, `.github/`, `BabyLog.xcodeproj/`, `CLAUDE.md`, `fastlane/`.
- You import `BabyLogCore` and depend on its types and protocols. Do NOT re-implement or copy logic from Core.
- No logic in views or view models: conditionals on domain state, derived values, validations, computations belong in `BabyLogCore`. If a Core service doesn't exist, ESCALATE.
- View models use `@Observable` macro (not ObservableObject + @Published).
- SwiftData `@Model` classes: `final`, every field has a default or is Optional (CloudKit requirement).
- Repository adapters translate `@Model` ↔ domain types, implementing `BabyLogCore` protocols.
- Every new view model must have tests. Tests and implementation go together.
- Every new view must have a `#Preview`.
- Every interactive element needs `.accessibilityLabel` and `.accessibilityHint`.
- PR size cap: ≤400 changed lines total across all FILE blocks.

Card context:
  #{card['number']} — {card['title']}
  Labels: {labels}
  Body:
  \"\"\"
  {card.get('body') or '(empty)'}
  \"\"\"

REPLY FORMAT (parsed literally by the orchestrator):

Line 1: `[agent:ui] plan:` followed by ≤10 semicolon-separated bullets.

Then one or more file blocks:

FILE <repo-relative path starting with BabyLog/ or BabyLogTests/>
<full file contents, no fences, no line numbers>
FILE <next path>
<full file contents>
...
FILES_END

Paths MUST start with `BabyLog/` or `BabyLogTests/`. Contents are the COMPLETE file as it should exist on disk. The final line must be `FILES_END`.

Escalation: if you cannot do the card within your lane, reply with:
  [agent:ui] plan: <why this needs to escalate>
  ESCALATE needs:human: <one-line reason>
  FILES_END

Do not reference gh, git, branches, or PRs. Do not use any tools."""


def build_designer_prompt(card: dict) -> str:
    labels = ", ".join(card.get("labels", [])) or "(none)"
    return f"""MODE: Designer, sandboxed. No gh, no git, no network, no repo clone.

You are the BabyLog Designer agent. You translate a UI card's acceptance criteria into a concrete, implementable design spec. You write no code, open no PRs, touch no files.

Your output is a single design spec that covers:
1. Purpose — one sentence, user outcome
2. Screen layout — ASCII wireframe
3. States — empty, valid, invalid, loading, error, success
4. Interactions — every tap/swipe/focus with effect
5. Navigation — where in the app, how entered/dismissed
6. Accessibility — labels, hints, VoiceOver focus order
7. Design tokens — use existing ones from DesignSystem/ (or note missing ones)
8. Out of scope — what this card does NOT cover
9. Open questions — any ambiguities

Card context:
  #{card['number']} — {card['title']}
  Labels: {labels}
  Body:
  \"\"\"
  {card.get('body') or '(empty)'}
  \"\"\"

REPLY FORMAT:
[agent:designer] spec:
<full design spec in markdown>

After the spec, on a separate line:
LABEL #{card['number']} design:ready
UNLABEL #{card['number']} needs:design

If you cannot complete the spec (missing token, ambiguous AC), reply with:
[agent:designer] ESCALATE: <reason>
LABEL #{card['number']} needs:human

Do not reference gh, git, branches, or PRs. Do not use any tools."""


def build_security_prompt(card: dict, pr_diff: str) -> str:
    labels = ", ".join(card.get("labels", [])) or "(none)"
    return f"""MODE: Security Reviewer, sandboxed. No gh, no git, no network.

You are the BabyLog Security Reviewer. Read the PR diff below through a security lens. BabyLog stores data about a real child — feed times, diaper events, photos, medical appointments. This is health-adjacent personal data about a minor.

Check for:
1. Credentials in code (github_pat_, AuthKey_, private keys, api keys)
2. PII in log calls (baby names, photo data, health data in print/NSLog/Logger)
3. Data at rest without FileProtection
4. Non-Apple network calls (only *.apple.com, *.icloud.com allowed)
5. Credentials in UserDefaults (must use Keychain)
6. New third-party dependencies (always REQUEST_CHANGES)
7. Photos handled via PHPickerViewController only
8. Off-limits files modified (.github/, fastlane/, CLAUDE.md, .agents/, .xcodeproj/)

Card: #{card['number']} — {card['title']}
Labels: {labels}

PR diff:
<<<DIFF
{pr_diff}
DIFF>>>

REPLY FORMAT:

If clean:
[agent:security] APPROVE
<one-line summary>

If findings:
[agent:security] REQUEST_CHANGES: <headline>
1. [severity] <file:line> — <risk> — <fix>
2. ...

Do not reference gh, git, or posting. Do not use any tools."""


def build_tester_prompt(card: dict, pr_diff: str) -> str:
    labels = ", ".join(card.get("labels", [])) or "(none)"
    return f"""MODE: Tester, sandboxed. No gh, no git, no network.

You are the BabyLog Tester agent. Verify the PR's test coverage against the card's acceptance criteria.

Check:
1. Every AC bullet on the card has a corresponding test
2. Test quality: descriptive names (test_subject_behavior), AAA structure, no Date()/URLSession.shared
3. TDD rhythm for Core PRs: test: commit before feat: commit
4. VM-test coupling for UI PRs: VM file has accompanying Tests.swift
5. Edge cases: identify 1-2 important missing ones
6. Tests test public surface, not internals

Card: #{card['number']} — {card['title']}
Labels: {labels}
Body:
\"\"\"
{card.get('body') or '(empty)'}
\"\"\"

PR diff:
<<<DIFF
{pr_diff}
DIFF>>>

REPLY FORMAT:

If coverage is adequate:
[agent:tester] APPROVE
<one-line summary>

If missing coverage:
[agent:tester] REQUEST_CHANGES: <headline>

missing coverage:
1. <AC bullet> — no test found; suggest test_<name>

quality:
1. <file:line> — <issue> — <fix>

edge cases to add:
1. test_<name> — <input> should <output>

Do not reference gh, git, or posting. Do not use any tools."""


# ---------------------------------------------------------------------------
# Session runner (generic)
# ---------------------------------------------------------------------------

def run_agent_session(
    client: anthropic.Anthropic,
    agents: dict,
    role: str,
    prompt: str,
) -> str:
    agent_cfg = agents["agents"][role]
    session = client.beta.sessions.create(
        agent={"type": "agent", "id": agent_cfg["id"]},
        environment_id=agents["environment_id"],
        title=f"{role} {datetime.now(timezone.utc).isoformat(timespec='seconds')}",
    )
    print(f"  [{role}] session_id = {session.id}")

    stream = client.beta.sessions.events.stream(session.id)
    client.beta.sessions.events.send(
        session_id=session.id,
        events=[{
            "type": "user.message",
            "content": [{"type": "text", "text": prompt}],
        }],
    )

    reply_parts: list[str] = []
    for event in stream:
        etype = getattr(event, "type", "")
        if etype == "agent.message":
            for block in (getattr(event, "content", None) or []):
                text = getattr(block, "text", None)
                if text:
                    reply_parts.append(text)
        elif etype == "session.status_terminated":
            break
        elif etype == "session.status_idle":
            stop = getattr(event, "stop_reason", None)
            if getattr(stop, "type", None) != "requires_action":
                break

    return "\n".join(reply_parts).strip()


# ---------------------------------------------------------------------------
# FILE block parsing
# ---------------------------------------------------------------------------

def parse_file_blocks(reply: str) -> list[tuple[str, str]]:
    """Extract (path, content) pairs from FILE <path>...FILES_END blocks."""
    files: list[tuple[str, str]] = []
    lines = reply.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if stripped.startswith("FILE ") and not stripped.startswith("FILES_END"):
            path = stripped[5:].strip().strip("`")
            content_lines: list[str] = []
            i += 1
            while i < len(lines):
                cur = lines[i]
                cur_stripped = cur.strip()
                if cur_stripped == "FILES_END" or (cur_stripped.startswith("FILE ") and not cur_stripped.startswith("FILES_END")):
                    break
                content_lines.append(cur)
                i += 1
            files.append((path, "\n".join(content_lines)))
        else:
            i += 1
    return files


def branch_slug(role: str, issue_number: int, title: str) -> str:
    """Generate a branch name like feat/core/feedlog-domain."""
    slug = re.sub(r'\[.*?\]\s*', '', title).lower()
    slug = re.sub(r'[^a-z0-9]+', '-', slug).strip('-')[:40]
    return f"feat/{role}/{slug}"


# ---------------------------------------------------------------------------
# PR creation from agent reply
# ---------------------------------------------------------------------------

def create_pr_from_reply(
    role: str,
    issue_number: int,
    card: dict,
    reply: str,
) -> str | None:
    """Parse FILE blocks → create branch → commit → push → open PR. Returns PR URL."""
    files = parse_file_blocks(reply)
    if not files:
        print(f"  No FILE blocks found in {role} reply for #{issue_number}")
        return None

    branch = branch_slug(role, issue_number, card["title"])
    print(f"  Creating branch {branch} with {len(files)} file(s)…")

    # Ensure we're on a clean main
    run_cmd("git", "fetch", "origin", "main")
    run_cmd("git", "checkout", "-B", branch, "origin/main")

    # Write files
    total_lines = 0
    for path, content in files:
        full = Path(path)
        full.parent.mkdir(parents=True, exist_ok=True)
        full.write_text(content.rstrip() + "\n")
        total_lines += content.count("\n") + 1
        run_cmd("git", "add", path)

    print(f"  {total_lines} lines across {len(files)} files")

    # Commit
    commit_title = f"[agent:{role}] feat: {card['title']}"
    if len(commit_title) > 72:
        commit_title = commit_title[:69] + "…"
    commit_body = f"Closes #{issue_number}\n\nCo-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
    commit_msg = f"{commit_title}\n\n{commit_body}"
    result = run_cmd("git", "commit", "-m", commit_msg, check=False)
    if result.returncode != 0:
        print(f"  git commit failed: {result.stderr}")
        return None

    # Push
    result = run_cmd("git", "push", "-u", "origin", branch, "--force", check=False)
    if result.returncode != 0:
        print(f"  git push failed: {result.stderr}")
        return None

    # Open PR
    try:
        pr_url = gh(
            "pr", "create",
            "-R", REPO,
            "--base", "main",
            "--head", branch,
            "--title", f"[agent:{role}] {card['title']}",
            "--body", f"## What\n{card['title']}\n\n## Why\nCloses #{issue_number}\n\n"
                      f"## How tested\nAutomated by orchestrator — CI validates.\n\n"
                      f"Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>",
        )
        print(f"  PR opened: {pr_url.strip()}")
        return pr_url.strip()
    except subprocess.CalledProcessError as e:
        print(f"  gh pr create failed: {e.stderr}")
        return None


# ---------------------------------------------------------------------------
# Action parsing and application
# ---------------------------------------------------------------------------

def parse_actions(reply: str) -> list[tuple[str, list[str]]]:
    actions: list[tuple[str, list[str]]] = []
    verbs = {"LABEL", "UNLABEL", "STAGE", "DISPATCH"}
    for line in reply.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) >= 2 and parts[0] in verbs:
            actions.append((parts[0], parts[1].split()))
    return actions


def apply_stage(issue_number: int, stage_name: str) -> str:
    option_id = STAGE_OPTIONS.get(stage_name)
    if not option_id:
        return f"unknown stage '{stage_name}' (valid: {', '.join(STAGE_OPTIONS)})"
    item_id = resolve_item_id(issue_number)
    if not item_id:
        return f"#{issue_number} not found on the project board"
    mutation = (
        'mutation($p:ID!,$i:ID!,$f:ID!,$o:String!){'
        'updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,'
        'fieldId:$f,value:{singleSelectOptionId:$o}}){projectV2Item{id}}}'
    )
    gh("api", "graphql",
       "-f", f"p={PROJECT_ID}",
       "-f", f"i={item_id}",
       "-f", f"f={STAGE_FIELD_ID}",
       "-f", f"o={option_id}",
       "-F", f"query={mutation}")
    return f"moved #{issue_number} → {stage_name}"


def apply_dispatch(
    role: str,
    issue_number: int,
    client: anthropic.Anthropic,
    agents: dict,
) -> str:
    """Dispatch agent → get reply → create PR → move card to In Review."""
    if role not in agents["agents"]:
        return f"unknown role '{role}' (available: {', '.join(agents['agents'])})"

    card_json = gh(
        "issue", "view", str(issue_number), "-R", REPO,
        "--json", "number,title,body,labels",
    )
    card = json.loads(card_json)
    card["labels"] = [l["name"] for l in card.get("labels", [])]

    if role == "core":
        prompt = build_core_prompt(card)
    elif role == "ui":
        prompt = build_ui_prompt(card)
    elif role == "designer":
        prompt = build_designer_prompt(card)
    elif role in ("reviewer", "security", "tester"):
        return f"{role} dispatch for #{issue_number} deferred to PR lifecycle"
    else:
        return f"prompt builder for '{role}' not implemented yet"

    print(f"  Dispatching {role} for #{issue_number}…")
    reply = run_agent_session(client, agents, role, prompt)

    print(f"\n--- {role} reply (#{issue_number}) ---")
    print(reply[:2000] + ("…" if len(reply) > 2000 else ""))
    print(f"--- end {role} ---\n")

    # Check for escalation
    if "ESCALATE" in reply:
        gh("issue", "comment", str(issue_number), "-R", REPO,
           "--body", f"**[orchestrator] {role} escalated:**\n\n{reply}")
        gh("issue", "edit", str(issue_number), "-R", REPO,
           "--add-label", "needs:human")
        return f"{role} escalated for #{issue_number}"

    # Post reply as comment
    gh("issue", "comment", str(issue_number), "-R", REPO,
       "--body", f"**[orchestrator] {role} dispatch result:**\n\n{reply}")

    # Designer produces specs (comments + label changes), not FILE blocks
    if role == "designer":
        # Parse and apply any LABEL/UNLABEL actions from the designer's reply
        designer_actions = parse_actions(reply)
        for verb, action_args in designer_actions:
            result = apply_action(verb, action_args)
            print(f"  designer action: {result}")
        return f"dispatched designer for #{issue_number}, spec posted"

    # Create PR from FILE blocks
    pr_url = create_pr_from_reply(role, issue_number, card, reply)
    if pr_url:
        apply_stage(issue_number, "In Review")
        return f"dispatched {role} for #{issue_number}, PR opened: {pr_url}"
    else:
        return f"dispatched {role} for #{issue_number}, reply posted (no FILE blocks found)"


def apply_action(
    verb: str,
    args: list[str],
    client: anthropic.Anthropic | None = None,
    agents: dict | None = None,
) -> str:
    if verb == "LABEL":
        issue = args[0].lstrip("#")
        label = " ".join(args[1:])
        gh("issue", "edit", issue, "-R", REPO, "--add-label", label)
        return f"labeled #{issue} +{label}"

    if verb == "UNLABEL":
        issue = args[0].lstrip("#")
        label = " ".join(args[1:])
        gh("issue", "edit", issue, "-R", REPO, "--remove-label", label)
        return f"unlabeled #{issue} -{label}"

    if verb == "STAGE":
        issue_num = int(args[0].lstrip("#"))
        stage_name = " ".join(args[1:])
        return apply_stage(issue_num, stage_name)

    if verb == "DISPATCH":
        role = args[0].lower()
        issue_num = int(args[1].lstrip("#"))
        if client is None or agents is None:
            return f"DISPATCH {role} #{issue_num} skipped (no client)"
        return apply_dispatch(role, issue_num, client, agents)

    return f"unknown verb {verb}"


# ---------------------------------------------------------------------------
# PR lifecycle — Phase 2
# ---------------------------------------------------------------------------

def extract_issue_number_from_pr(pr: dict) -> int | None:
    """Extract the linked issue number from PR body (Closes #N)."""
    body = pr.get("body") or ""
    m = re.search(r'[Cc]loses\s+#(\d+)', body)
    return int(m.group(1)) if m else None


LOCAL_CI = os.environ.get("LOCAL_CI", "1") == "1"


def run_local_tests(pr_number: int) -> str:
    """Run BabyLogCore tests locally via `swift test`. Returns 'passed' or 'failed'."""
    branch = ""
    try:
        branch = gh("pr", "view", str(pr_number), "-R", REPO,
                     "--json", "headRefName", "--jq", ".headRefName").strip()
    except subprocess.CalledProcessError:
        return "failed"

    run_cmd("git", "fetch", "origin", branch)
    run_cmd("git", "checkout", branch)

    print(f"    Running local tests on {branch}…")
    result = subprocess.run(
        ["swift", "test", "--package-path", "BabyLogCore"],
        capture_output=True, text=True, timeout=120,
    )
    run_cmd("git", "checkout", "main")
    if result.returncode == 0:
        print("    Local tests passed ✓")
        return "passed"
    print(f"    Local tests failed:\n{result.stderr[-500:]}")
    return "failed"


def get_pr_ci_status(pr_number: int) -> str:
    """Return 'passed', 'failed', or 'pending'.
    In LOCAL_CI mode, runs swift test locally instead of checking GitHub."""
    if LOCAL_CI:
        return run_local_tests(pr_number)

    try:
        proc = subprocess.run(
            ["gh", "pr", "checks", str(pr_number), "-R", REPO],
            capture_output=True, text=True,
        )
        result = proc.stdout
    except Exception:
        return "pending"

    if not result.strip():
        return "pending"

    lines = result.strip().splitlines()
    has_real_failure = False
    all_done = True
    for line in lines:
        lower = line.lower()
        if "pending" in lower or "queued" in lower or "in_progress" in lower:
            all_done = False
        elif "fail" in lower:
            if any(f"\t{s}s\t" in line for s in range(6)):
                print(f"    Ignoring runner-allocation failure: {line.strip()}")
            else:
                has_real_failure = True
    if not all_done:
        return "pending"
    if has_real_failure:
        return "failed"
    return "passed"


def pr_has_agent_verdict(pr_number: int, agent_tag: str) -> tuple[str | None, str | None]:
    """Check PR comments for a specific agent's verdict.
    agent_tag is e.g. 'reviewer', 'security', 'tester'.
    Returns (verdict, review_body) tuple."""
    comments = json.loads(gh(
        "pr", "view", str(pr_number), "-R", REPO,
        "--json", "comments",
    )).get("comments", [])
    for c in reversed(comments):
        body = c.get("body", "")
        if f"[agent:{agent_tag}] APPROVE" in body:
            return ("APPROVE", body)
        if f"[agent:{agent_tag}] REQUEST_CHANGES" in body:
            return ("REQUEST_CHANGES", body)
    return (None, None)


def pr_has_new_commits_since_review(pr_number: int) -> bool:
    """Check if there are commits on the PR after the last reviewer comment."""
    try:
        data = json.loads(gh(
            "pr", "view", str(pr_number), "-R", REPO,
            "--json", "comments,commits",
        ))
    except subprocess.CalledProcessError:
        return False
    review_time = None
    for c in reversed(data.get("comments", [])):
        body = c.get("body", "")
        if "[agent:reviewer]" in body and ("APPROVE" in body or "REQUEST_CHANGES" in body):
            review_time = c.get("createdAt")
            break
    if not review_time:
        return False
    commits = data.get("commits", [])
    if not commits:
        return False
    last_commit_time = commits[-1].get("committedDate") or commits[-1].get("authoredDate", "")
    return last_commit_time > review_time


def extract_role_from_branch(branch: str) -> str | None:
    """Extract the agent role from branch name like feat/core/... → core."""
    parts = branch.split("/")
    if len(parts) >= 2:
        return parts[1]
    return None


def build_fix_prompt(role: str, card: dict, review_body: str) -> str:
    """Build a prompt for the agent to fix reviewer's must-fix items."""
    labels = ", ".join(card.get("labels", [])) or "(none)"
    if role == "core":
        lane_rule = "Only files under `BabyLogCore/Sources/` and `BabyLogCore/Tests/`."
    elif role == "ui":
        lane_rule = "Only files under `BabyLog/Features/`, `BabyLog/App/`, `BabyLogTests/`."
    else:
        lane_rule = "Stay within your designated lanes."

    return f"""MODE: Fix reviewer feedback, sandboxed. No gh, no git, no network.

The reviewer found issues with your previous submission for card #{card['number']}. Fix the must-fix items below and re-emit ALL files (not just changed ones).

Card: #{card['number']} — {card['title']}
Labels: {labels}

Reviewer feedback:
{review_body}

Rules:
- {lane_rule}
- Fix ALL must-fix items. Address should-fix items where reasonable.
- Emit the complete updated files using the FILE block format.
- Do not reference gh, git, branches, or PRs. Do not use any tools.

REPLY FORMAT:
[agent:{role}] plan: <what you fixed>

FILE <path>
<complete file contents>
FILE <next path>
...
FILES_END"""


def run_pr_lifecycle(
    client: anthropic.Anthropic,
    agents: dict,
) -> list[str]:
    """Advance each open PR by one step. Returns list of status strings."""
    results: list[str] = []

    prs = json.loads(gh(
        "pr", "list", "-R", REPO, "--state", "open",
        "--json", "number,title,body,headRefName",
        "--limit", "20",
    ))

    for pr in prs:
        pr_num = pr["number"]
        branch = pr.get("headRefName", "")

        if not branch.startswith("feat/"):
            continue

        issue_num = extract_issue_number_from_pr(pr)
        ci = get_pr_ci_status(pr_num)
        has_new_commits = pr_has_new_commits_since_review(pr_num)

        # Gather verdicts from all three reviewers
        reviewer_verdict, reviewer_body = pr_has_agent_verdict(pr_num, "reviewer")
        security_verdict, _ = pr_has_agent_verdict(pr_num, "security")
        tester_verdict, _ = pr_has_agent_verdict(pr_num, "tester")

        # Reset verdicts if new commits were pushed after the review
        if has_new_commits:
            if reviewer_verdict:
                print(f"  PR #{pr_num}: new commits since reviewer, re-reviewing")
                reviewer_verdict = reviewer_body = None
            if security_verdict:
                security_verdict = None
            if tester_verdict:
                tester_verdict = None

        print(f"\n  PR #{pr_num} ({branch}): CI={ci}, reviewer={reviewer_verdict}, security={security_verdict}, tester={tester_verdict}")

        if ci == "pending":
            results.append(f"PR #{pr_num}: CI pending, skipping")
            continue

        if ci == "failed":
            if not reviewer_verdict:
                gh("pr", "comment", str(pr_num), "-R", REPO,
                   "--body", "**[orchestrator]** CI failed on this PR. Needs investigation.")
            results.append(f"PR #{pr_num}: CI failed")
            continue

        # CI passed — get diff and card context (shared by all reviewers)
        diff = None
        card = {"number": issue_num or 0, "title": pr["title"], "body": pr.get("body", ""), "labels": []}
        if issue_num:
            try:
                card_json = gh("issue", "view", str(issue_num), "-R", REPO,
                               "--json", "number,title,body,labels")
                card = json.loads(card_json)
                card["labels"] = [l["name"] for l in card.get("labels", [])]
            except subprocess.CalledProcessError:
                pass

        def get_diff():
            nonlocal diff
            if diff is None:
                try:
                    diff = gh("pr", "diff", str(pr_num), "-R", REPO)
                except subprocess.CalledProcessError:
                    diff = "(diff unavailable)"
            return diff

        # Dispatch missing reviewers
        if reviewer_verdict is None:
            print(f"  Dispatching reviewer for PR #{pr_num}…")
            review_prompt = build_reviewer_prompt(card, get_diff()[:15000])
            review_reply = run_agent_session(client, agents, "reviewer", review_prompt)
            print(f"  reviewer → {review_reply[:200]}")
            gh("pr", "comment", str(pr_num), "-R", REPO,
               "--body", f"**[orchestrator] reviewer verdict:**\n\n{review_reply}")
            if "[agent:reviewer] APPROVE" in review_reply:
                reviewer_verdict, reviewer_body = "APPROVE", review_reply
            elif "[agent:reviewer] REQUEST_CHANGES" in review_reply:
                reviewer_verdict, reviewer_body = "REQUEST_CHANGES", review_reply
            results.append(f"PR #{pr_num}: reviewer → {reviewer_verdict}")

        if security_verdict is None and "security" in agents.get("agents", {}):
            print(f"  Dispatching security for PR #{pr_num}…")
            sec_prompt = build_security_prompt(card, get_diff()[:15000])
            sec_reply = run_agent_session(client, agents, "security", sec_prompt)
            print(f"  security → {sec_reply[:200]}")
            gh("pr", "comment", str(pr_num), "-R", REPO,
               "--body", f"**[orchestrator] security verdict:**\n\n{sec_reply}")
            if "[agent:security] APPROVE" in sec_reply:
                security_verdict = "APPROVE"
            elif "[agent:security] REQUEST_CHANGES" in sec_reply:
                security_verdict = "REQUEST_CHANGES"
            results.append(f"PR #{pr_num}: security → {security_verdict}")

        if tester_verdict is None and "tester" in agents.get("agents", {}):
            print(f"  Dispatching tester for PR #{pr_num}…")
            test_prompt = build_tester_prompt(card, get_diff()[:15000])
            test_reply = run_agent_session(client, agents, "tester", test_prompt)
            print(f"  tester → {test_reply[:200]}")
            gh("pr", "comment", str(pr_num), "-R", REPO,
               "--body", f"**[orchestrator] tester verdict:**\n\n{test_reply}")
            if "[agent:tester] APPROVE" in test_reply:
                tester_verdict = "APPROVE"
            elif "[agent:tester] REQUEST_CHANGES" in test_reply:
                tester_verdict = "REQUEST_CHANGES"
            results.append(f"PR #{pr_num}: tester → {tester_verdict}")

        # Check if any reviewer requested changes (reviewer verdict is blocking)
        all_verdicts = {"reviewer": reviewer_verdict, "security": security_verdict, "tester": tester_verdict}
        request_changes = {k: v for k, v in all_verdicts.items() if v == "REQUEST_CHANGES"}
        all_approved = all(v == "APPROVE" for v in all_verdicts.values() if v is not None)

        if request_changes:
            # Collect all REQUEST_CHANGES feedback for the fix prompt
            blocking_agent = next(iter(request_changes))
            blocking_body = reviewer_body if blocking_agent == "reviewer" else None

            if blocking_agent == "reviewer" and blocking_body:
                role = extract_role_from_branch(branch)
                if role and role in agents.get("agents", {}):
                    print(f"  Re-dispatching {role} to fix feedback for PR #{pr_num}…")
                    fix_prompt = build_fix_prompt(role, card, blocking_body)
                    fix_reply = run_agent_session(client, agents, role, fix_prompt)

                    fixed_files = parse_file_blocks(fix_reply)
                    if fixed_files:
                        run_cmd("git", "fetch", "origin", branch)
                        run_cmd("git", "checkout", "-B", branch, f"origin/{branch}")
                        for path, content in fixed_files:
                            full = Path(path)
                            full.parent.mkdir(parents=True, exist_ok=True)
                            full.write_text(content.rstrip() + "\n")
                            run_cmd("git", "add", path)
                        result_cmd = run_cmd(
                            "git", "commit", "-m",
                            f"[agent:{role}] fix: address reviewer feedback\n\n"
                            f"Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>",
                            check=False,
                        )
                        if result_cmd.returncode == 0:
                            run_cmd("git", "push", "origin", branch, "--force-with-lease", check=False)
                            gh("pr", "comment", str(pr_num), "-R", REPO,
                               "--body", f"**[orchestrator] {role} pushed fixes:**\n\n{fix_reply[:3000]}")
                            results.append(f"PR #{pr_num}: {role} pushed fixes, awaiting re-review")
                        else:
                            results.append(f"PR #{pr_num}: fix commit failed")
                    else:
                        if issue_num:
                            gh("issue", "edit", str(issue_num), "-R", REPO, "--add-label", "needs:human")
                        results.append(f"PR #{pr_num}: agent couldn't fix, escalated")
                else:
                    if issue_num:
                        gh("issue", "edit", str(issue_num), "-R", REPO, "--add-label", "needs:human")
                    results.append(f"PR #{pr_num}: changes requested, escalated")
            else:
                # Security or tester REQUEST_CHANGES — escalate to human
                if issue_num:
                    gh("issue", "edit", str(issue_num), "-R", REPO, "--add-label", "needs:human")
                results.append(f"PR #{pr_num}: {blocking_agent} requested changes, escalated")

        elif all_approved and len([v for v in all_verdicts.values() if v]) >= 3:
            # All three approved — merge
            print(f"  All 3 reviewers approved PR #{pr_num}, merging…")
            try:
                gh("pr", "merge", str(pr_num), "-R", REPO, "--squash",
                   "--subject", pr["title"])
                results.append(f"PR #{pr_num}: merged! (3/3 approved)")
                if issue_num:
                    apply_stage(issue_num, "Done")
                    try:
                        gh("issue", "close", str(issue_num), "-R", REPO,
                           "--comment", f"[agent:pm] Merged via PR #{pr_num}. All 3 reviewers approved.")
                    except subprocess.CalledProcessError:
                        pass
                    results.append(f"  #{issue_num} → Done")
            except subprocess.CalledProcessError as e:
                results.append(f"PR #{pr_num}: merge failed: {e.stderr}")
        else:
            # Some verdicts still pending — will be picked up next tick
            pending = [k for k, v in all_verdicts.items() if v is None]
            results.append(f"PR #{pr_num}: waiting on {', '.join(pending)}")

    return results


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

import time


def run_one_tick(client, agents, skip_pm=False, dry_run=False) -> None:
    """Run a single orchestrator tick (PM + PR lifecycle)."""
    run_cmd("git", "checkout", "main", check=False)
    run_cmd("git", "pull", "--rebase", "origin", "main", check=False)

    # Phase 1: PM tick
    if not skip_pm:
        print("=== Phase 1: PM tick ===")
        print("Gathering board context…")
        context = gather_context()
        print(f"  context: {len(context)} chars")

        prompt = build_pm_prompt(context)

        print("Spawning PM session…")
        reply = run_agent_session(client, agents, "pm", prompt)

        print("\n--- PM reply ---")
        print(reply)
        print("--- end ---\n")

        actions = parse_actions(reply)
        print(f"Parsed {len(actions)} action(s): {[a[0] for a in actions]}")

        if dry_run:
            print("(dry-run: not posting to GitHub, not applying actions)")
            return

        results: list[str] = []
        for verb, a in actions:
            try:
                status = apply_action(verb, a, client=client, agents=agents)
                print(f"  ✓ {status}")
                results.append(f"- ✓ {status}")
            except subprocess.CalledProcessError as e:
                err = (e.stderr or str(e)).strip()
                print(f"  ✗ {verb} {a}: {err}")
                results.append(f"- ✗ {verb} {' '.join(a)}: {err}")

        footer = "\n\n---\n**Orchestrator applied:**\n" + "\n".join(results) if results else ""
        print(f"Posting to issue #{PM_LOG_ISSUE}…")
        subprocess.run(
            ["gh", "issue", "comment", str(PM_LOG_ISSUE), "-R", REPO, "--body", reply + footer],
            check=True,
        )

    # Phase 2: PR lifecycle
    print("\n=== Phase 2: PR lifecycle ===")
    if dry_run:
        print("(dry-run: skipping PR lifecycle)")
        return

    pr_results = run_pr_lifecycle(client, agents)
    if pr_results:
        print("\nPR lifecycle results:")
        for r in pr_results:
            print(f"  {r}")

        summary = "**[orchestrator] PR lifecycle results:**\n" + "\n".join(f"- {r}" for r in pr_results)
        subprocess.run(
            ["gh", "issue", "comment", str(PM_LOG_ISSUE), "-R", REPO, "--body", summary],
            check=True, capture_output=True,
        )
    else:
        print("  No open agent PRs to process.")

    print("\nDone.")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="Don't post or apply")
    ap.add_argument("--skip-pm", action="store_true", help="Skip PM tick, only run PR lifecycle")
    ap.add_argument("--loop", type=int, metavar="SECS", default=0,
                    help="Run continuously with SECS interval between ticks (e.g. --loop 120)")
    args = ap.parse_args()

    api_key = load_env()
    agents = json.loads(AGENTS_FILE.read_text())
    client = anthropic.Anthropic(api_key=api_key)

    if args.loop > 0:
        tick = 0
        while True:
            tick += 1
            ts = datetime.now(timezone.utc).strftime("%H:%M:%S")
            print(f"\n{'='*60}")
            print(f"  TICK {tick} @ {ts}")
            print(f"{'='*60}\n")
            try:
                run_one_tick(client, agents, skip_pm=args.skip_pm, dry_run=args.dry_run)
            except Exception as e:
                print(f"\n  !! Tick {tick} failed: {e}\n")
            print(f"\nSleeping {args.loop}s until next tick…")
            time.sleep(args.loop)
    else:
        run_one_tick(client, agents, skip_pm=args.skip_pm, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
