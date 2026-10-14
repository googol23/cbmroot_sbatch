#!/usr/bin/env bash
set -euo pipefail

: "${1:?Usage: sync.sh DEST SYNC_HOST}"
: "${2:?Usage: sync.sh DEST SYNC_HOST}"
DEST="$1"
SYNC_HOST="$2"

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
printf -v QUOTED_DEST '%q' "$DEST"

ssh "${USER}@${SYNC_HOST}" "mkdir -p -- ${QUOTED_DEST}"

rsync -av -e "ssh " \
    --exclude='__pycache__/' \
    --include='/run_jobs.sh' \
    --include='/run_common.sh' \
    --include='/sbash/***' \
    --include='/macros/***' \
    --include='/config/***' \
    --include='/utils/***' \
    --exclude='*' \
    "${PROJECT_DIR}/" "${USER}@${SYNC_HOST}:${DEST}"

printf '%s\n' "${DEST}"