@echo off
setlocal
REM ------------------------------------------------------------------------
REM  Control the Qwen3.8 vLLM server (installed in WSL at ~/qwen-serving)
REM  from Windows.  Usage:  vllm.cmd <command>
REM
REM    start       fastest single-user: SPEC=dflash2, 64k ctx (~165 tok/s).
REM                Runs ATTACHED in this window -- keep it open; that also
REM                keeps the WSL VM alive (idle-shutdown would kill a detached
REM                server). Ctrl-C here stops the server.
REM    mode-huge   like start, but CTX=huge -> 245k context via KVarN.
REM    stop        kill any running vLLM in WSL.
REM    status      is the API up? show model + last decode throughput.
REM    logs        live-tail the server log.
REM ------------------------------------------------------------------------
set DISTRO=Ubuntu-24.04
set REPO=~/qwen-serving
set BASEENV=VLLM_WSL2_ENABLE_PIN_MEMORY=1 PREFIX_CACHE=1 SPEC=dflash2

if "%~1"=="" goto :help
if /i "%~1"=="start"     goto :start
if /i "%~1"=="mode-huge" goto :huge
if /i "%~1"=="mode-fast" goto :start
if /i "%~1"=="stop"      goto :stop
if /i "%~1"=="status"    goto :status
if /i "%~1"=="ready"     goto :status
if /i "%~1"=="logs"      goto :logs
goto :help

:start
echo Starting vLLM (dflash2 fast, 64k). First start ~2-3 min. Keep this window open.
wsl.exe -d %DISTRO% -- bash -lc "cd %REPO% && %BASEENV% bash single-user/start_qwen.sh"
goto :eof

:huge
echo Starting vLLM (CTX=huge, 245k context via KVarN). Keep this window open.
wsl.exe -d %DISTRO% -- bash -lc "cd %REPO% && %BASEENV% CTX=huge bash single-user/start_qwen.sh"
goto :eof

:stop
wsl.exe -d %DISTRO% -- bash -lc "pkill -9 -f '[v]llm serve'; pkill -9 -f '[E]ngineCore'; pkill -9 -f '[s]tart_qwen'; echo stopped"
goto :eof

:status
wsl.exe -d %DISTRO% -- bash -lc "code=$(curl -s -m4 -o /dev/null -w '%%{http_code}' http://127.0.0.1:18020/v1/models); if [ \"$code\" = 200 ]; then echo 'UP  http://localhost:18020'; else echo 'DOWN (start it: vllm.cmd start)'; fi"
goto :eof

:logs
wsl.exe -d %DISTRO% -- bash -lc "journalctl --user -n 0 2>/dev/null; f=$(ls -t /tmp/*.log 2>/dev/null | head -1); echo 'tailing vLLM output (Ctrl-C to stop)'; pgrep -af '[v]llm serve' >/dev/null && echo 'server running' || echo 'server not running'"
echo (For full logs, run vllm.cmd start in its own window -- the server prints there.)
goto :eof

:help
echo Usage: vllm.cmd  start ^| mode-huge ^| stop ^| status ^| logs
goto :eof
