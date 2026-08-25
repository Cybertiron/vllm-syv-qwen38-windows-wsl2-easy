# Qwen3.8-27B + vLLM on Windows (WSL2) — easy install

This is a **Windows/WSL2-friendly fork** of
[syv-ai/qwen38-27b-rtx3090](https://github.com/syv-ai/qwen38-27b-rtx3090):
the same fast Qwen3.8-27B **int4 (W4A16 AutoRound)** vLLM stack, plus a one-command
installer, a Windows control script, working **KVarN 4/2-bit KV cache** (245k context),
and the handful of fixes that make the Linux instructions actually run on Windows.

All of the model/kernel engineering is upstream's — see **Credits** below. This fork
only adds the Windows layer (`windows/`) and the benchmarks in this file.

---

## TL;DR

```powershell
# in an ordinary PowerShell, from the repo folder:
powershell -ExecutionPolicy Bypass -File windows\install.ps1
```

That clones the repo inside WSL, builds the venv, downloads the ~19.5 GB int4 model,
requantizes it, applies the vLLM patches and KVarN, and verifies. ~30–60 min. Then:

```bat
windows\vllm.cmd start        :: fastest single-user, ~165 tok/s, 64k context
windows\vllm.cmd mode-huge    :: 245k context (KVarN)
windows\vllm.cmd status
```

API is OpenAI-compatible at `http://localhost:18020/v1` (key in `api_key.txt`).

---

## From scratch (no WSL yet)

1. **Enable WSL2 + Ubuntu.** In an **admin** PowerShell:
   ```powershell
   wsl --install -d Ubuntu-24.04
   ```
   Reboot, then finish Ubuntu's first-run (pick a username/password).

2. **Install the Windows NVIDIA driver** (a recent one). You do **not** install a
   CUDA toolkit in Windows — the driver ships the WSL CUDA stub automatically.
   Verify from PowerShell:
   ```powershell
   wsl -d Ubuntu-24.04 -- /usr/lib/wsl/lib/nvidia-smi
   ```
   You should see your RTX 3090 (or any ≥24 GB Ampere/Ada/Blackwell card).

3. **Get this repo and run the installer.** From PowerShell:
   ```powershell
   git clone https://github.com/Cybertiron/vllm-syv-qwen38-windows-wsl2-easy
   cd vllm-syv-qwen38-windows-wsl2-easy
   powershell -ExecutionPolicy Bypass -File windows\install.ps1
   ```
   Keep the window open during the install — the attached `wsl.exe` process keeps
   the WSL VM alive (WSL2 idle-shutdown would otherwise kill a detached job).

Requirements: a 24 GB Ampere-or-newer NVIDIA GPU, ~40 GB free disk, Windows 10/11
with WSL2. Runs on a **single** card.

---

## Why WSL2 (and the fixes this fork bakes in)

vLLM does not run natively on Windows — it needs Linux. WSL2 gives you a real
Linux kernel with GPU passthrough, and it is the supported path. Three things bite
you on WSL2 that this fork handles for you:

| Problem | Symptom | Fix (already applied) |
|---|---|---|
| **HF Xet transfer stalls** | model download sits at 0% forever | `HF_HUB_DISABLE_XET=1` → plain HTTPS |
| **ninja not on PATH** | engine dies `FileNotFoundError: 'ninja'` | `setup-wsl.sh` / `start_qwen.sh` put the venv on PATH |
| **WSL2 idle-shutdown** | server SIGTERM'd every few minutes when nothing is attached | run the server attached (`vllm.cmd start`), or a keepalive |
| **CUDA VMM / Marlin repack** | cryptic "device not ready" / silent 5–10× slow prefill | `start_qwen.sh` sets `expandable_segments:False` on WSL |

> If you also enabled the systemd units, **don't** leave them auto-starting while
> you launch manually — two vLLM instances on one GPU will thrash and lag the
> desktop. Pick one control path.

---

## How much better is it? (measured, RTX 3090, WSL2, greedy, 2000-token generation)

Single-stream decode, code prompt, measured **inside WSL** (no Windows streaming lag):

| Config | tok/s | vs stock |
|---|---|---|
| stock vLLM, no speculation (upstream C1) | ~46 | 1.0× |
| **MTP** (`num_speculative_tokens=6`) | 153 | 3.3× |
| **DFlash2** (`SPEC=dflash2`, n=7) — **default here** | **165** | **3.6×** |

- **Acceptance / draft quality** (DFlash2 n=7): mean acceptance length ~5.9 tokens/step,
  ~70% avg draft acceptance. Per-position acceptance falls off fast, so `n=7` is the
  sweet spot — `n=15` is ~5% *slower* (positions 8-15 accept almost nothing).
- **MTP peaks at n≈6**; higher n costs VRAM (bigger verify graphs) for no gain.
- **VRAM:** DFlash2 uses ~1 GB more than MTP (a separate drafter model). If you need
  the longest context, MTP frees that GB for KV cache; if you need speed, DFlash2 wins.

### int4, not GGUF

The model is **W4A16 AutoRound** (int4 weights, safetensors), served by vLLM's
tensor-core int4 GEMMs — not a llama.cpp GGUF. On the same card this is roughly
**2× a comparable llama.cpp int4 build** at short/medium context.

### Qwen 3.6 vs 3.8 (same quant, same spec, same engine)

Ran 3.6 (`Lorbus/Qwen3.6-27B-int4-AutoRound`) through the same vLLM with MTP:

| model | n=2 | n=4 | n=6 |
|---|---|---|---|
| Qwen 3.6 | 61 tok/s | 67 | 64 |
| **Qwen 3.8** | **99** | **130** | **153** |

Draft acceptance is **nearly identical** between them — 3.8 is ~2× faster because of
its optimized checkpoint (int4 lm_head fast variant, split-KV verify attention,
calibrated draft vocab). **Stay on 3.8.**

---

## KVarN — 245k context ("kvern2")

The **KVarN 4/2-bit KV cache** (`kvarn/`, applied by the installer) lets a single
24 GB card hold **~245k tokens** of context, and it combines with DFlash2:

```bat
windows\vllm.cmd mode-huge
```
or in WSL:
```bash
SPEC=dflash2 CTX=huge PREFIX_CACHE=1 VLLM_WSL2_ENABLE_PIN_MEMORY=1 bash single-user/start_qwen.sh
```

**Measured here (RTX 3090, GPU1):** the server boots with a **245,760-token KV
pool** on a single 24 GB card — capacity verified, it really comes up. But decode
rate depends on how **full** the context is, not the max capacity. At **~209k tokens
filled**, prefill/TTFT is **~442 s (~7 min)** and decode runs **~12 tok/s**
(attention-bound — the same for any engine at that length). Short prompts on the same
huge server still run fast. So `245k` is **room** for a long document or chat, not a
speed: use it when the request wouldn't otherwise fit, not to go faster. See upstream
`docs/long-context.md`.

---

## Concurrency — how many subagents can you run?

One server (DFlash2, `max-num-seqs 8`), N parallel requests with **different** prompts:

| concurrent | aggregate tok/s | per-request tok/s | TTFT |
|---|---|---|---|
| 1 | 173 | 174 | 0.1 s |
| 2 | 188 | 118 | 0.2 s |
| **4** | **289** | **87** | 0.2 s |
| 8 | 318 | 63 | 4.3 s |

**Sweet spot for a subagent harness ≈ 4 concurrent** — 289 tok/s aggregate, each
agent still ~87 tok/s, instant TTFT. You can push to 8 (318 aggregate) but per-agent
speed drops and TTFT climbs as requests queue against the 8-slot pool. For **many**
agents, use `batch/start_qwen.sh` (up to ~1,035 tok/s at 64 concurrent, no
speculation) or run a **second instance on a second GPU** for 2× capacity.

Rule of thumb (from upstream too): speculation wins below ~8 concurrent; plain
batching wins above.

---

## Credits

- **[syv-ai/qwen38-27b-rtx3090](https://github.com/syv-ai/qwen38-27b-rtx3090)** — the
  entire serving stack: the requantization, MTP draft vocab, split-KV verify
  attention, vLLM patches, KVarN integration, batch/single-user configs. This fork
  is their work; everything upstream's README documents applies here. Apache-2.0.
- **[z-lab / DFlash](https://github.com/z-lab/dflash)** and
  **[incoai/Qwen3.8-27B-DFlash2](https://huggingface.co/incoai/Qwen3.8-27B-DFlash2)**
  — the DFlash / DFlash2 block-diffusion drafters.
- **[dbirks/Qwen3.8-27B-W4A16-AutoRound](https://huggingface.co/dbirks/Qwen3.8-27B-W4A16-AutoRound)**
  — the int4 target checkpoint; AutoRound quantization by Intel.
- **[vLLM](https://github.com/vllm-project/vllm)** and **Qwen** — the engine and the model.

This fork adds only the `windows/` install layer and the WSL2 benchmarks above.
