// L410 performance hints for l410-perfd (docs/tuning/perf-power.md):
// the active window's process gets a uclamp floor, the first window of a
// starting application ends its launch boost.
function hint(method, w) {
    if (!w || !w.pid || w.pid <= 0)
        return;
    callDBus("org.l410.perfd", "/org/l410/perfd", "org.l410.perfd", method, w.pid);
}

workspace.windowActivated.connect(function (w) {
    hint("Foreground", w);
});

workspace.windowAdded.connect(function (w) {
    if (w && (w.normalWindow || w.dialog))
        hint("WindowAdded", w);
});
