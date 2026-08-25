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
```

OpenAI-compatible API at `http://localhost:18020/v1` (key in `api_key.txt`).

## Why bother (measured on one RTX 3090, WSL2, greedy)

| | tok/s | note |
|---|---|---|
| stock vLLM, no speculation | ~46 | baseline |
| **DFlash2** (default here) | **165** | **3.6×** faster, int4 |
| KVarN `mode-huge` | — | **245k** token context on one 24 GB card |
| 4 concurrent (subagents) | 289 aggregate | ~87 tok/s each, instant TTFT |

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
