#!/usr/bin/env bash
# Foreground launcher for systemd or manual diagnosis; supervisor owns the PID.
set -euo pipefail
APP_DIR=${APP_DIR:-/u01/ims/mediapipe_gesture}
if [[ -z "${VENV_DIR:-}" && -f "$APP_DIR/.app_venv" ]]; then
    IFS= read -r VENV_DIR < "$APP_DIR/.app_venv" || [[ -n "$VENV_DIR" ]] || {
        echo '[ERROR] Empty .app_venv; set VENV_DIR explicitly' >&2; exit 1;
    }
fi
VENV_DIR=${VENV_DIR:-$APP_DIR/libs/venv}
[[ "$APP_DIR" == /* && "$VENV_DIR" == /* ]] || { echo '[ERROR] APP_DIR/VENV_DIR must be absolute' >&2; exit 1; }
[[ -x "$VENV_DIR/bin/mediapipe-gesture-server" && -f "$APP_DIR/etc/config.yaml" ]] || {
    echo '[ERROR] Missing worker/config; run setup-gpu-server.sh first' >&2; exit 1;
}
export PYTHONUNBUFFERED=1
export MPLCONFIGDIR=${MPLCONFIGDIR:-$APP_DIR/run/matplotlib}
mkdir -p "$APP_DIR/logs" "$MPLCONFIGDIR"
command -v flock >/dev/null || { echo '[ERROR] flock is required' >&2; exit 1; }
exec 8> "$APP_DIR/run/gpu-server.lock"
flock -n 8 || { echo '[ERROR] Gesture is already running or setup is active' >&2; exit 1; }
printf '[INFO] APP_DIR=%s VENV_DIR=%s CONFIG=%s/etc/config.yaml\n' "$APP_DIR" "$VENV_DIR" "$APP_DIR"
cd -- "$APP_DIR"
exec "$VENV_DIR/bin/mediapipe-gesture-server" --config "$APP_DIR/etc/config.yaml"
