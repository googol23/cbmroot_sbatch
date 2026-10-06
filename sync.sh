#!/usr/bin/env bash

DEST=${1:-/lustre/cbm/users/dramirez/slurm_scripts_v3/}

# rsync -av \
#     --include='*.sbash' \
#     --include='*.sh' \
#     --include='*.yaml' \
#     --include='*.yml' \
#     --exclude='*' \
#     ./ "$DEST"

rsync -av -e "ssh " \
    --include='*.sbash' \
    --include='*.sh' \
    --include='*.py' \
    --include='*.yaml' \
    --include='*.yml' \
    --include='*.C' \
    --exclude='*' \
    ./ "dramirez@lustre.hpc.gsi.de:${DEST}"

echo ${DEST}