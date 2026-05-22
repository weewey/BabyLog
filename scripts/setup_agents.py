#!/usr/bin/env python3
"""
One-time bootstrap for the BabyLog managed-agent team.

Creates one cloud environment and the Phase-1 roster (PM, Core, Reviewer),
wiring each agent to the full agent toolset (bash/read/write/edit/glob/grep/web_*).
Writes scripts/agents.json with the persisted IDs for the orchestrator.

Idempotent: if scripts/agents.json already exists, the script prints it and exits.
To rebuild, delete scripts/agents.json first.

Reads ANTHROPIC_API_KEY from .secrets/agents.env.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import anthropic

REPO_ROOT = Path(__file__).resolve().parent.parent
SECRETS = REPO_ROOT.parent / ".secrets" / "agents.env"  # .secrets lives outside the git repo
AGENTS_DIR = REPO_ROOT / ".agents"
OUT_FILE = REPO_ROOT / "scripts" / "agents.json"

PHASE_1 = [
    {"role": "pm", "name": "BabyLog PM", "model": "claude-opus-4-6", "spec": "pm.md"},
    {"role": "core", "name": "BabyLog Core", "model": "claude-sonnet-4-6", "spec": "core.md"},
    {"role": "reviewer", "name": "BabyLog Reviewer", "model": "claude-opus-4-6", "spec": "reviewer.md"},
]


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
        "You are one of the BabyLog managed agents.\n\n"
        "=== .agents/AGENTS.md (shared contract) ===\n"
        f"{shared}\n\n"
        f"=== .agents/{spec_file} (your role) ===\n"
        f"{role_md}\n"
    )


def main() -> None:
    if OUT_FILE.exists():
        print(f"{OUT_FILE} already exists — nothing to do:\n")
        print(OUT_FILE.read_text())
        return

    api_key = load_env()
    client = anthropic.Anthropic(api_key=api_key)

    print("Creating environment…")
    env = client.beta.environments.create(
        name="littlee-phase1",
        config={"type": "cloud"},
        description="BabyLog autonomous build pipeline — phase 1 (PM/Core/Reviewer)",
    )
    print(f"  environment_id = {env.id}")

    agents: dict[str, dict] = {}
    for spec in PHASE_1:
        print(f"Creating agent: {spec['role']} ({spec['model']})")
        agent = client.beta.agents.create(
            model=spec["model"],
            name=spec["name"],
            system=build_system_prompt(spec["spec"]),
            tools=[{"type": "agent_toolset_20260401"}],
            description=f"BabyLog {spec['role']} agent",
        )
        print(f"  agent_id = {agent.id}")
        agents[spec["role"]] = {
            "id": agent.id,
            "name": spec["name"],
            "model": spec["model"],
        }

    OUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    OUT_FILE.write_text(
        json.dumps(
            {"environment_id": env.id, "agents": agents},
            indent=2,
        )
        + "\n"
    )
    print(f"\nWrote {OUT_FILE}")


if __name__ == "__main__":
    main()
