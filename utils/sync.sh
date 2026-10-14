#!/usr/bin/env bash

DEST=${1:-/lustre/cbm/users/${USER}/slurm_scripts_v3/}

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

rsync -av -e "ssh " \
    --exclude='__pycache__/' \
    --include='/run_jobs.sh' \
    --include='/run_common.sh' \
    --include='/sbash/***' \
    --include='/macros/***' \
    --include='/config/***' \
    --include='/utils/***' \
    --exclude='*' \
    "${PROJECT_DIR}/" "${USER}@lustre.hpc.gsi.de:${DEST}"

printf '%s\n' "${DEST}"