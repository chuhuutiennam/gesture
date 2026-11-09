#!/usr/bin/env bash
# Template installed by setup as APP_DIR/start.sh, like Nemotron's start.sh.
set -euo pipefail
APP_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -f "$APP_DIR/.gpu-server-deployment" ]] || { echo '[ERROR] Run the generated APP_DIR/start.sh after setup' >&2; exit 1; }
mkdir -p "$APP_DIR/run" "$APP_DIR/logs"
exec 9> "$APP_DIR/run/gpu-management.lock"
flock -x 9
proc_token() {
    local record rest; local -a fields
    [[ "$1" =~ ^[0-9]+$ && -r "/proc/$1/stat" ]] || return 1
    IFS= read -r record < "/proc/$1/stat" || return 1
    rest=${record##*) }; read -r -a fields <<< "$rest"
    [[ "${fields[0]}" != Z && "${fields[0]}" != X ]] || return 1
    printf '%s\n' "${fields[19]}"
}
if [[ -f "$APP_DIR/run.pid" ]]; then
    old_pid=$(cat "$APP_DIR/run.pid")
    old_token=$(cat "$APP_DIR/run.start" 2>/dev/null || true)
    token=$(proc_token "$old_pid" || true)
    if [[ -n "$token" && "$token" == "$old_token" ]]; then
        echo "[INFO] Already running PID=$old_pid"; exit 0
    fi
fi
# Check the lifetime lock before spawning so an existing foreground process wins.
exec 8> "$APP_DIR/run/gpu-server.lock"
flock -n 8 || { echo '[ERROR] Gesture is already running or setup is active' >&2; exit 1; }
flock -u 8
exec 8>&-
nohup env APP_DIR="$APP_DIR" bash "$APP_DIR/scripts/run-gpu-server.sh" \
    </dev/null >> "$APP_DIR/logs/console.log" 2>&1 9>&- &
pid=$!
token=$(proc_token "$pid") || { wait "$pid" || true; echo '[ERROR] Launcher exited; inspect logs/console.log' >&2; exit 1; }
printf '%s\n' "$token" > "$APP_DIR/run.start"
printf '%s\n' "$pid" > "$APP_DIR/run.pid"
sleep .2
if [[ "$(proc_token "$pid" || true)" != "$token" ]]; then
    code=0; wait "$pid" || code=$?
    rm -f "$APP_DIR/run.pid" "$APP_DIR/run.start"
    tail -n 20 "$APP_DIR/logs/console.log" >&2 || true
    echo "[ERROR] Launcher exited (exit=$code); inspect logs/console.log" >&2; exit 1
fi
echo "[INFO] Started PID=$pid; log: $APP_DIR/logs/console.log"
echo '[INFO] Wait for gesture server ready in the log before sending requests'
