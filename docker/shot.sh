#!/bin/bash
# Usage (inside the container): docker/shot.sh <debug-state> <out.png> [wait-seconds]
# Starts Xvfb, runs PeaLinux with PEA_DEBUG=<state>, grabs the window.
set -e
STATE=$1; OUT=$2; WAIT=${3:-2}
BIN=${BIN:-/build/debug/PeaLinux}
export DISPLAY=:99
pgrep Xvfb >/dev/null || { Xvfb :99 -screen 0 400x400x24 >/dev/null 2>&1 & sleep 1; }
PEA_DEBUG=$STATE HOME=${HOME_DIR:-/tmp/pea-home} $BIN >/tmp/pea.log 2>&1 &
PID=$!
sleep "$WAIT"
import -window root -crop 232x266+0+0 +repage "$OUT"
kill $PID 2>/dev/null || true
