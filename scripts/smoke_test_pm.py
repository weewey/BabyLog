#!/usr/bin/env python3
"""
Smoke test: spawn a PM session, send a no-op message, stream events until
the session terminates, print a readable event log. Does NOT clone the repo,
does NOT hit GitHub. Purely validates that session create + stream + terminate
works end-to-end against the persisted agent.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import anthropic

REPO_ROOT = Path(__file__).resolve().parent.parent
SECRETS = REPO_ROOT.parent / ".secrets" / "agents.env"
AGENTS_FILE = REPO_ROOT / "scripts" / "agents.json"


def load_env() -> str:
    for line in SECRETS.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        sys.exit("ANTHROPIC_API_KEY not set")
    return key


def main() -> None:
    api_key = load_env()
    cfg = json.loads(AGENTS_FILE.read_text())
    env_id = cfg["environment_id"]
    pm_id = cfg["agents"]["pm"]["id"]

    client = anthropic.Anthropic(api_key=api_key)

    print(f"Creating session (agent={pm_id}, env={env_id})…")
    session = client.beta.sessions.create(
        agent={"type": "agent", "id": pm_id},
        environment_id=env_id,
        title="smoke test — PM no-op",
    )
    print(f"  session_id = {session.id}\n")

    # Stream-first ordering: open the stream BEFORE sending the first event,
    # otherwise early events arrive buffered in one batch.
    print("Opening event stream…")
    stream = client.beta.sessions.events.stream(session.id)

    print("Sending user.message…\n")
    client.beta.sessions.events.send(
        session_id=session.id,
        events=[
            {
                "type": "user.message",
                "content": [
                    {
                        "type": "text",
                        "text": (
                            "SMOKE TEST — ignore your normal role instructions.\n"
                            "Do not clone the repo. Do not touch GitHub. Do not run any tools.\n"
                            "Reply with exactly one short sentence acknowledging you received this, "
                            "then stop."
                        ),
                    }
                ],
            }
        ],
    )

    event_count = 0
    for event in stream:
        event_count += 1
        etype = getattr(event, "type", "<?>")
        # Print a terse line per event, plus any text content we can extract
        print(f"[{event_count}] {etype}")

        # Text deltas — pull from nested message/content_block structures if present
        for attr in ("message", "content_block", "delta"):
            obj = getattr(event, attr, None)
            if obj is None:
                continue
            text = getattr(obj, "text", None)
            if text:
                print(f"    text: {text[:200]}")

        # Termination conditions from skill doc
        if etype == "session.status_terminated":
            print("\n== terminated ==")
            break
        if etype == "session.status_idle":
            stop = getattr(event, "stop_reason", None)
            stop_type = getattr(stop, "type", None) if stop else None
            if stop_type != "requires_action":
                print(f"\n== idle (stop_reason={stop_type}), exiting ==")
                break

    print(f"\nTotal events: {event_count}")
    print(f"Session id for inspection: {session.id}")


if __name__ == "__main__":
    main()
