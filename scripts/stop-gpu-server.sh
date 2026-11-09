#!/usr/bin/env bash
# Template installed by setup as APP_DIR/stop.sh; only controls start.sh's process.
set -euo pipefail
APP_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -f "$APP_DIR/.gpu-server-deployment" ]] || { echo '[ERROR] Run the generated APP_DIR/stop.sh after setup' >&2; exit 1; }
mkdir -p "$APP_DIR/run"
exec 9> "$APP_DIR/run/gpu-management.lock"
flock -x 9
[[ -f "$APP_DIR/run.pid" ]] || { echo '[INFO] No background PID; stop foreground with Ctrl+C or systemd with systemctl'; exit 0; }
pid=$(cat "$APP_DIR/run.pid")
[[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || { echo '[ERROR] Invalid run.pid' >&2; exit 1; }
saved=$(cat "$APP_DIR/run.start" 2>/dev/null || true)
[[ "$saved" =~ ^[0-9]+$ ]] || { echo '[ERROR] Missing/invalid run.start; refusing to signal an unverified PID' >&2; exit 1; }
proc_token() {
    local record rest; local -a fields
    [[ -r "/proc/$pid/stat" ]] || return 1
    IFS= read -r record < "/proc/$pid/stat" || return 1
    rest=${record##*) }; read -r -a fields <<< "$rest"
    [[ "${fields[0]}" != Z && "${fields[0]}" != X ]] || return 1
    printf '%s\n' "${fields[19]}"
}
if [[ "$(proc_token || true)" != "$saved" ]]; then
    rm -f "$APP_DIR/run.pid" "$APP_DIR/run.start"
    echo '[INFO] Stale background metadata cleared; no signal sent'; exit 0
fi
kill -TERM "$pid"
deadline=$((SECONDS + 35))
while [[ "$(proc_token || true)" == "$saved" ]]; do
    if (( SECONDS >= deadline )); then
        echo "[ERROR] Shutdown timeout PID=$pid; metadata retained" >&2; exit 1
    fi
    sleep .1
done
rm -f "$APP_DIR/run.pid" "$APP_DIR/run.start"
echo "[INFO] Stopped PID=$pid"
