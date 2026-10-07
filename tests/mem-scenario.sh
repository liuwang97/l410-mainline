#!/bin/bash
# Desktop memory scenario (docs/tuning/memory.md; the plan's "验证与基线"): Chromium with N
# tabs of real sites, a background memory hog standing in for the other applications, then
# every tab is brought to the front twice (right away and after an idle period) and the time
# until it renders again is measured through the DevTools protocol.
#
#   bash tests/mem-scenario.sh [tabs=20] [idle seconds=300] [hog MiB|auto]
#
# Runs as the desktop user inside the Plasma session (XDG_RUNTIME_DIR set; sudo -n for the
# kernel counters). "auto" hog = 95% of MemAvailable after the tabs have loaded, so the tabs
# and the hog together do not fit in RAM. Prints per round p50/p95/max switch time and the
# reclaim/zswap/PSI deltas. Output in /var/tmp/l410-memscen/<time>/.
N=${1:-20} IDLE=${2:-300} HOG=${3:-auto}
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}
OUT=/var/tmp/l410-memscen/$(date +%Y%m%d-%H%M%S); mkdir -p $OUT
PORT=9333
P=$HOME/.config/chromium-memtest
URLS="https://www.bilibili.com/ https://www.baidu.com/ https://www.jd.com/ https://www.taobao.com/
https://www.sina.com.cn/ https://www.qq.com/ https://www.163.com/ https://www.sohu.com/ https://www.ifeng.com/
https://www.csdn.net/ https://www.douban.com/ https://www.huawei.com/cn/ https://www.cctv.com/
https://www.people.com.cn/ https://www.xinhuanet.com/ https://news.baidu.com/ https://www.mi.com/
https://www.gov.cn/ https://www.zhihu.com/ https://www.xiaohongshu.com/explore https://www.toutiao.com/
https://www.youku.com/ https://www.iqiyi.com/ https://www.meituan.com/"

vm() { awk '$1 ~ /^(allocstall_|compact_stall$|pgmajfault$|workingset_refault_|zswpin$|zswpout$|zswpwb$|pswpin$|pswpout$|pgscan_direct$|oom_kill$)/ { print $1, $2 }' /proc/vmstat; }
d() { awk -v k="$1" 'NR == FNR { a[$1] = $2; next } $1 ~ k { s += $2 - a[$1] } END { print s + 0 }' $2 $3; }

pkill -x chromium; sleep 3
rm -rf $P; mkdir -p $P/Default
echo '{"browser":{"has_seen_welcome_page":true},"distribution":{"skip_first_run_ui":true}}' > $P/Default/Preferences
touch "$P/First Run"
systemd-run --user --scope -q -u app-chromium-memtest-$$.scope chromium --user-data-dir=$P --ozone-platform=wayland \
	--no-first-run --no-default-browser-check --password-store=basic --disable-session-crashed-bubble \
	--remote-debugging-port=$PORT --remote-allow-origins='*' about:blank > $OUT/chromium.log 2>&1 &
for i in $(seq 1 30); do curl -s localhost:$PORT/json/version > /dev/null && break; sleep 1; done

cat > $OUT/cdp.py << 'PY'
import json, sys, time, urllib.request, websocket
PORT = 9333
def http(path, method="GET"):
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}{path}", method=method)
    return json.loads(urllib.request.urlopen(req, timeout=30).read() or b"null")
def pages():
    return [t for t in http("/json/list") if t["type"] == "page"]
def open_tabs(urls):
    for u in urls:
        http("/json/new?" + u, "PUT"); time.sleep(3)
    for t in pages():
        if t["url"] == "about:blank": http("/json/close/" + t["id"])
JS = """new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => {
  window.scrollBy(0, 1500); requestAnimationFrame(() => requestAnimationFrame(() => r(1))); })))"""
def switch_round(tag):
    res = []
    for t in pages():
        t0 = time.monotonic()
        try:
            http("/json/activate/" + t["id"])
            ws = websocket.create_connection(t["webSocketDebuggerUrl"], timeout=60)
            ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate",
                                "params": {"expression": JS, "awaitPromise": True}}))
            while json.loads(ws.recv()).get("id") != 1: pass
            ws.close()
            ms = (time.monotonic() - t0) * 1000
        except Exception as e:
            ms = 60000.0
            print(f"{tag} {t['url'][:50]} error {e}", file=sys.stderr)
        res.append(ms); print(f"{tag} {ms:8.1f} ms {t['url'][:60]}", flush=True)
        time.sleep(0.5)
    res.sort()
    n = len(res)
    print(f"SUMMARY {tag} n={n} p50={res[n//2]:.0f} p95={res[min(n-1, int(n*.95))]:.0f} max={res[-1]:.0f} ms", flush=True)
cmd = sys.argv[1]
if cmd == "open": open_tabs(sys.argv[2:])
elif cmd == "round": switch_round(sys.argv[2])
elif cmd == "count": print(len(pages()))
PY
python3 $OUT/cdp.py open $(echo $URLS | tr ' ' '\n' | head -$N)
echo "tabs: $(python3 $OUT/cdp.py count); waiting 40 s for loads"
sleep 40
avail=$(awk '/MemAvailable/ { print int($2 / 1024) }' /proc/meminfo)
[ "$HOG" = auto ] && HOG=$((avail * 95 / 100))
echo "MemAvailable ${avail} MiB after the tabs; hog ${HOG} MiB" | tee $OUT/summary.txt
sudo -n cat /proc/pressure/memory > $OUT/psi.a 2> /dev/null
vm > $OUT/vm.a
( while :; do echo "$(date +%s) $(sed -n 's/^some avg10=\([0-9.]*\).*/\1/p;s/^full avg10=\([0-9.]*\).*/\1/p' /proc/pressure/memory | tr '\n' ' ')"; sleep 1; done ) > $OUT/psi.txt & PSIP=$!
cat > $OUT/hog.py << 'PY'
# memory hog: MB of pages that compress about 3:1 (1 KiB random + 3 KiB zero per page),
# then random touches keep them in use until the time is up
import os, random, sys, time
mb, secs = int(sys.argv[1]), float(sys.argv[2])
page = 4096; chunk = 64 << 20; bufs = []
rnd = os.urandom(1 << 20)
t_end = time.monotonic() + secs
for i in range(mb // 64):
    b = bytearray(chunk)
    for off in range(0, chunk, page):
        o = (off // 4) % ((1 << 20) - 1024)
        b[off:off + 1024] = rnd[o:o + 1024]
    bufs.append(b)
    if time.monotonic() > t_end:
        break
n = len(bufs) * (chunk // page)
while time.monotonic() < t_end:
    for _ in range(20000):
        k = random.randrange(n)
        b = bufs[k // (chunk // page)]
        b[(k % (chunk // page)) * page + 2048] ^= 1
print("hog done", len(bufs) * 64, "MiB")
PY
[ "$HOG" -gt 0 ] && systemd-run --user --scope -q -u app-memhog-$$.scope python3 $OUT/hog.py $HOG $((IDLE + 900)) > /dev/null 2>&1 &
sleep 20
python3 $OUT/cdp.py round R1 2>> $OUT/errors.txt | tee $OUT/r1.txt | tail -1
echo "idle $IDLE s"; sleep $IDLE
python3 $OUT/cdp.py round R2 2>> $OUT/errors.txt | tee $OUT/r2.txt | tail -1
pkill -f "$OUT/hog.py"; kill $PSIP 2> /dev/null
vm > $OUT/vm.b
{
	grep SUMMARY $OUT/r1.txt $OUT/r2.txt | sed 's/.*SUMMARY/SUMMARY/'
	echo "allocstall +$(d '^allocstall_' $OUT/vm.a $OUT/vm.b) pgscan_direct +$(d '^pgscan_direct$' $OUT/vm.a $OUT/vm.b) compact_stall +$(d '^compact_stall$' $OUT/vm.a $OUT/vm.b) pgmajfault +$(d '^pgmajfault$' $OUT/vm.a $OUT/vm.b)"
	echo "refault file +$(d '^workingset_refault_file$' $OUT/vm.a $OUT/vm.b) anon +$(d '^workingset_refault_anon$' $OUT/vm.a $OUT/vm.b); zswpout +$(d '^zswpout$' $OUT/vm.a $OUT/vm.b) zswpin +$(d '^zswpin$' $OUT/vm.a $OUT/vm.b) zswpwb +$(d '^zswpwb$' $OUT/vm.a $OUT/vm.b) pswpin +$(d '^pswpin$' $OUT/vm.a $OUT/vm.b); oom_kill +$(d '^oom_kill$' $OUT/vm.a $OUT/vm.b)"
	echo "PSI avg10 peak some/full: $(awk '{ if ($2 > s) s = $2; if ($3 > f) f = $3 } END { print s + 0, f + 0 }' $OUT/psi.txt)"
	echo "tabs alive at the end: $(python3 $OUT/cdp.py count 2> /dev/null || echo 'browser gone')"
	journalctl --user --since "-$((IDLE + 600))s" --no-pager -o cat 2> /dev/null | grep -iE "oomd|Killed|out of memory" | tail -3
} | tee -a $OUT/summary.txt
pkill -x chromium
echo "OUT: $OUT"
