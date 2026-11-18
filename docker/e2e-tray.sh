#!/bin/bash
# Session bus + fake watcher + app: checks SNI registration, properties and Activate.
export DISPLAY=:99 HOME=$(mktemp -d)
pgrep Xvfb >/dev/null || { Xvfb :99 -screen 0 700x400x24 >/dev/null 2>&1 & sleep 1; }
python3 /src/docker/fake_watcher.py & sleep 1
/build/debug/DAllLinux 2>&1 | grep -v a11y &
sleep 5
xdotool search --name D-All | head -1 | xargs -I{} xdotool getwindowgeometry {} | head -3
pkill DAllLinux; pkill -f fake_watcher
