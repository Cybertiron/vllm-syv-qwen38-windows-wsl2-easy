# Open WebUI add-ons

Small, self-contained customizations for the Open WebUI that ships with this
stack. Nothing here changes the model server — they only touch the chat UI.

## 1. Context-usage ring (`context_ring.js` + `inject_ring.py`)

A tiny, always-current ring next to the model selector that shows **how full the
context window is** — like the usage indicator in some coding agents. It fills
as the conversation grows and turns amber/red as you approach the limit; hover
for the exact `tokens / max (%)`.

**How it works:** the injected script hooks the chat request, sends the active
conversation to vLLM's `/tokenize` endpoint (CORS is open on the stack's
`:18020`), and draws an SVG ring. No polling, no extra server, no dependency on
any Open WebUI function — it reads the *real* token count, not an estimate.

Why a script and not a filter: Open WebUI status/footer messages are transient,
and a filter can't place a persistent widget by the input. Injecting one small
`<script>` into the built `index.html` is the only way to get a fixed, live ring.

**Install** (run with the Open WebUI venv's python, from WSL):

```bash
~/owui-venv/bin/python /mnt/c/.../openwebui/inject_ring.py
```

Then hard-refresh the page (`Ctrl+Shift+R`). It is **idempotent** (re-running
replaces the old copy). After `pip install -U open-webui` the built `index.html`
is overwritten — just run the injector again. A one-time `index.html.bak` backup
is written next to it.

`context_ring.js` assumes vLLM on `http://127.0.0.1:18020`; edit the `VLLM`
constant at the top if yours differs.

## 2. "No Thinking" filter (`no_thinking_filter.py`)

Qwen3.8 thinks by default. This Open WebUI **filter function** injects
`chat_template_kwargs: {enable_thinking: false}` into every request so the model
answers directly (no `<think>` block) — a quick per-chat toggle without
restarting vLLM.

**Install:** Open WebUI → **Admin Panel → Functions → Create** → paste the file
→ Save → enable it (globally or per-model).

> Note: whether Open WebUI forwards `chat_template_kwargs` to the backend can
> depend on version. If it doesn't take effect, disable thinking server-side
> instead (launch vLLM with a chat template whose `enable_thinking` defaults to
> false).

---

*These are UI conveniences; the stack works fine without them.*
