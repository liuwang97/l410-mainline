#!/usr/bin/python3
# Dump chrome://gpu of a Chromium started with --remote-debugging-port=9222 (text of all shadow roots).
import json, sys, time, urllib.request, websocket
port = sys.argv[1] if len(sys.argv) > 1 else "9222"
url = sys.argv[2] if len(sys.argv) > 2 else "chrome://gpu"
for i in range(30):
    try:
        tabs = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json"))
        break
    except Exception:
        time.sleep(1)
tab = next(t for t in tabs if t.get("type") == "page")
ws = websocket.create_connection(tab["webSocketDebuggerUrl"], timeout=30, suppress_origin=True)
n = 0
def call(method, **params):
    global n
    n += 1
    ws.send(json.dumps({"id": n, "method": method, "params": params}))
    while True:
        r = json.loads(ws.recv())
        if r.get("id") == n:
            return r
if not tab["url"].startswith(url):
    call("Page.navigate", url=url)
time.sleep(6)
js = r"""
(function () {
  const out = [];
  function walk(root) {
    const w = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    let n;
    while ((n = w.nextNode())) {
      if (n.nodeType === 3) { const s = n.textContent.trim(); if (s) out.push(s); }
      else if (n.shadowRoot) walk(n.shadowRoot);
    }
  }
  walk(document.body);
  return out.join('\n');
})()
"""
r = call("Runtime.evaluate", expression=js, returnByValue=True)
print(r["result"]["result"].get("value", r))
