#!/usr/bin/env python3
"""
Provisions the UI agent and adds it to scripts/agents.json.

Reads ANTHROPIC_API_KEY from .secrets/agents.env (same as setup_agents.py).
Uses the existing environment_id from agents.json.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import anthropic

REPO_ROOT = Path(__file__).resolve().parent.parent
SECRETS = REPO_ROOT.parent / ".secrets" / "agents.env"
AGENTS_DIR = REPO_ROOT / ".agents"
OUT_FILE = REPO_ROOT / "scripts" / "agents.json"

UI_SPEC = {
    "role": "ui",
    "name": "LittleE UI",
    "model": "claude-sonnet-4-6",
    "spec": "ui.md",
}


def load_env() -> str:
    if not SECRETS.exists():
        sys.exit(f"missing {SECRETS}")
    for line in SECRETS.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        sys.exit("ANTHROPIC_API_KEY not set in .secrets/agents.env")
    return key


def build_system_prompt(spec_file: str) -> str:
    role_md = (AGENTS_DIR / spec_file).read_text()
    shared = (AGENTS_DIR / "AGENTS.md").read_text()
    return (
        "You are one of the LittleE managed agents.\n\n"
        "=== .agents/AGENTS.md (shared contract) ===\n"
        f"{shared}\n\n"
        f"=== .agents/{spec_file} (your role) ===\n"
        f"{role_md}\n"
    )


def main() -> None:
    if not OUT_FILE.exists():
        sys.exit(f"{OUT_FILE} does not exist — run setup_agents.py first")

    data = json.loads(OUT_FILE.read_text())

    if "ui" in data.get("agents", {}):
        print("UI agent already exists in agents.json:")
        print(json.dumps(data["agents"]["ui"], indent=2))
        return

    api_key = load_env()
    client = anthropic.Anthropic(api_key=api_key)

    spec = UI_SPEC
    print(f"Creating agent: {spec['role']} ({spec['model']})")
    agent = client.beta.agents.create(
        model=spec["model"],
        name=spec["name"],
        system=build_system_prompt(spec["spec"]),
        tools=[{"type": "agent_toolset_20260401"}],
        description=f"LittleE {spec['role']} agent",
    )
    print(f"  agent_id = {agent.id}")

    data["agents"]["ui"] = {
        "id": agent.id,
        "name": spec["name"],
        "model": spec["model"],
    }

    OUT_FILE.write_text(json.dumps(data, indent=2) + "\n")
    print(f"\nUpdated {OUT_FILE}")


if __name__ == "__main__":
    main()
