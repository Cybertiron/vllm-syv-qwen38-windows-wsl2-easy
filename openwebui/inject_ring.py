#!/usr/bin/env python3
"""Inject the context-usage ring (context_ring.js) into Open WebUI's
frontend/index.html.

Run it with the Open WebUI venv's python, e.g. from WSL:
    ~/owui-venv/bin/python /path/to/openwebui/inject_ring.py

Idempotent: re-running replaces the JS between the markers. After
`pip install -U open-webui` the built index.html is overwritten, so run it
again. A one-time backup is written next to index.html (index.html.bak)."""
import glob
import os
import sys

# context_ring.js sits next to this script -> works wherever the repo lives
JS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "context_ring.js")
START = "<!-- ctx-ring:start -->"
END = "<!-- ctx-ring:end -->"


def find_index():
    pats = [
        os.path.expanduser("~/owui-venv/lib/python*/site-packages/open_webui/frontend/index.html"),
        "/root/owui-venv/lib/python*/site-packages/open_webui/frontend/index.html",
        os.path.expanduser("~/.venv/lib/python*/site-packages/open_webui/frontend/index.html"),
    ]
    for p in pats:
        hits = glob.glob(p)
        if hits:
            return hits[0]
    return None


def main():
    idx = find_index()
    if not idx:
        print("ERROR: open_webui/frontend/index.html not found "
              "(is Open WebUI installed in ~/owui-venv?)", file=sys.stderr)
        sys.exit(1)
    if not os.path.exists(JS):
        print("ERROR: context_ring.js not found next to this script:", JS, file=sys.stderr)
        sys.exit(1)

    js = open(JS, encoding="utf-8").read()
    html = open(idx, encoding="utf-8").read()
    block = START + "\n<script>\n" + js + "\n</script>\n" + END

    if START in html and END in html:
        pre = html[:html.index(START)]
        post = html[html.index(END) + len(END):]
        html2 = pre + block + post
        action = "UPDATED"
    else:
        bak = idx + ".bak"
        if not os.path.exists(bak):
            open(bak, "w", encoding="utf-8").write(html)
        if "</head>" in html:
            html2 = html.replace("</head>", block + "\n</head>", 1)
        elif "</body>" in html:
            html2 = html.replace("</body>", block + "\n</body>", 1)
        else:
            html2 = html + "\n" + block
        action = "INJECTED"

    open(idx, "w", encoding="utf-8").write(html2)
    print("%s -> %s (%d B JS)" % (action, idx, len(js)))
    print("Hard-refresh the Open WebUI page (Ctrl+Shift+R).")


if __name__ == "__main__":
    main()
