#!/usr/bin/env bash
# Preserve the deployed model by default; --replace explicitly updates it.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
APP_DIR=${APP_DIR:-/u01/ims/mediapipe_gesture}
MODEL_SOURCE="$SCRIPT_DIR/../checkpoint"
DRY_RUN=false REPLACE=false
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
while (( $# )); do
    case "$1" in
        -h|--help) echo 'Usage: copy-models.sh [--src MODEL_DIR_OR_FILE] [--app-dir DIR] [--dry-run] [--replace]'; exit 0 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --replace) REPLACE=true; shift ;;
        --src|--app-dir)
            (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] || die "Missing value for $1"
            case "$1" in --src) MODEL_SOURCE=$2 ;; --app-dir) APP_DIR=$2 ;; esac
            shift 2 ;;
        *) die "Unknown option: $1" ;;
    esac
done
[[ "$APP_DIR" == /* ]] || die 'APP_DIR must be absolute'
APP_DIR=$(realpath -m -- "$APP_DIR")
[[ "$APP_DIR" != / && "$APP_DIR" != /u01 && "$APP_DIR" != /u01/ims && "$APP_DIR" != /u01/ims/namcht ]] || die "Unsafe APP_DIR: $APP_DIR"
[[ "$APP_DIR" != /u01/ims/ai-engine && "$APP_DIR" != /u01/ims/ai-engine/* && ! -e "$APP_DIR/etc/nemotron-engine.yaml" ]] || die 'APP_DIR belongs to Nemotron'
target="$APP_DIR/models/gesture_recognizer.task"
source_model="$MODEL_SOURCE/gesture_recognizer.task"
if [[ -f "$MODEL_SOURCE" ]]; then source_model=$MODEL_SOURCE; fi
if [[ -s "$target" ]] && ! $REPLACE; then echo "[INFO] Preserving $target"; exit 0; fi
[[ -s "$source_model" && -r "$source_model" ]] || die "Model missing/unreadable: $source_model"
if [[ -e "$target" && "$source_model" -ef "$target" ]]; then echo '[INFO] Source and target model are identical'; exit 0; fi
echo "[INFO] $source_model -> $target"
if $DRY_RUN; then echo '[INFO] DRY RUN: no files written'; exit 0; fi
mkdir -p "$APP_DIR/models"
temp_model=$(mktemp "$APP_DIR/models/.gesture-model.XXXXXX")
trap 'rm -f -- "$temp_model"' EXIT
cp -- "$source_model" "$temp_model"
chmod 0644 "$temp_model"
mv -f -- "$temp_model" "$target"
echo "[OK] Model copied: $target"
