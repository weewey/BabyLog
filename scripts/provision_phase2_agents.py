#!/usr/bin/env python3
"""Provision Phase 2 managed agents: Designer, Security, Tester."""

import json
import os
from pathlib import Path

import anthropic

REPO_ROOT = Path(__file__).resolve().parent.parent
SECRETS = REPO_ROOT.parent / ".secrets" / "agents.env"
AGENTS_FILE = REPO_ROOT / "scripts" / "agents.json"

def load_env():
    if SECRETS.exists():
        for line in SECRETS.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))

def main():
    load_env()
    client = anthropic.Anthropic()
    agents_data = json.loads(AGENTS_FILE.read_text())
    env_id = agents_data["environment_id"]

    new_agents = [
        ("designer", "BabyLog Designer", "claude-opus-4-6"),
        ("security", "BabyLog Security", "claude-opus-4-6"),
        ("tester", "BabyLog Tester", "claude-sonnet-4-6"),
    ]

    for role, name, model in new_agents:
        if role in agents_data["agents"]:
            print(f"  {role} already exists: {agents_data['agents'][role]['id']}")
            continue

        print(f"  Creating {role} ({model})...")
        agent = client.beta.agents.create(
            name=name,
            model=model,
            system=f"You are the {name} agent. Read CLAUDE.md and .agents/AGENTS.md first.",
        )
        agents_data["agents"][role] = {
            "id": agent.id,
            "name": name,
            "model": model,
        }
        print(f"  {role} created: {agent.id}")

    AGENTS_FILE.write_text(json.dumps(agents_data, indent=2) + "\n")
    print(f"\nUpdated {AGENTS_FILE}")
    print(f"Agents: {', '.join(agents_data['agents'].keys())}")

if __name__ == "__main__":
    main()
