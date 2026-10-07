#!/usr/bin/python3
# mainstall.py <trace.json.gz>: what the renderer main thread ran while the compositor waited on it
# (bursts of SKIPPED_REASON_WAITING_ON_MAIN): long tasks with where they were posted from
import collections, gzip, json, sys
d = json.load(gzip.open(sys.argv[1], "rt")); ev = d["traceEvents"] if isinstance(d, dict) else d
pname = {e["pid"]: e["args"]["name"] for e in ev if e.get("ph") == "M" and e.get("name") == "process_name"}
tname = {(e["pid"], e["tid"]): e["args"]["name"] for e in ev if e.get("ph") == "M" and e.get("name") == "thread_name"}
waits = sorted(e["ts"] / 1000 for e in ev if e.get("name") == "Graphics.Pipeline" and e.get("ph") == "X"
               and e.get("args", {}).get("chrome_graphics_pipeline", {}).get("frame_skipped_reason") == "SKIPPED_REASON_WAITING_ON_MAIN")
# the renderer (pid) that hosts the page = the one with the most Compositor Graphics.Pipeline events
rp = collections.Counter(e["pid"] for e in ev if e.get("name") == "Graphics.Pipeline" and tname.get((e["pid"], e.get("tid"))) == "Compositor").most_common(1)[0][0]
main = [e for e in ev if e["pid"] == rp and tname.get((e["pid"], e.get("tid"))) == "CrRendererMain" and e.get("ph") == "X" and "dur" in e]
tasks = [e for e in main if e.get("name") == "ThreadControllerImpl::RunTask"]
busy = sum(e["dur"] for e in tasks) / 1000
span = (max(e["ts"] for e in ev if "ts" in e) - min(e["ts"] for e in ev if "ts" in e and e.get("ph") != "M")) / 1000
print(f"renderer pid {rp}: main thread busy {busy:.0f} ms of {span:.0f} ms ({busy / span * 100:.0f}%), {len(tasks)} tasks, {len(waits)} BeginFrames skipped waiting on it")
long = sorted((e for e in tasks if e["dur"] > 16000), key=lambda e: -e["dur"])
print(f"tasks > 16 ms: {len(long)}, total {sum(e['dur'] for e in long) / 1000:.0f} ms")
def inside(t, a, b): return a <= t <= b
for e in long[:15]:
    a, b = e["ts"] / 1000, (e["ts"] + e["dur"]) / 1000
    n = sum(1 for w in waits if inside(w, a, b + 17))
    src = e.get("args", {}).get("src_func") or e.get("args", {}).get("src") or e.get("args", {}).get("task", {}).get("posted_from", {})
    kids = collections.Counter(k["name"] for k in main if k is not e and a * 1000 <= k["ts"] <= b * 1000 and k.get("dur", 0) > 2000)
    print(f"  {e['dur'] / 1000:6.1f} ms at {a - waits[0] if waits else a:8.0f}, skipped frames during it {n:2d}, from {str(src)[:70]}; inside: {', '.join(f'{k}x{v}' for k, v in kids.most_common(4))[:150]}")
cov = sum(1 for w in waits if any(e["ts"] / 1000 <= w <= (e["ts"] + e["dur"]) / 1000 + 17 for e in tasks if e["dur"] > 16000))
print(f"skipped-waiting-on-main BeginFrames that overlap a main-thread task > 16 ms: {cov} of {len(waits)}")
