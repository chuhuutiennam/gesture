#!/usr/bin/env bash
# Bare-metal setup/update, following Nemotron's SRC_DIR -> APP_DIR -> venv flow.
# Source: /u01/ims/namcht/gesture; runtime: /u01/ims/mediapipe_gesture.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SRC_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
APP_DIR=${APP_DIR:-/u01/ims/mediapipe_gesture}
VENV_DIR=${VENV_DIR:-}
PYTHON_BIN=${PYTHON:-python3.12}
WHEELS_DIR=${WHEELS_DIR:-$SRC_DIR/wheels}
MODEL= DELEGATE=gpu SERVICE_USER=${SUDO_USER:-$(id -un)}
SYSTEMD=false DRY_RUN=false
UNIT=mediapipe-gesture
info() { printf '[INFO] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
Usage: bash scripts/setup-gpu-server.sh [--systemd] [--dry-run] [options]
  --app-dir DIR       Runtime directory (default /u01/ims/mediapipe_gesture)
  --venv DIR          Existing APP_DIR/.app_venv, otherwise APP_DIR/libs/venv
  --python FILE       Interpreter for a new venv (default python3.12)
  --wheels-dir DIR    Offline wheelhouse (default SRC_DIR/wheels)
  --model FILE        Initial model (default SRC_DIR/checkpoint/gesture_recognizer.task)
  --delegate cpu|gpu  New config only (default gpu); existing YAML is preserved
  --service-user USER Runtime user (default SUDO_USER or current user)
  --systemd          Install/enable service; does not start it
  --dry-run          Check inputs and print the deployment plan/unit without writes
Stop gesture, re-run this setup after a source update, then start it again.
HELP
}
while (( $# )); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --systemd) SYSTEMD=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --app-dir|--venv|--python|--wheels-dir|--model|--delegate|--service-user)
            (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] || die "Missing value for $1"
            case "$1" in
                --app-dir) APP_DIR=$2 ;; --venv) VENV_DIR=$2 ;; --python) PYTHON_BIN=$2 ;;
                --wheels-dir) WHEELS_DIR=$2 ;; --model) MODEL=$2 ;;
                --delegate) DELEGATE=$2 ;; --service-user) SERVICE_USER=$2 ;;
            esac
            shift 2 ;;
        *) die "Unknown option: $1 (use --help)" ;;
    esac
done
for name in realpath flock; do command -v "$name" >/dev/null || die "Required command missing: $name"; done
[[ "$APP_DIR" == /* ]] || die 'APP_DIR must be absolute'
APP_DIR=$(realpath -m -- "$APP_DIR")
case "$APP_DIR" in /|/u01|/u01/ims|/u01/ims/namcht) die "Unsafe APP_DIR: $APP_DIR" ;; esac
[[ ! -e "$APP_DIR/etc/nemotron-engine.yaml" && "$APP_DIR" != /u01/ims/ai-engine && "$APP_DIR" != /u01/ims/ai-engine/* ]] || die 'APP_DIR belongs to Nemotron'
[[ "$APP_DIR" != "$SRC_DIR" && "$SRC_DIR/" != "$APP_DIR/"* && "$APP_DIR/" != "$SRC_DIR/"* ]] || die 'Source and APP_DIR must be separate, non-nested directories'
[[ "$DELEGATE" == cpu || "$DELEGATE" == gpu ]] || die '--delegate must be cpu or gpu'
if [[ -z "$VENV_DIR" && -f "$APP_DIR/.app_venv" ]]; then
    IFS= read -r VENV_DIR < "$APP_DIR/.app_venv" || [[ -n "$VENV_DIR" ]] || die 'Empty .app_venv; pass --venv'
fi
VENV_DIR=${VENV_DIR:-$APP_DIR/libs/venv}
[[ "$VENV_DIR" == /* ]] || die 'VENV_DIR must be absolute'
VENV_DIR=$(realpath -m -- "$VENV_DIR")
[[ "$VENV_DIR" != /opt/nemotron-venv && "$VENV_DIR" != /opt/nemotron-venv/* && "$VENV_DIR" != / ]] || die 'Cannot use the Nemotron venv or filesystem root'
WHEELS_DIR=$(realpath -m -- "$WHEELS_DIR")
MODEL=${MODEL:-$SRC_DIR/checkpoint/gesture_recognizer.task}
for name in src scripts assets etc/config.yaml pyproject.toml setup.py MANIFEST.in README.md; do
    [[ -e "$SRC_DIR/$name" ]] || die "Missing source: $name"
done
for name in src scripts assets; do [[ ! -L "$APP_DIR/$name" ]] || die "Deployment directory must not be a symlink: $APP_DIR/$name"; done
[[ -s "$APP_DIR/models/gesture_recognizer.task" || -s "$MODEL" ]] || die "Checkpoint missing: $MODEL (use --model FILE)"
[[ -d "$WHEELS_DIR" ]] || die "Offline wheelhouse missing: $WHEELS_DIR"
wheels=()
while IFS= read -r -d '' wheel; do wheels+=("$wheel"); done < <(find "$WHEELS_DIR" -type f -name '*.whl' -print0 | sort -z)
(( ${#wheels[@]} )) || die "No wheels in $WHEELS_DIR"
command -v "$PYTHON_BIN" >/dev/null || die "Python missing: $PYTHON_BIN"
"$PYTHON_BIN" -c 'import sys; assert sys.version_info >= (3,11), "Python 3.11+ required"'
if [[ "$DELEGATE" == gpu ]]; then
    command -v nvidia-smi >/dev/null || die 'nvidia-smi missing; check the existing NVIDIA driver with the administrator'
    gpu_info=$(nvidia-smi --query-gpu=index,name,driver_version,memory.total --format=csv,noheader)
    [[ -n "$gpu_info" ]] || die 'No NVIDIA GPU detected'
    printf '%s\n' "$gpu_info"
fi
if $SYSTEMD; then
    id "$SERVICE_USER" >/dev/null || die "Unknown service user: $SERVICE_USER"
    command -v systemctl >/dev/null || die 'systemctl missing'
    [[ "$APP_DIR" =~ ^/[a-zA-Z0-9_./-]+$ && "$VENV_DIR" =~ ^/[a-zA-Z0-9_./-]+$ ]] || die 'systemd paths must not contain spaces or specifiers'
    if ! $DRY_RUN; then (( EUID == 0 )) || die 'Use sudo for --systemd'; fi
fi
render_unit() {
    cat <<UNITFILE
[Unit]
Description=MediaPipe Gesture Worker
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$APP_DIR
Environment="APP_DIR=$APP_DIR"
Environment="VENV_DIR=$VENV_DIR"
EnvironmentFile=-/etc/mediapipe-gesture/env
ExecStart=/bin/bash $APP_DIR/scripts/run-gpu-server.sh
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mediapipe-gesture
KillSignal=SIGTERM
TimeoutStopSec=35s

[Install]
WantedBy=multi-user.target
UNITFILE
}
info "SRC_DIR=$SRC_DIR APP_DIR=$APP_DIR VENV_DIR=$VENV_DIR"
if $DRY_RUN; then
    info 'DRY RUN: create/reuse venv and bootstrap pip with ensurepip if needed'
    info "DRY RUN: deploy src/scripts/assets, preserving runtime YAML/model; install ${#wheels[@]} wheels offline"
    info 'DRY RUN: install app from APP_DIR, validate imports/config and generate APP_DIR/start.sh + stop.sh'
    info 'DRY RUN: rsync --delete if available, otherwise cp -r; no service starts or native model probe'
    if $SYSTEMD; then render_unit; fi
    exit 0
fi
mkdir -p "$APP_DIR/run"
# The foreground launcher holds the same lock throughout the worker lifetime.
exec 8> "$APP_DIR/run/gpu-server.lock"
flock -n 8 || die 'Gesture is running or another setup is active; stop gesture before setup'
if command -v systemctl >/dev/null && systemctl is-active --quiet "$UNIT"; then
    die "Stop $UNIT with systemctl before setup"
fi
for pid_file in "$APP_DIR/run.pid" "$APP_DIR/run/mediapipe-gesture.pid"; do
    if [[ -f "$pid_file" ]]; then
        IFS= read -r gesture_pid < "$pid_file" || true
        if [[ "${gesture_pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$gesture_pid" 2>/dev/null; then
            die "Gesture PID=$gesture_pid is still alive; stop it before setup"
        fi
    fi
done
# Detect direct launchers from the previous deployment which had no lifetime lock.
"$PYTHON_BIN" - "$APP_DIR/etc/config.yaml" <<'PYRUNNING'
import os, sys
from pathlib import Path
config = str(Path(sys.argv[1]).resolve())
for process in Path('/proc').iterdir():
    if not process.name.isdigit() or int(process.name) == os.getpid():
        continue
    try:
        args = process.joinpath('cmdline').read_bytes().decode(errors='replace').split('\0')
    except OSError:
        continue
    worker = any(Path(arg).name == 'mediapipe-gesture-server' or arg == 'mediapipe_gesture.server' for arg in args)
    configs = [args[i+1] for i, arg in enumerate(args[:-1]) if arg == '--config']
    configs += [arg.split('=', 1)[1] for arg in args if arg.startswith('--config=')]
    if worker and any(str(Path(value).resolve()) == config for value in configs):
        raise SystemExit(f'Gesture PID={process.name} is running with {config}; stop it before setup')
PYRUNNING
info '=== Creating/reusing virtualenv ==='
if [[ ! -x "$VENV_DIR/bin/python" ]]; then "$PYTHON_BIN" -m venv --without-pip "$VENV_DIR"; fi
if ! "$VENV_DIR/bin/python" -m pip --version >/dev/null 2>&1; then
    "$VENV_DIR/bin/python" -m ensurepip --upgrade || die 'Cannot bootstrap pip; check the Python venv/ensurepip installation'
fi
info '=== Deploying source to APP_DIR ==='
mkdir -p "$APP_DIR"/{src,scripts,assets,etc,logs,models}
for name in src scripts assets; do
    if command -v rsync >/dev/null; then
        rsync -a --delete --exclude '__pycache__/' "$SRC_DIR/$name/" "$APP_DIR/$name/"
    else
        info "rsync unavailable; using cp -r for $name (removed source files are retained)"
        cp -r -- "$SRC_DIR/$name/." "$APP_DIR/$name/"
    fi
done
chmod +x "$APP_DIR/scripts/"*.sh
for name in pyproject.toml setup.py MANIFEST.in README.md; do cp -- "$SRC_DIR/$name" "$APP_DIR/$name"; done
bash "$SCRIPT_DIR/copy-models.sh" --app-dir "$APP_DIR" --src "$MODEL"
info '=== Installing wheels offline ==='
"$VENV_DIR/bin/python" -m pip install --no-index --find-links "$WHEELS_DIR" --no-deps --no-build-isolation "${wheels[@]}"
info '=== Installing application from APP_DIR ==='
"$VENV_DIR/bin/python" -m pip install --no-index --no-deps --no-build-isolation "$APP_DIR"
"$VENV_DIR/bin/python" -m pip check
if [[ ! -f "$APP_DIR/etc/config.yaml" ]]; then
    "$VENV_DIR/bin/python" - "$SRC_DIR/etc/config.yaml" "$APP_DIR" "$DELEGATE" <<'PYCONFIG'
import pathlib, sys, yaml
source, app, delegate = sys.argv[1:]
root = pathlib.Path(app)
cfg = yaml.safe_load(pathlib.Path(source).read_text())
cfg['gesture'].update(enabled=True, model=str(root/'models/gesture_recognizer.task'), delegate=delegate)
cfg['server']['addr'] = '127.0.0.1:50053'
cfg['metrics'].update(enabled=True, port=9102)
cfg['logging']['file'] = str(root/'logs/mediapipe-gesture.log')
(root/'etc/config.yaml').write_text(yaml.safe_dump(cfg, sort_keys=False))
PYCONFIG
else
    info 'Existing etc/config.yaml preserved'
fi
info '=== Validating installation ==='
"$VENV_DIR/bin/python" - "$APP_DIR/etc/config.yaml" <<'PYVALIDATE'
import importlib, sys
from pathlib import Path
for name in ('mediapipe', 'grpc', 'grpc_tools', 'google.protobuf', 'cv2', 'numpy', 'yaml', 'prometheus_client'):
    module = importlib.import_module(name)
    print(f'  {name}: {getattr(module, "__version__", "import OK")}')
from mediapipe_gesture.config import load_config
from mediapipe_gesture.server import Worker
cfg = load_config(Path(sys.argv[1]))
if not cfg.gesture.enabled or not cfg.gesture.model or not cfg.gesture.model.is_file():
    raise SystemExit('Set gesture.enabled=true and gesture.model to an existing checkpoint')
print(f'  config: {sys.argv[1]} delegate={cfg.gesture.delegate} grpc={cfg.server.addr} metrics={cfg.metrics.port}')
if cfg.gesture.delegate != 'gpu':
    print('[WARN] Existing YAML uses CPU; edit gesture.delegate: gpu to enable GPU')
print('[OK] Installation validated. The worker initializes the real model when started.')
PYVALIDATE
printf '%s\n' "$VENV_DIR" > "$APP_DIR/.app_venv"
printf 'nemotron-layout-v1\n' > "$APP_DIR/.gpu-server-deployment"
install -m 0755 "$APP_DIR/scripts/start-gpu-server.sh" "$APP_DIR/start.sh"
install -m 0755 "$APP_DIR/scripts/stop-gpu-server.sh" "$APP_DIR/stop.sh"
if (( EUID == 0 )); then
    id "$SERVICE_USER" >/dev/null || die "Unknown service user: $SERVICE_USER"
    chown "$SERVICE_USER:$(id -gn "$SERVICE_USER")" "$APP_DIR"
    chown -R "$SERVICE_USER:$(id -gn "$SERVICE_USER")" "$APP_DIR/logs" "$APP_DIR/run"
fi
if $SYSTEMD; then
    render_unit > "/etc/systemd/system/$UNIT.service"
    mkdir -p /etc/mediapipe-gesture
    if [[ ! -e /etc/mediapipe-gesture/env ]]; then
        printf '# Gesture environment only. Runtime config: APP_DIR/etc/config.yaml\n' > /etc/mediapipe-gesture/env
    fi
    systemctl daemon-reload
    systemctl enable "$UNIT"
fi
info '=== Setup complete; no service started ==='
info "Foreground: bash $APP_DIR/scripts/run-gpu-server.sh"
info "Background: bash $APP_DIR/start.sh; stop: bash $APP_DIR/stop.sh"
info 'Update: stop gesture, re-run setup-gpu-server.sh from SRC_DIR, then start again'
if $SYSTEMD; then info "Systemd: systemctl start $UNIT"; fi
