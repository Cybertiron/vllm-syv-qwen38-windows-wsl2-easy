#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-shot installer for Qwen3.8-27B + vLLM inside WSL2 (Ubuntu 24.04).
#
# This runs the exact venv install from the upstream README (syv-ai), but
# automated, idempotent (safe to re-run / resume), and with the two fixes that
# trip people up on Windows/WSL2:
#   1. HF_HUB_DISABLE_XET=1  -- the Xet transfer backend frequently STALLS at 0%
#      on WSL2; the plain HTTPS path downloads the 19.5 GB model reliably.
#   2. ninja / venv bin on PATH -- vLLM JIT-compiles kernels with ninja at first
#      run; without it the engine dies with FileNotFoundError: 'ninja'.
#
# Usage (from inside WSL, in the repo root):   bash windows/setup-wsl.sh
# Or from Windows:                             windows\install.ps1
# ---------------------------------------------------------------------------
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
MODEL_DIR="$REPO/models/Qwen3.8-27B-W4A16-AutoRound"
VENV="$REPO/venv"
PY="$VENV/bin/python"
export PATH="$VENV/bin:$PATH"
export HF_HUB_DISABLE_XET=1          # WSL2 Xet-stall fix (see header)
export HF_HUB_ENABLE_HF_TRANSFER=1

say()  { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }
skip() { printf "    \033[2m(skip) %s\033[0m\n" "$*"; }

# --- 0. system packages (idempotent) --------------------------------------
if ! dpkg -s python3.12-venv >/dev/null 2>&1 || ! command -v patch >/dev/null 2>&1; then
  say "Installing system packages (sudo)"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    python3.12 python3.12-venv python3.12-dev \
    build-essential patch curl ca-certificates openssl git
else
  skip "system packages already present"
fi

# --- 1. python venv + vLLM 0.27.1 + flashinfer ----------------------------
if [ ! -x "$PY" ]; then
  say "Creating venv + installing vLLM 0.27.1 (torch/cu130) + flashinfer"
  python3.12 -m venv "$VENV"
  "$VENV/bin/pip" install --upgrade pip
  # pinned stack every upstream number was measured on
  "$VENV/bin/pip" install -r docker/requirements.txt
  # flashinfer makes the DFlash2 selector ~2x faster; cubin avoids needing nvcc
  "$VENV/bin/pip" install flashinfer-python flashinfer-cubin==0.6.13
else
  skip "venv already exists ($VENV)"
fi
SP="$("$PY" -c 'import vllm, os; print(os.path.dirname(vllm.__file__))' | tail -n1)"

# --- 2. model download (~19.5 GB, Xet disabled) ---------------------------
if [ ! -f "$MODEL_DIR/config.json" ] || ! ls "$MODEL_DIR"/*.safetensors >/dev/null 2>&1; then
  say "Downloading Qwen3.8-27B-W4A16-AutoRound (~19.5 GB, HTTPS not Xet)"
  "$VENV/bin/hf" download dbirks/Qwen3.8-27B-W4A16-AutoRound --local-dir "$MODEL_DIR"
else
  skip "model already downloaded ($MODEL_DIR)"
fi

# --- 3. requantize lm_head + embeddings + MTP + draft vocab ----------------
if ! "$PY" - "$MODEL_DIR" <<'EOF' 2>/dev/null
import json, sys
idx = json.load(open(sys.argv[1] + "/model.safetensors.index.json"))["weight_map"]
sys.exit(0 if "lm_head.weight_packed" in idx else 1)
EOF
then
  say "Requantizing lm_head / embeddings / MTP (CPU, a few minutes)"
  "$PY" prepare/quant_lm_head.py "$MODEL_DIR"
  "$PY" prepare/quant_embed.py   "$MODEL_DIR"
  "$PY" prepare/quant_mtp.py     "$MODEL_DIR"
  "$PY" prepare/build_draft_vocab.py "$MODEL_DIR" --ids prepare/draft_vocab_ids.json
else
  skip "model already requantized"
fi

# --- 4. single-user 'fast' variant + DFlash2 drafter ----------------------
if [ ! -d "$REPO/models/Qwen3.8-27B-W4A16-AutoRound-fast" ]; then
  say "Fetching single-user fast variant (~1 GB, hardlinks the rest)"
  "$PY" prepare/fetch_fast_variant.py
else
  skip "fast variant present"
fi
if ! ls "$REPO"/models/Qwen3.8-27B-DFlash2*/model.safetensors >/dev/null 2>&1; then
  say "Fetching DFlash2 block drafter (~1.2 GB) for SPEC=dflash2"
  "$PY" prepare/fetch_dflash2.py
else
  skip "DFlash2 drafter present"
fi

# --- 5. apply vLLM patches (idempotent, never interactive) -----------------
# -N --batch: on a re-run patch would otherwise prompt "Reversed ... Assume -R?"
# and hang an unattended install. Forward dry-run first: applies cleanly => not
# yet applied => apply; anything else (already applied / the DFlash2 pair that
# can't be reversed individually) => skip.
say "Applying vLLM patches"
for p in patches/*.patch; do
  if patch -p1 -N --batch -d "$SP" --dry-run <"$p" >/dev/null 2>&1; then
    patch -p1 -N --batch -d "$SP" <"$p" >/dev/null && echo "    applied $(basename "$p")"
  else
    skip "$(basename "$p") already applied"
  fi
done

# --- 6. KVarN 4/2-bit KV cache (this is the 'kvern2' / CTX=huge path) ------
# Detection matches verify.sh: the backend file present == installed.
if [ -f "$SP/v1/attention/backends/kvarn_attn.py" ]; then
  skip "KVarN already installed"
else
  say "Installing KVarN 4/2-bit KV cache (CTX=huge, 245k context + DFlash2)"
  bash kvarn/install.sh
fi

# --- 7. api key ------------------------------------------------------------
[ -f "$REPO/api_key.txt" ] || openssl rand -hex 24 > "$REPO/api_key.txt"

# --- 8. verify -------------------------------------------------------------
say "Verifying install (no GPU/server needed)"
bash verify.sh --no-server || true

printf '\n\033[1;32m%s\033[0m\n' "============================================================"
cat <<EOF
 Install complete. Launch (from WSL, in $REPO):

   # fastest single-user, 64k ctx, ~165 tok/s:
   SPEC=dflash2 PREFIX_CACHE=1 VLLM_WSL2_ENABLE_PIN_MEMORY=1 bash single-user/start_qwen.sh

   # huge context, 245k tokens (KVarN / 'kvern2'):
   SPEC=dflash2 CTX=huge PREFIX_CACHE=1 VLLM_WSL2_ENABLE_PIN_MEMORY=1 bash single-user/start_qwen.sh

 Or from Windows just use:  windows\\vllm.cmd start | mode-huge | logs
 API: http://localhost:18020/v1   (key in api_key.txt)
EOF
printf '\033[1;32m%s\033[0m\n' "============================================================"
