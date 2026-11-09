#!/usr/bin/env bash
# Native model initialization probe. Run with the same user/env as the service.
set -euo pipefail
APP_DIR=${APP_DIR:-/u01/ims/mediapipe_gesture}
if [[ -z "${VENV_DIR:-}" && -f "$APP_DIR/.app_venv" ]]; then
    IFS= read -r VENV_DIR < "$APP_DIR/.app_venv" || [[ -n "$VENV_DIR" ]] || {
        echo '[ERROR] Empty .app_venv; set VENV_DIR explicitly' >&2; exit 1;
    }
fi
VENV_DIR=${VENV_DIR:-$APP_DIR/libs/venv}
[[ "$APP_DIR" == /* && "$VENV_DIR" == /* ]] || { echo '[ERROR] APP_DIR/VENV_DIR must be absolute' >&2; exit 1; }
[[ -x "$VENV_DIR/bin/python" && -f "$APP_DIR/etc/config.yaml" ]] || {
    echo '[ERROR] Missing Python/config; run setup-gpu-server.sh first' >&2; exit 1;
}
export MPLCONFIGDIR=${MPLCONFIGDIR:-$APP_DIR/run/matplotlib}
mkdir -p "$MPLCONFIGDIR"
cd -- "$APP_DIR"
timeout 120 "$VENV_DIR/bin/python" - "$APP_DIR/etc/config.yaml" <<'PYPROBE'
import ctypes, sys
from pathlib import Path
import mediapipe
from mediapipe_gesture.config import load_config
from mediapipe_gesture.server import Worker
cfg = load_config(Path(sys.argv[1]))
if not cfg.gesture.enabled or not cfg.gesture.model or not cfg.gesture.model.is_file():
    raise SystemExit('Set gesture.enabled=true and gesture.model to an existing checkpoint')
print(f'MediaPipe={mediapipe.__version__} delegate={cfg.gesture.delegate} model={cfg.gesture.model}', flush=True)
if cfg.gesture.delegate == 'gpu':
    for library in ('libEGL.so.1', 'libGLESv2.so.2'):
        ctypes.CDLL(library)
        print(f'{library}: load OK', flush=True)
else:
    print('[WARN] Existing YAML uses CPU. To enable GPU, edit gesture.delegate and restart.', flush=True)
Worker(cfg).probe()
print('[OK] Native model initialization passed (does not measure throughput or GPU utilization).', flush=True)
PYPROBE
