# Qwen3.8-27B on Windows (WSL2) — easy install

**Windows/WSL2-friendly fork of [syv-ai/qwen38-27b-rtx3090](https://github.com/syv-ai/qwen38-27b-rtx3090).**
Same fast Qwen3.8-27B **int4 (W4A16)** vLLM stack on a single RTX 3090 — with a
one-command installer, a Windows control script, working **KVarN 245k context**, and
the WSL2 fixes that make the Linux instructions actually run on Windows.

> All of the model and kernel engineering is **upstream's** — this fork only adds the
> `windows/` install layer and the WSL2 benchmarks. The original project's full README
> is kept verbatim in **[README-upstream.md](README-upstream.md)**. See
> [Credits](INSTALL-WINDOWS.md#credits).

---

## Install

```powershell
git clone https://github.com/Cybertiron/vllm-syv-qwen38-windows-wsl2-easy
cd vllm-syv-qwen38-windows-wsl2-easy
powershell -ExecutionPolicy Bypass -File windows\install.ps1
```

That clones into WSL, builds the venv, downloads the ~19.5 GB int4 model,
requantizes it, applies the vLLM patches + KVarN, and verifies. ~30–60 min.

**No WSL yet?** Full from-scratch guide (enable WSL2, NVIDIA driver, etc.):
**→ [INSTALL-WINDOWS.md](INSTALL-WINDOWS.md)**

## Run

```bat
windows\vllm.cmd start        :: fastest single-user, ~165 tok/s, 64k context
windows\vllm.cmd mode-huge    :: 245k context (KVarN)
windows\vllm.cmd status
windows\vllm.cmd webui        :: chat UI with saved history -> http://localhost:3000
```

OpenAI-compatible API at `http://localhost:18020/v1` (key in `api_key.txt`).
For a chat window that **remembers your history**, `vllm.cmd webui` runs
[Open WebUI](https://github.com/open-webui/open-webui) at `http://localhost:3000`
(no login; the installer sets it up unless you pass `OWUI=0`). Start the server first.

## Why bother (measured on one RTX 3090, WSL2, greedy)

All numbers below are measured on this fork's harness (same 2000-token generation,
`CTX=fast` = 64k context, single RTX 3090), so they compare like-for-like:

| | tok/s | note |
|---|---|---|
| stock vLLM, no speculation | 36 | baseline |
| **DFlash2** (default here) | **169** | **4.7×** faster, int4, at 64k context |
| KVarN `mode-huge` | 12 @ 209k filled | **245k**-token *capacity* on 24 GB (verified boot). Room for long docs — decode is slow once full: ~12 tok/s at 209k, prefill ~7 min |
| 4 concurrent (subagents) | ~87 each | short prompts; the 64k KV pool is **shared** — see [subagents](#subagents-and-context) |

### Subagents and context

At `CTX=fast` the KV pool holds **~65k tokens total**, shared across concurrent
requests — one stream gets the full 64k, but **4 subagents split it (~16k context
each**, measured: 4/4 fit, ~42 tok/s decode each). For more context per agent launch
`CTX=long` (~136k pool → ~34k each) or `CTX=huge` (~245k → ~60k each), slower.

The default **DFlash2 helps subagents too**: at 4 concurrent with ~15k context each,
per-agent decode is **43.5 tok/s with DFlash2 vs 28.3 without** (+54%). Keep it on for a
handful of agents; use `batch/` mode only when running many at once (spec crosses over
around 8 concurrent). Full tables: [INSTALL-WINDOWS.md](INSTALL-WINDOWS.md).

Runnable orchestrator (stdlib only): **[examples/subagents.py](examples/subagents.py)** —
fans out subagents in parallel, shares one brief via prefix caching, and a lead call
synthesizes their outputs (the server serves independent completions; the orchestrator
routes — subagents don't talk to each other).

Full numbers, VRAM notes, Qwen 3.6-vs-3.8, and the subagent concurrency table are in
**[INSTALL-WINDOWS.md](INSTALL-WINDOWS.md)**.

## Requirements

24 GB Ampere-or-newer NVIDIA GPU · ~40 GB free disk · Windows 10/11 with WSL2 · single card.

## License & credits

Apache-2.0, inherited from upstream. The entire serving stack (requantization, MTP
draft vocab, split-KV verify attention, vLLM patches, KVarN, batch/single-user configs)
is **[syv-ai/qwen38-27b-rtx3090](https://github.com/syv-ai/qwen38-27b-rtx3090)**; DFlash/
DFlash2 drafters are [z-lab](https://github.com/z-lab/dflash) /
[incoai](https://huggingface.co/incoai/Qwen3.8-27B-DFlash2); the int4 checkpoint is
[dbirks/Qwen3.8-27B-W4A16-AutoRound](https://huggingface.co/dbirks/Qwen3.8-27B-W4A16-AutoRound).
This fork adds only the Windows layer.
