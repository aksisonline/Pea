#!/bin/bash
# Real yt-dlp run: copy a YouTube link, click through Audio -> Save Space, wait for the file.
OUT=${1:-/shots}; URL=${2:-https://www.youtube.com/watch?v=jNQXAC9IVRw}
export DISPLAY=:99 HOME=$(mktemp -d)
mkdir -p $OUT
pgrep Xvfb >/dev/null || { Xvfb :99 -screen 0 700x400x24 >/dev/null 2>&1 & sleep 1; }
/build/debug/DAllLinux >$OUT/yt-app.log 2>&1 &
APP=$!
shot() { import -window root -crop 232x266+0+0 +repage $OUT/$1.png; }
sleep 4
printf '%s' "$URL" | xclip -selection clipboard -i
xdotool mousemove 116 120; sleep 8; shot yt-1-armed
xdotool click 1; sleep 1; shot yt-2-kind
xdotool mousemove 116 136 click 1; sleep 1; shot yt-3-quality
xdotool mousemove 116 152 click 1
for i in 1 2 3 4 5 6; do sleep 3; shot yt-4-$i; done
ls -la /root/Downloads
kill $APP
