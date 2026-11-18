#!/bin/bash
# Real end-to-end run of the plain-HTTP path inside the container, with screenshots at each stage.
# Usage: docker/e2e-http.sh <out-dir> [url]
OUT=${1:-/shots}; URL=${2:-https://proof.ovh.net/files/10Mb.dat}
export DISPLAY=:99 HOME=$(mktemp -d)
mkdir -p $OUT
pgrep Xvfb >/dev/null || { Xvfb :99 -screen 0 400x400x24 >/dev/null 2>&1 & sleep 1; }
BIN=${BIN:-/build/debug/DAllLinux}
$BIN >$OUT/app.log 2>&1 &
APP=$!
shot() { import -window root -crop 232x266+0+0 +repage $OUT/$1.png; }
sleep 2; xdotool mousemove 116 120; sleep 0.5; shot e2e-1-start      # first run: tools present -> Ready! then idle
sleep 3; shot e2e-2-idle
printf '%s' "$URL" | xclip -selection clipboard -i
sleep 2; xdotool mousemove 118 122; sleep 1; shot e2e-3-linkcopied
xdotool key ctrl+v
for i in 1 2 3 4 5 6 7 8; do sleep 1; shot e2e-4-dl-$i; ls -la $HOME/Downloads 2>/dev/null | tail -2; done
sleep 3; shot e2e-5-after
ls -la $HOME/Downloads
kill $APP
