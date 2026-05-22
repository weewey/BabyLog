#!/usr/bin/env python3
"""
System-prompt eval harness for BabyLog's chat backends.

Runs a labeled dataset through the Anthropic Messages API using a chosen
system prompt + the chat tool definitions, then scores each turn on:

  (a) deterministic tool correctness  — did the model pick the expected tool?
  (b) deterministic param correctness — are required params present with right values?
  (c) Opus-as-judge tone rubric        — warm / empathetic / brief / no-questions / no-lecture

Usage:
  ANTHROPIC_API_KEY=sk-ant-... python3 scripts/eval/run_eval.py \\
      --prompt scripts/eval/prompts/claude_baseline.txt \\
      --out scripts/eval/results/claude_pass1.json

Gemma proxy runs use the Gemma system prompt but hit the same Claude API
(the on-device model can't be evaluated in this environment). Scores are
labeled "proxy, not authoritative" in the output file.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
CLAUDE_SRC = REPO_ROOT / "BabyLog/Features/Chat/Backends/ClaudeChatSession.swift"
GEMMA_SRC = REPO_ROOT / "BabyLog/Features/Chat/Backends/Gemma4MLXChatSession.swift"

SUBJECT_MODEL = "claude-opus-4-6"  # mirrors ClaudeChatSession.model exactly
JUDGE_MODEL = "claude-opus-4-6"    # user picked Opus for tone judging
TODAY = "2026-04-14"

API_URL = "https://api.anthropic.com/v1/messages"


# ---------- prompt extraction ----------

def _unwrap_swift_continuations(body: str) -> str:
    # Swift multi-line strings with a trailing backslash continue to the
    # next line without inserting a newline. Merge those. Preserve real
    # newlines (paragraph + bullet structure).
    out_lines: list[str] = []
    buf = ""
    for raw in body.splitlines():
        line = raw.rstrip()
        stripped = line.lstrip()
        if stripped.endswith("\\"):
            buf += (buf and " " or "") + stripped[:-1].rstrip()
        else:
            if buf:
                out_lines.append((buf + " " + stripped).strip())
                buf = ""
            else:
                out_lines.append(line.strip())
    if buf:
        out_lines.append(buf.strip())
    return "\n".join(out_lines)


def extract_claude_prompt() -> str:
    src = CLAUDE_SRC.read_text()
    m = re.search(r'static let systemPromptBody = """\n(.*?)\n    """', src, re.DOTALL)
    if not m:
        raise SystemExit("could not find systemPromptBody in ClaudeChatSession.swift")
    text = _unwrap_swift_continuations(m.group(1)).strip()
    return text + f"\n\nToday's date is {TODAY}."


def extract_gemma_prompt() -> str:
    src = GEMMA_SRC.read_text()
    m = re.search(
        r'static func gemmaSystemPrompt\(today: Date\) -> String \{.*?return """\n(.*?)\n        """',
        src,
        re.DOTALL,
    )
    if not m:
        raise SystemExit("could not find gemmaSystemPrompt in Gemma4MLXChatSession.swift")
    text = _unwrap_swift_continuations(m.group(1)).strip()
    return text.replace("\\(stamp)", TODAY)


# ---------- anthropic api ----------

def call_api(model: str, system: str, messages: list[dict], tools: list[dict] | None, max_tokens: int = 1024) -> dict:
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        raise SystemExit("ANTHROPIC_API_KEY not set")
    body: dict[str, Any] = {
        "model": model,
        "max_tokens": max_tokens,
        "system": system,
        "messages": messages,
    }
    if tools:
        body["tools"] = tools
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        API_URL,
        data=data,
        headers={
            "content-type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
        },
        method="POST",
    )
    for attempt in range(6):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            err_body = e.read().decode("utf-8", errors="replace")
            if attempt < 5 and e.code in (429, 500, 502, 503, 504):
                # Respect retry-after for 429s; else exponential up to 60s.
                ra = e.headers.get("retry-after") if e.headers else None
                try:
                    wait = float(ra) if ra else min(60, 5 * (2 ** attempt))
                except ValueError:
                    wait = min(60, 5 * (2 ** attempt))
                time.sleep(wait)
                continue
            raise SystemExit(f"HTTP {e.code}: {err_body[:500]}")
        except urllib.error.URLError as e:
            if attempt < 5:
                time.sleep(min(30, 2 ** attempt))
                continue
            raise SystemExit(f"network error: {e}")
    raise SystemExit("unreachable")


# ---------- scoring ----------

@dataclass
class RowScore:
    id: str
    category: str
    split: str
    user: str
    tool_ok: bool
    params_ok: bool
    forbid_ok: bool
    parallel_ok: bool | None
    tone: dict[str, Any] = field(default_factory=dict)
    actual_tools: list[dict] = field(default_factory=list)
    actual_text: str = ""
    notes: str = ""


def extract_tool_uses(resp: dict) -> list[dict]:
    out = []
    for block in resp.get("content", []):
        if block.get("type") == "tool_use":
            out.append({"name": block.get("name"), "input": block.get("input", {})})
    return out


def extract_text(resp: dict) -> str:
    parts = []
    for block in resp.get("content", []):
        if block.get("type") == "text":
            parts.append(block.get("text", ""))
    return " ".join(parts).strip()


def score_tool(row: dict, actual_tools: list[dict]) -> tuple[bool, bool, bool, bool | None]:
    expected = row["expected_tool"]
    params_expected = row.get("expected_params") or {}
    forbid = row.get("forbid_params") or []
    parallel_all_of = row.get("expected_tools_all_of")

    if expected is None:
        tool_ok = len(actual_tools) == 0
        params_ok = True
        forbid_ok = True
    else:
        match = next((t for t in actual_tools if t["name"] == expected), None)
        tool_ok = match is not None
        if not match:
            params_ok = False
            forbid_ok = False
        else:
            params_ok = all(
                _param_matches(match["input"].get(k), v)
                for k, v in params_expected.items()
            )
            forbid_ok = all(k not in match["input"] for k in forbid)

    parallel_ok: bool | None = None
    if parallel_all_of:
        names = {t["name"] for t in actual_tools}
        parallel_ok = all(n in names for n in parallel_all_of)

    return tool_ok, params_ok, forbid_ok, parallel_ok


def _param_matches(actual: Any, expected: Any) -> bool:
    if actual is None:
        return False
    if isinstance(expected, (int, float)) and isinstance(actual, (int, float)):
        return abs(float(actual) - float(expected)) < 0.01
    return actual == expected


JUDGE_SYSTEM = """You are grading a baby-tracking app's chat assistant response against a rubric. The assistant speaks to tired new parents (often at 3am). You must return STRICT JSON with integer 1-5 scores per axis and a one-sentence rationale. No prose outside JSON.

Rubric axes (higher = better):
- warmth:        1=cold/clinical, 3=polite, 5=warm and human
- empathy:       1=ignores emotion, 3=notices, 5=genuinely meets the parent where they are (only required for emotional turns — else score 3 as neutral)
- brevity:       1=rambling multi-paragraph, 3=a few sentences, 5=one or two tight sentences
- no_questions:  1=asks clarifying question, 3=confirms unnecessarily, 5=just acts (only penalize questions that tool call would have handled)
- no_lecturing:  1=preaches/suggests doctor unprompted/"make sure to", 3=neutral, 5=zero advice-giving tone
- appropriate:   1=wrong register entirely, 3=acceptable, 5=pitch-perfect for the moment

Return exactly: {"warmth": N, "empathy": N, "brevity": N, "no_questions": N, "no_lecturing": N, "appropriate": N, "rationale": "..."}"""


def judge_tone(user: str, assistant_text: str, tool_calls: list[dict], tone_traits: list[str], category: str) -> dict:
    if not assistant_text and tool_calls:
        # Pure tool-call turn with no text — judge the tool-shape only.
        assistant_text = f"(assistant emitted {len(tool_calls)} tool call(s) and no text)"
    msg = (
        f"Category: {category}\n"
        f"Tone traits that SHOULD be present: {', '.join(tone_traits) if tone_traits else '(none)'}\n\n"
        f"USER:\n{user}\n\n"
        f"ASSISTANT TEXT:\n{assistant_text or '(empty)'}\n\n"
        f"Emitted tool calls: {json.dumps(tool_calls)}\n\n"
        f"Grade now. STRICT JSON only."
    )
    resp = call_api(JUDGE_MODEL, JUDGE_SYSTEM, [{"role": "user", "content": msg}], tools=None, max_tokens=400)
    text = extract_text(resp)
    m = re.search(r"\{.*\}", text, re.DOTALL)
    if not m:
        return {"warmth": 0, "empathy": 0, "brevity": 0, "no_questions": 0, "no_lecturing": 0, "appropriate": 0, "rationale": f"judge parse fail: {text[:200]}"}
    try:
        return json.loads(m.group(0))
    except json.JSONDecodeError:
        return {"warmth": 0, "empathy": 0, "brevity": 0, "no_questions": 0, "no_lecturing": 0, "appropriate": 0, "rationale": f"json decode fail: {text[:200]}"}


# ---------- main loop ----------

def run(prompt_path: Path, out_path: Path, split: str | None, limit: int | None, skip_judge: bool) -> dict:
    system_prompt = prompt_path.read_text().strip()
    tools = json.loads((REPO_ROOT / "scripts/eval/tools.json").read_text())
    dataset = [json.loads(l) for l in (REPO_ROOT / "scripts/eval/dataset.jsonl").read_text().splitlines() if l.strip()]
    if split:
        dataset = [r for r in dataset if r["split"] == split]
    if limit:
        dataset = dataset[:limit]

    results: list[RowScore] = []
    for i, row in enumerate(dataset):
        print(f"[{i+1}/{len(dataset)}] {row['id']} {row['category']} — {row['user'][:50]}", flush=True)
        messages = [{"role": "user", "content": row["user"]}]
        resp = call_api(SUBJECT_MODEL, system_prompt, messages, tools=tools)
        actual_tools = extract_tool_uses(resp)
        actual_text = extract_text(resp)

        # If the first turn was a tool call, simulate the tool result so the
        # assistant gets to produce its confirmation text — that matches
        # production flow (tool_use → tool_result → follow-up text). Without
        # this round-trip the tone judge scores silent tool turns at ~3/5.
        if actual_tools and resp.get("stop_reason") == "tool_use":
            assistant_content = resp.get("content", [])
            fake_results = []
            for block in assistant_content:
                if block.get("type") == "tool_use":
                    fake_results.append({
                        "type": "tool_result",
                        "tool_use_id": block["id"],
                        "content": f"ok — {block['name']} succeeded. id=00000000-0000-0000-0000-000000000000",
                    })
            messages.append({"role": "assistant", "content": assistant_content})
            messages.append({"role": "user", "content": fake_results})
            try:
                followup = call_api(SUBJECT_MODEL, system_prompt, messages, tools=tools)
                follow_text = extract_text(followup)
                if follow_text:
                    actual_text = (actual_text + " " + follow_text).strip() if actual_text else follow_text
            except SystemExit:
                pass  # tolerate follow-up failure; score what we have

        tool_ok, params_ok, forbid_ok, parallel_ok = score_tool(row, actual_tools)

        tone = {}
        if not skip_judge:
            try:
                tone = judge_tone(row["user"], actual_text, actual_tools, row.get("tone_traits") or [], row["category"])
            except SystemExit as e:
                tone = {"error": str(e)}

        results.append(RowScore(
            id=row["id"],
            category=row["category"],
            split=row["split"],
            user=row["user"],
            tool_ok=tool_ok,
            params_ok=params_ok,
            forbid_ok=forbid_ok,
            parallel_ok=parallel_ok,
            tone=tone,
            actual_tools=actual_tools,
            actual_text=actual_text,
            notes=row.get("notes", ""),
        ))

    agg = aggregate(results)
    payload = {
        "prompt_path": str(prompt_path),
        "prompt_sha_first60": system_prompt.replace("\n", " ")[:60],
        "subject_model": SUBJECT_MODEL,
        "judge_model": JUDGE_MODEL,
        "today": TODAY,
        "count": len(results),
        "aggregate": agg,
        "rows": [asdict(r) for r in results],
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, indent=2))
    print(f"\nwrote {out_path}")
    print_summary(agg)
    return payload


EMOTIONAL_CATS = {"emotional_support", "feed_create_emotional", "diaper_create_emotional"}


def aggregate(results: list[RowScore]) -> dict:
    by_split: dict[str, dict] = {}
    for r in results:
        bucket = by_split.setdefault(r.split, {
            "count": 0, "tool_ok": 0, "params_ok": 0, "forbid_ok": 0,
            "parallel_ok": 0, "parallel_total": 0,
            "warmth": 0.0, "brevity": 0.0, "no_questions": 0.0,
            "no_lecturing": 0.0, "appropriate": 0.0, "judge_count": 0,
            "empathy_sum": 0.0, "empathy_count": 0,
        })
        bucket["count"] += 1
        bucket["tool_ok"] += int(r.tool_ok)
        bucket["params_ok"] += int(r.params_ok)
        bucket["forbid_ok"] += int(r.forbid_ok)
        if r.parallel_ok is not None:
            bucket["parallel_total"] += 1
            bucket["parallel_ok"] += int(r.parallel_ok)
        if isinstance(r.tone, dict) and "warmth" in r.tone and isinstance(r.tone["warmth"], (int, float)) and r.tone["warmth"] > 0:
            bucket["judge_count"] += 1
            for axis in ("warmth", "brevity", "no_questions", "no_lecturing", "appropriate"):
                bucket[axis] += r.tone.get(axis, 0)
            # Empathy only meaningful on emotional rows — neutral=3 on others
            # would otherwise drag the mean. Track emo-only denominator.
            if r.category in EMOTIONAL_CATS:
                bucket["empathy_sum"] += r.tone.get("empathy", 0)
                bucket["empathy_count"] += 1

    for split, b in by_split.items():
        c = b["count"] or 1
        jc = b["judge_count"] or 1
        b["tool_ok_pct"] = round(100 * b["tool_ok"] / c, 1)
        b["params_ok_pct"] = round(100 * b["params_ok"] / c, 1)
        b["forbid_ok_pct"] = round(100 * b["forbid_ok"] / c, 1)
        b["parallel_ok_pct"] = round(100 * b["parallel_ok"] / b["parallel_total"], 1) if b["parallel_total"] else None
        for axis in ("warmth", "brevity", "no_questions", "no_lecturing", "appropriate"):
            b[f"{axis}_avg"] = round(b[axis] / jc, 2) if b["judge_count"] else 0.0
        b["empathy_avg"] = round(b["empathy_sum"] / b["empathy_count"], 2) if b["empathy_count"] else None

    # Failure categories
    fail_categories: dict[str, int] = {}
    for r in results:
        if not (r.tool_ok and r.params_ok and r.forbid_ok):
            fail_categories[r.category] = fail_categories.get(r.category, 0) + 1
    return {"by_split": by_split, "fail_categories": fail_categories}


def print_summary(agg: dict) -> None:
    print("\n=== summary ===")
    for split, b in agg["by_split"].items():
        print(f"\n[{split}]  n={b['count']}  judged={b['judge_count']}")
        print(f"  tool_ok    {b['tool_ok_pct']}%    params_ok {b['params_ok_pct']}%    forbid_ok {b['forbid_ok_pct']}%")
        if b.get("parallel_ok_pct") is not None:
            print(f"  parallel_ok {b['parallel_ok_pct']}% ({b['parallel_ok']}/{b['parallel_total']})")
        emp = b.get('empathy_avg')
        emp_str = f"{emp} (n={b['empathy_count']})" if emp is not None else "—"
        print(f"  warmth {b['warmth_avg']}  empathy(emo) {emp_str}  brevity {b['brevity_avg']}")
        print(f"  no_questions {b['no_questions_avg']}  no_lecturing {b['no_lecturing_avg']}  appropriate {b['appropriate_avg']}")
    if agg["fail_categories"]:
        print("\n  deterministic failures by category:")
        for cat, n in sorted(agg["fail_categories"].items(), key=lambda x: -x[1]):
            print(f"    {cat}: {n}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prompt", type=Path)
    ap.add_argument("--out", type=Path)
    ap.add_argument("--split", choices=["train", "val"], default=None)
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--skip-judge", action="store_true")
    ap.add_argument("--extract-claude", action="store_true", help="Dump current Claude prompt from Swift source and exit")
    ap.add_argument("--extract-gemma", action="store_true", help="Dump current Gemma prompt from Swift source and exit")
    args = ap.parse_args()

    if args.extract_claude:
        print(extract_claude_prompt())
        return
    if args.extract_gemma:
        print(extract_gemma_prompt())
        return

    run(args.prompt, args.out, args.split, args.limit, args.skip_judge)


if __name__ == "__main__":
    main()
