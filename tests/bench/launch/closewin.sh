#!/bin/bash
# closewin.sh CLASS: close all windows whose resourceClass is CLASS through a one-shot KWin script
. ~/l410-bench/launch-lat/env.sh
f=$B/closewin-$1.js
echo "workspace.windowList().forEach(function (w) { if (w.resourceClass == \"$1\") w.closeWindow(); });" > $f
qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript l410close >/dev/null 2>&1
id=$(qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript $f l410close)
qdbus6 org.kde.KWin /Scripting/Script$id org.kde.kwin.Script.run >/dev/null
sleep 0.3
qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript l410close >/dev/null
