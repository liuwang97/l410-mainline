// L410 launch-latency probe: log the wall-clock ms at which each window maps/unmaps
workspace.windowAdded.connect(function (w) {
    console.warn("L410T add " + Date.now() + " " + w.resourceClass + " | " + w.caption +
                 " | popup=" + w.popupWindow + " type=" + w.windowType + " pid=" + w.pid);
});
workspace.windowRemoved.connect(function (w) {
    console.warn("L410T del " + Date.now() + " " + w.resourceClass + " pid=" + w.pid);
});
