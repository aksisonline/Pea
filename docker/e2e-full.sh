#!/bin/bash
# Real download (HTTP) then drag the result onto a second GTK app; the main window must return to idle.
OUT=${1:-/shots}; URL=${2:-https://proof.ovh.net/files/10Mb.dat}
export DISPLAY=:99 HOME=$(mktemp -d)
mkdir -p $OUT
pgrep Xvfb >/dev/null || { Xvfb :99 -screen 0 700x400x24 >/dev/null 2>&1 & sleep 1; }
/build/debug/PeaLinux >$OUT/full-app.log 2>&1 &
APP=$!
GTK_A11Y=none python3 /src/docker/drop_target.py > $OUT/drop.log 2>&1 &
sleep 4
xdotool windowmove $(xdotool search --name drop-target | head -1) 300 20
printf '%s' "$URL" | xclip -selection clipboard -i
xdotool mousemove 116 120; sleep 2; xdotool click 1
sleep 8
import -window root +repage $OUT/full-1-done.png
xdotool mousemove 116 120 mousedown 1; sleep 0.3
xdotool mousemove 130 125; sleep 0.2; xdotool mousemove 250 120; sleep 0.2; xdotool mousemove 350 120; sleep 0.3
xdotool mouseup 1; sleep 2
import -window root +repage $OUT/full-2-after.png
cat $OUT/drop.log
kill $APP; pkill -f drop_target.py
