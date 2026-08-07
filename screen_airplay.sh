#!/usr/bin/env bash
set -euo pipefail

# Starts the UxPlay AirPlay receiver (mirrored screen host).
# The video window is created by UxPlay when the iPhone starts mirroring
# (Control Center -> Screen Mirroring -> "MiniControl"). Our server.py
# capture thread discovers the window dynamically, so order does not matter.

NAME="${MINICONTROL_AIRPLAY_NAME:-MiniControl}"
RES="${MINICONTROL_SCREEN_RES:-390x844@60}"
LOG="${MINICONTROL_UXPLAY_LOG:-/tmp/minicontrol_uxplay.log}"

export DISPLAY="${DISPLAY:-:0}"

pkill -f "uxplay -s" 2>/dev/null || true
sleep 1

echo "Starting UxPlay ($NAME, $RES) on $DISPLAY ..." >&2
setsid env DISPLAY="$DISPLAY" uxplay -s "$RES" -n "$NAME" >"$LOG" 2>&1 < /dev/null &
disown

for i in $(seq 1 10); do
    if pgrep -x uxplay >/dev/null; then
        echo "UxPlay running (pid $(pgrep -x uxplay | head -n1)). Log: $LOG"
        echo "Start mirroring from iPhone: Control Center -> Screen Mirroring -> '$NAME'"
        exit 0
    fi
    sleep 1
done

echo "UxPlay failed to start. See $LOG" >&2
exit 1
