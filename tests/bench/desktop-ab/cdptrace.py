#!/usr/bin/python3
# cdptrace.py <seconds> <out.json.gz> [port]: record a Chrome trace over the DevTools protocol
# from a Chromium started with --remote-debugging-port. Timestamps are CLOCK_MONOTONIC in us,
# the same clock as KWin's frame log (ns), so the two can be lined up frame by frame.
import gzip, json, sys, time, urllib.request, websocket

dur, out = float(sys.argv[1]), sys.argv[2]
port = sys.argv[3] if len(sys.argv) > 3 else "9222"
CATS = ["toplevel", "benchmark", "cc", "viz", "gpu", "ui", "wayland", "input", "latencyInfo",
        "disabled-by-default-cc.debug.scheduler.frames", "disabled-by-default-viz.gpu_composite_time"]

ver = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version"))
ws = websocket.create_connection(ver["webSocketDebuggerUrl"], timeout=60, suppress_origin=True)
n = 0
def send(method, **params):
    global n
    n += 1
    ws.send(json.dumps({"id": n, "method": method, "params": params}))
    return n
def wait(id_=None, event=None):
    while True:
        r = json.loads(ws.recv())
        if id_ is not None and r.get("id") == id_:
            return r
        if event is not None and r.get("method") == event:
            return r

r = wait(send("Tracing.start", traceConfig={"includedCategories": CATS, "recordMode": "recordAsMuchAsPossible"},
              transferMode="ReturnAsStream", streamFormat="json"))
if "error" in r:
    sys.exit(f"Tracing.start: {r['error']}")
t0 = time.monotonic()
print(f"tracing {dur} s from CLOCK_MONOTONIC {time.clock_gettime(time.CLOCK_MONOTONIC):.3f}", flush=True)
time.sleep(dur)
send("Tracing.end")
handle = wait(event="Tracing.tracingComplete")["params"]["stream"]
chunks = []
while True:
    r = wait(send("IO.read", handle=handle, size=1 << 20))["result"]
    chunks.append(r["data"])
    if r.get("eof"):
        break
send("IO.close", handle=handle)
data = "".join(chunks)
with gzip.open(out, "wt") as f:
    f.write(data)
print(f"saved {out}: {len(data) / 1e6:.1f} MB", flush=True)
