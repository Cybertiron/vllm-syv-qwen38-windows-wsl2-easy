/* Open WebUI — minimalistinis konteksto žiedas + spaudžiamas breakdown popup
   (kaip Claude Code usage apskritimas ir statistika).
   DUOMENŲ ŠALTINIS: pokalbis skaitomas iš DOM (.chat-user / .chat-assistant),
   NE iš užklausos — Open WebUI /api/chat/completions NEturi `messages` (siunčia
   message_ids/chat_id, backend'as atkuria istoriją). Periodinis scrape kas 2.5s
   (+ po siuntimo) -> vLLM /tokenize (CORS *) -> žiedas + breakdown.
   Žiedas seka model selektorių. Įterpiama į frontend/index.html (inject_ring.py). */
(function () {
  if (window.__ctxRing) return;
  window.__ctxRing = true;

  var VLLM = "http://127.0.0.1:18020";
  var origFetch = window.fetch.bind(window);
  var lastModel = null, lastHash = "", busy = false;
  var curPct = 0, curCount = 0, curMax = 65536, curTip = "";
  var lastMsgs = [];
  var COL = { user: "#3b82f6", asst: "#10b981", sys: "#f59e0b", free: "#6b7280" };

  // model pavadinimą pasiimam iš užklausos (jei praeina), kitaip iš /v1/models
  window.fetch = function (input, init) {
    try {
      var body = init && init.body;
      if (body && typeof body === "string" && /completions/.test((typeof input === "string") ? input : (input && input.url) || "")) {
        var j = JSON.parse(body);
        if (j && j.model) lastModel = j.model;
        // po siuntimo DOM greitai keisis -> paskatinam kelis atnaujinimus
        setTimeout(tick, 500); setTimeout(tick, 1500);
      }
    } catch (e) {}
    return origFetch(input, init);
  };

  // ---------- pokalbio nuskaitymas ----------
  // PIRMINIS: Open WebUI API (pilnas chatas, TIK aktyvi šaka per currentId->parentId;
  // atsparu DOM virtualizacijai ir be UI šiukšlių). FALLBACK: DOM scrape (naujas chatas).
  async function getMessages() {
    var chatId = (location.pathname.match(/\/c\/([0-9a-f-]+)/) || [])[1];
    var token = localStorage.getItem("token");
    if (chatId && token) {
      try {
        var r = await origFetch("/api/v1/chats/" + chatId, { headers: { Authorization: "Bearer " + token } });
        if (r.ok) {
          var d = await r.json();
          var h = d && d.chat && d.chat.history;
          if (h && h.messages && h.currentId) {
            var chain = [], id = h.currentId, guard = 0;
            while (id && h.messages[id] && guard++ < 5000) {
              var m = h.messages[id];
              var c = (typeof m.content === "string") ? m.content
                    : (Array.isArray(m.content) ? m.content.map(function (p) { return p && p.text || ""; }).join(" ") : "");
              chain.push({ role: m.role || "user", content: c });
              id = m.parentId;
            }
            chain.reverse();
            if (chain.length) return chain;
          }
        }
      } catch (e) {}
    }
    return scrape();
  }
  function nodeText(n) {
    var md = n.querySelector('[class*="markdown"], .prose, [class*="prose"]');
    var t = (md && md.innerText) ? md.innerText : (n.innerText || "");
    return t.replace(/\s+$/g, "").trim();
  }
  function scrape() {
    var nodes = document.querySelectorAll(".chat-user, .chat-assistant");
    var msgs = [];
    nodes.forEach(function (n) {
      var role = n.classList.contains("chat-user") ? "user" : "assistant";
      var t = nodeText(n);
      if (t) msgs.push({ role: role, content: t });
    });
    return msgs;
  }

  async function ensureModel() {
    if (lastModel) return lastModel;
    try {
      var r = await origFetch(VLLM + "/v1/models");
      var d = await r.json();
      if (d.data && d.data[0]) lastModel = d.data[0].id;
    } catch (e) {}
    return lastModel;
  }

  async function tokenize(messages, gen) {
    var payload = { messages: messages, add_generation_prompt: !!gen };
    if (lastModel) payload.model = lastModel;
    var r = await origFetch(VLLM + "/tokenize", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload) });
    if (!r.ok) throw new Error("tokenize " + r.status);
    return await r.json();
  }
  async function tkCount(messages, gen) {
    if (!messages || !messages.length) return 0;
    try { var d = await tokenize(messages, gen); return (d.count != null) ? d.count : (Array.isArray(d.tokens) ? d.tokens.length : 0); }
    catch (e) { return estimate(messages); }
  }
  function estimate(messages) {
    var chars = 0;
    for (var i = 0; i < messages.length; i++) { var c = messages[i] && messages[i].content; if (typeof c === "string") chars += c.length; }
    return Math.round(chars / 4);
  }

  async function tick() {
    if (busy) return;
    busy = true;
    try {
      var msgs = await getMessages();
      if (!msgs.length) return;
      var hash = msgs.length + ":" + msgs.reduce(function (a, m) { return a + m.content.length; }, 0);
      if (hash === lastHash) return;   // niekas nepasikeitė -> netokenizuojam
      await ensureModel();
      lastMsgs = msgs;
      var count = null, max = 65536;
      try { var d = await tokenize(msgs, true);
        count = (d.count != null) ? d.count : (Array.isArray(d.tokens) ? d.tokens.length : null);
        if (d.max_model_len) max = d.max_model_len;
      } catch (e) { count = estimate(msgs); }
      if (count == null) count = estimate(msgs);
      lastHash = hash;
      setRing(count, max);
      if (popup && popup.style.display === "block") renderPopup();
    } finally { busy = false; }
  }

  // ---------- žiedas ----------
  var elWrap, elProg, elTxt, popup, R = 12, C = 2 * Math.PI * R;

  function build() {
    if (elWrap && document.body.contains(elWrap)) return;
    elWrap = document.createElement("div");
    elWrap.id = "ctx-ring";
    elWrap.style.cssText =
      "position:fixed;z-index:99999;width:30px;height:30px;cursor:pointer;opacity:.92;" +
      "transition:opacity .2s;filter:drop-shadow(0 1px 2px rgba(0,0,0,.4));";
    elWrap.onmouseenter = function () { elWrap.style.opacity = "1"; };
    elWrap.onmouseleave = function () { elWrap.style.opacity = ".92"; };
    elWrap.onclick = function (e) { e.stopPropagation(); togglePopup(); };
    elWrap.innerHTML =
      '<svg width="30" height="30" viewBox="0 0 30 30">' +
        '<circle cx="15" cy="15" r="' + R + '" fill="none" stroke="currentColor" stroke-opacity="0.18" stroke-width="2.5"></circle>' +
        '<circle id="ctx-ring-prog" cx="15" cy="15" r="' + R + '" fill="none" stroke="#3b82f6" stroke-width="2.5" stroke-linecap="round" ' +
          'stroke-dasharray="' + C + '" stroke-dashoffset="' + C + '" transform="rotate(-90 15 15)" style="transition:stroke-dashoffset .5s,stroke .3s"></circle>' +
        '<text id="ctx-ring-txt" x="15" y="15" text-anchor="middle" dominant-baseline="central" font-size="8" ' +
          'font-family="system-ui,sans-serif" fill="currentColor" fill-opacity="0.8">–</text>' +
      '</svg>';
    document.body.appendChild(elWrap);
    elProg = elWrap.querySelector("#ctx-ring-prog");
    elTxt = elWrap.querySelector("#ctx-ring-txt");
    if (curCount) applyPct();
    if (curTip) elWrap.title = curTip;
  }

  function findModelBtn() {
    var best = null, bestY = -1, vh = window.innerHeight, btns = document.querySelectorAll("button");
    for (var i = 0; i < btns.length; i++) {
      var b = btns[i], t = (b.textContent || "").trim();
      if (!t || t.length > 44 || !/[a-z0-9]/i.test(t) || !b.querySelector("svg")) continue;
      var r = b.getBoundingClientRect();
      if (r.width < 40 || r.top < vh * 0.55) continue;
      if (r.top > bestY) { bestY = r.top; best = b; }
    }
    return best;
  }
  function reposition() {
    if (!elWrap) return;
    var mb = findModelBtn(), r = mb && mb.getBoundingClientRect();
    if (r) { elWrap.style.left = Math.max(4, r.left - 38) + "px"; elWrap.style.top = (r.top + r.height / 2 - 15) + "px"; elWrap.style.right = "auto"; elWrap.style.bottom = "auto"; }
    else { elWrap.style.left = "auto"; elWrap.style.top = "auto"; elWrap.style.right = "20px"; elWrap.style.bottom = "20px"; }
    if (popup && popup.style.display === "block") placePopup();
  }

  function fmt(n) { return n >= 1000 ? (n / 1000).toFixed(n >= 10000 ? 0 : 1) + "k" : String(n); }
  function full(n) { return n.toLocaleString("en-US"); }
  function applyPct() {
    var col = curPct >= 90 ? "#ef4444" : curPct >= 70 ? "#f59e0b" : "#3b82f6";
    elProg.setAttribute("stroke", col);
    elProg.setAttribute("stroke-dashoffset", (C * (1 - curPct / 100)).toFixed(2));
    elTxt.textContent = Math.round(curPct) + "%";
  }
  function setRing(count, max) {
    build(); curCount = count; curMax = max;
    curPct = Math.max(0, Math.min(100, count / max * 100));
    curTip = "🧮 Context  " + full(count) + " / " + full(max) + "  (" + curPct.toFixed(1) + "%)";
    applyPct(); elWrap.title = curTip; reposition();
  }

  // ---------- popup ----------
  function buildPopup() {
    if (popup && document.body.contains(popup)) return;
    popup = document.createElement("div");
    popup.id = "ctx-ring-popup";
    popup.style.cssText =
      "position:fixed;z-index:100000;display:none;width:270px;padding:14px 16px;border-radius:12px;" +
      "background:#1e1e22;color:#e5e7eb;font:12px/1.5 system-ui,sans-serif;" +
      "box-shadow:0 8px 30px rgba(0,0,0,.5);border:1px solid rgba(255,255,255,.08);";
    document.body.appendChild(popup);
    document.addEventListener("click", function (e) { if (popup && popup.style.display === "block" && !popup.contains(e.target) && e.target !== elWrap && !(elWrap && elWrap.contains(e.target))) popup.style.display = "none"; });
  }
  function placePopup() {
    if (!popup || !elWrap) return;
    var r = elWrap.getBoundingClientRect(), pw = 270, ph = popup.offsetHeight || 200;
    var left = Math.min(window.innerWidth - pw - 10, Math.max(10, r.left + r.width / 2 - pw / 2));
    var top = r.top - ph - 10; if (top < 10) top = r.bottom + 10;
    popup.style.left = left + "px"; popup.style.top = top + "px";
  }
  async function renderPopup() {
    buildPopup();
    var msgs = lastMsgs || [];
    var g = { system: [], user: [], assistant: [] };
    msgs.forEach(function (m) { if (g[m.role]) g[m.role].push(m); });
    var sys = await tkCount(g.system, false), usr = await tkCount(g.user, false), ast = await tkCount(g.assistant, false);
    var sum = sys + usr + ast || 1, scale = Math.min(1, curCount / sum);
    var sV = Math.round(sys * scale), uV = Math.round(usr * scale), aV = Math.round(ast * scale);
    var free = Math.max(0, curMax - curCount);
    function pct(n) { return n / curMax * 100; }
    function seg(v, c) { return v > 0 ? '<div style="height:8px;background:' + c + ';width:' + pct(v).toFixed(3) + '%"></div>' : ""; }
    function row(dot, name, v) {
      return '<div style="display:flex;align-items:center;gap:8px;margin-top:7px">' +
        '<span style="width:9px;height:9px;border-radius:2px;background:' + dot + ';flex:0 0 auto"></span>' +
        '<span style="flex:1">' + name + '</span>' +
        '<span style="color:#9ca3af;font-variant-numeric:tabular-nums">' + fmt(v) + '</span>' +
        '<span style="width:44px;text-align:right;font-weight:600;font-variant-numeric:tabular-nums">' + pct(v).toFixed(1) + '%</span></div>';
    }
    var html =
      '<div style="display:flex;justify-content:space-between;align-items:baseline;margin-bottom:10px">' +
        '<span style="font-weight:600;font-size:12.5px">Context window</span>' +
        '<span style="color:#9ca3af">' + full(curCount) + ' / ' + full(curMax) + ' (' + curPct.toFixed(0) + '%)</span></div>' +
      '<div style="display:flex;height:8px;border-radius:4px;overflow:hidden;background:rgba(255,255,255,.06)">' +
        seg(uV, COL.user) + seg(aV, COL.asst) + seg(sV, COL.sys) + '</div>';
    if (uV) html += row(COL.user, "User messages", uV);
    if (aV) html += row(COL.asst, "Assistant", aV);
    if (sV) html += row(COL.sys, "System prompt", sV);
    html += row(COL.free, "Free space", free);
    popup.innerHTML = html; placePopup();
  }
  function togglePopup() {
    buildPopup();
    if (popup.style.display !== "block") { popup.style.display = "block"; popup.innerHTML = '<div style="color:#9ca3af">skaičiuoju…</div>'; placePopup(); renderPopup(); }
    else popup.style.display = "none";
  }

  function init() {
    build(); reposition(); tick();
    setInterval(function () { build(); reposition(); }, 1500);
    setInterval(tick, 2500);
    window.addEventListener("resize", reposition, { passive: true });
  }
  if (document.body) init(); else document.addEventListener("DOMContentLoaded", init);
})();
