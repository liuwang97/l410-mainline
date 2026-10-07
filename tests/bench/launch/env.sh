# session env for ssh shells + KWin window-map probe
export XDG_RUNTIME_DIR=/run/user/${L410_UID:-1000} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${L410_UID:-1000}/bus WAYLAND_DISPLAY=wayland-0 \
       XDG_SESSION_TYPE=wayland QT_QPA_PLATFORM=wayland XDG_CURRENT_DESKTOP=KDE KDE_FULL_SESSION=true KDE_SESSION_VERSION=6
B=$HOME/l410-bench/launch-lat
ms() { date +%s%3N; }
probe_load() {
    if [ "$(qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.isScriptLoaded l410launch)" != true ]; then
        id=$(qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript $B/watch.js l410launch)
        qdbus6 org.kde.KWin /Scripting/Script$id org.kde.kwin.Script.run
    fi
}
probe_unload() { qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript l410launch >/dev/null; }
# follow KWin's journal into $LOG for the whole run (timestamps come from KWin, so lag doesn't matter)
follow_start() {
    LOG=$(mktemp -p $B log.XXXX); : > $B/trig.$$
    journalctl --user -u plasma-kwin_wayland -f -n0 -o cat | grep --line-buffered "L410T" > $LOG &
    FPID=$!; sleep 0.5
}
follow_stop() { kill $FPID 2>/dev/null; pkill -P $$ -x journalctl 2>/dev/null; }
trig() { echo "$1 $(ms)" >> $B/trig.$$; }
# report: for each trigger "<label> <ms>", first "add" with pattern $1 after it
report() {
    awk -v pat="$1" 'FNR==NR { sub(/^js: /, ""); $0 = $0; if ($1=="L410T" && $2=="add" && $0 ~ pat) a[++n]=$3; next }
        { t=$2; best=-1; for (i=1;i<=n;i++) if (a[i]>=t) { best=a[i]; break }
          printf "%s map_ms=%s\n", $1, (best<0 ? "none" : best-t) }' $LOG $B/trig.$$
}
