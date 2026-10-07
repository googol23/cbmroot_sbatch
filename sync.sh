#!/usr/bin/env bash

DEST=${1:-/lustre/cbm/users/${USER}/slurm_scripts_v3/}

rsync -av -e "ssh " \
    --include='*.sbash' \
    --include='*.sh' \
    --include='*.py' \
    --include='*.yaml' \
    --include='*.yml' \
    --include='*.C' \
    --exclude='*' \
    ./ "${USER}@lustre.hpc.gsi.de:${DEST}"

echo ${DEST}