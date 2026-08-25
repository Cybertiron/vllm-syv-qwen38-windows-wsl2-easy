<#
  Qwen3.8-27B + vLLM on Windows via WSL2 -- one-command installer.

  What it does:
    1. checks WSL2 + an Ubuntu distro are present (tells you how to get them if not)
    2. clones this repo INTO the WSL native filesystem (~/qwen-serving) -- never
       build the venv on /mnt/c, the 9p filesystem makes it painfully slow
    3. runs windows/setup-wsl.sh there (venv, vLLM 0.27.1, model, patches, KVarN)

  The wsl.exe process stays attached for the whole install, which also keeps the
  WSL VM alive (WSL2 idle-shutdown would otherwise SIGTERM a detached job).

  Run from an ordinary PowerShell (no admin needed once WSL is installed):
      powershell -ExecutionPolicy Bypass -File windows\install.ps1
  Options:
      -Distro Ubuntu-24.04     which WSL distro to use (default Ubuntu-24.04)
      -RepoUrl <git url>       override the repo to clone
#>
param(
  [string]$Distro  = "Ubuntu-24.04",
  [string]$RepoUrl = "https://github.com/Cybertiron/vllm-syv-qwen38-windows-wsl2-easy",
  [string]$Dest    = "~/qwen-serving"
)
$ErrorActionPreference = "Stop"
function Info($m){ Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m){ Write-Host "!!  $m" -ForegroundColor Yellow }

# --- 1. WSL present? ------------------------------------------------------
Info "Checking WSL2..."
$wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wsl) {
  Warn "WSL is not installed. In an ADMIN PowerShell run:  wsl --install -d Ubuntu-24.04"
  Warn "reboot, finish the Ubuntu first-run (username/password), then re-run this script."
  exit 1
}
$distros = (wsl.exe -l -q) -replace "`0","" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($distros -notcontains $Distro) {
  Warn "Distro '$Distro' not found. Installed: $($distros -join ', ')"
  Warn "Install it with:  wsl --install -d $Distro   (or pass -Distro <name>)"
  exit 1
}
Info "Using distro: $Distro"

# --- 2. NVIDIA GPU visible inside WSL? ------------------------------------
$smi = wsl.exe -d $Distro -- bash -lc "/usr/lib/wsl/lib/nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1"
if ([string]::IsNullOrWhiteSpace($smi)) {
  Warn "No NVIDIA GPU visible inside WSL. Install the Windows NVIDIA driver (it ships"
  Warn "the WSL CUDA stub automatically) and make sure it is up to date, then re-run."
  exit 1
}
Info "GPU in WSL: $($smi.Trim())"

# --- 3. clone into WSL native fs + run the installer ----------------------
Info "Cloning + installing inside WSL (this takes ~30-60 min: 19.5 GB model + compile)."
Info "Leave this window open -- it keeps the WSL VM alive for the whole install."
$cmd = @"
set -e
if [ ! -d "$Dest/.git" ]; then git clone --depth 1 "$RepoUrl" "$Dest"; else echo "repo already cloned"; fi
cd "$Dest" && bash windows/setup-wsl.sh
"@
wsl.exe -d $Distro -- bash -lc $cmd
if ($LASTEXITCODE -ne 0) { Warn "Install exited with code $LASTEXITCODE -- re-run to resume (it is idempotent)."; exit $LASTEXITCODE }

Info "Done. Control it from Windows with:  windows\vllm.cmd start   (then http://localhost:18020)"
