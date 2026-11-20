#!/bin/bash
# Drag the finished file out of the window onto a second GTK app and check the move + reset.
OUT=${1:-/shots}
export DISPLAY=:99 HOME=$(mktemp -d)
mkdir -p $OUT
pgrep Xvfb >/dev/null || { Xvfb :99 -screen 0 700x400x24 >/dev/null 2>&1 & sleep 1; }
head -c 300000 /dev/urandom > /tmp/dragme.dat
PEA_DEBUG=done-file /build/debug/PeaLinux >$OUT/drag-app.log 2>&1 &
APP=$!
sleep 1
GTK_A11Y=none python3 /src/docker/drop_target.py > $OUT/drop.log 2>&1 &
sleep 2
WIN=$(xdotool search --name drop-target | head -1)
xdotool windowmove $WIN 300 20
sleep 1
import -window root +repage $OUT/drag-0.png
xdotool mousemove 116 120 mousedown 1
sleep 0.3; xdotool mousemove 130 125; sleep 0.2; xdotool mousemove 200 120; sleep 0.2; xdotool mousemove 350 120; sleep 0.3
import -window root +repage $OUT/drag-1.png
xdotool mouseup 1
sleep 1.5
import -window root +repage $OUT/drag-2.png
cat $OUT/drop.log; echo ---; cat $OUT/drag-app.log | grep -v a11y
kill $APP; pkill -f drop_target.py
