#!/usr/bin/env python3
"""
Minimal subagent orchestrator for the Qwen3.8 vLLM server.

The server does NOT make subagents talk to each other -- it only serves independent
completions. Coordination lives here, in the orchestrator: it fans out N subagent
requests in parallel, then a final "lead" call synthesizes their outputs. Subagents
never talk directly; the orchestrator routes everything.

The one thing the server does for you: PREFIX CACHING (start with SPEC=dflash2
PREFIX_CACHE=1, which is the default here). Every subagent below shares the same
leading messages -- the system role plus a shared context block -- so vLLM computes
that prefix's KV once and reuses it for all of them. That is how a shared brief or
document is "communicated" to every subagent cheaply: not by agents messaging each
other, but by reusing cached KV. Keep the shared part first and identical, and put
each subagent's unique task last.

Why bother with parallel subagents at all: aggregate throughput scales with
concurrency. Single-stream decode is ~170 tok/s; 4 concurrent subagents run ~289
tok/s aggregate and 8 run ~318 tok/s (~1.8x a single stream) -- so a fan-out of
independent tasks finishes far sooner than running them one after another. Keep the
fan-out at ~4-8: beyond that requests queue against the 8-slot pool, and for very
many at once switch to batch/ mode.

No dependencies beyond the standard library. Run it against a live server:

    python examples/subagents.py
    # or point it elsewhere / pass a key:
    VLLM_URL=http://localhost:18020/v1 VLLM_API_KEY=$(cat api_key.txt) python examples/subagents.py
"""
import os
import json
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

BASE = os.environ.get("VLLM_URL", "http://localhost:18020/v1").rstrip("/")
MODEL = os.environ.get("VLLM_MODEL", "qwen3.8-27b")

# API key: env wins, else read api_key.txt next to the repo root if present.
_KEY = os.environ.get("VLLM_API_KEY", "")
if not _KEY:
    for p in ("api_key.txt", os.path.join(os.path.dirname(__file__), "..", "api_key.txt")):
        try:
            _KEY = open(p).read().strip()
            break
        except OSError:
            pass
HEADERS = {"Content-Type": "application/json"}
if _KEY:
    HEADERS["Authorization"] = "Bearer " + _KEY

# --- the shared brief every subagent sees FIRST (prefix-cached across all of them) ---
SHARED_SYSTEM = (
    "You are one of several engineers reviewing a small Python module for a team. "
    "Be concise and concrete. Answer only your assigned task."
)
SHARED_CONTEXT = """\
Shared module under review:

    def transfer(accounts, src, dst, amount):
        if amount <= 0:
            raise ValueError("amount must be positive")
        accounts[src] -= amount
        accounts[dst] += amount
        return accounts
"""

# --- each subagent gets a different task; the leading messages are identical ---
SUBAGENTS = {
    "security":   "List concurrency and validation bugs in transfer(), most severe first.",
    "tests":      "Write pytest tests for transfer(), including the edge cases.",
    "refactor":   "Rewrite transfer() to be correct and thread-safe; show the code.",
    "docs":       "Write a short docstring and a one-paragraph usage note for transfer().",
}


def call(messages, max_tokens=500, temperature=0.0):
    """One completion. Shared messages go first so their KV prefix is cache-reused."""
    body = json.dumps({
        "model": MODEL,
        "messages": messages,
        "temperature": temperature,
        "max_tokens": max_tokens,
        "chat_template_kwargs": {"enable_thinking": False},
    }).encode()
    req = urllib.request.Request(BASE + "/chat/completions", data=body, headers=HEADERS)
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=600) as r:
        j = json.load(r)
    dt = time.time() - t0
    text = j["choices"][0]["message"]["content"]
    toks = (j.get("usage") or {}).get("completion_tokens", 0)
    return text, toks, dt


def subagent(name, task):
    messages = [
        {"role": "system", "content": SHARED_SYSTEM},
        {"role": "user", "content": SHARED_CONTEXT},      # identical prefix -> cached
        {"role": "user", "content": f"[task: {name}] {task}"},  # unique tail
    ]
    text, toks, dt = call(messages, max_tokens=500)
    return {"name": name, "text": text, "toks": toks, "dt": dt}


def orchestrate():
    # 1. fan out: all subagents run in parallel against the one server
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=len(SUBAGENTS)) as pool:
        results = list(pool.map(lambda kv: subagent(*kv), SUBAGENTS.items()))
    fan_wall = time.time() - t0

    # 2. the orchestrator collects and routes -- here, a lead call that synthesizes.
    #    (Subagents did not talk to each other; the orchestrator hands their outputs on.)
    joined = "\n\n".join(f"## {r['name']}\n{r['text']}" for r in results)
    lead_messages = [
        {"role": "system", "content": SHARED_SYSTEM},
        {"role": "user", "content": SHARED_CONTEXT},
        {"role": "user", "content":
            "Below are four teammates' findings on transfer(). Merge them into a single "
            "prioritized action list (dedupe overlap), then give the final corrected "
            "function.\n\n" + joined},
    ]
    summary, s_toks, s_dt = call(lead_messages, max_tokens=700)

    # 3. report
    total_toks = sum(r["toks"] for r in results) + s_toks
    print("=" * 70)
    for r in results:
        print(f"[{r['name']:8s}] {r['toks']:4d} tok in {r['dt']:4.1f}s "
              f"({r['toks']/r['dt']:.0f} tok/s)")
    print("-" * 70)
    print(f"fan-out of {len(results)} subagents: wall {fan_wall:.1f}s, "
          f"aggregate {sum(r['toks'] for r in results)/fan_wall:.0f} tok/s")
    print(f"lead synthesis: {s_toks} tok in {s_dt:.1f}s")
    print(f"TOTAL {total_toks} tokens, {time.time()-t0:.1f}s end to end")
    print("=" * 70)
    print("\nFINAL (orchestrator synthesis):\n")
    print(summary)


if __name__ == "__main__":
    orchestrate()
