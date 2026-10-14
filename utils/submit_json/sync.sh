#!/usr/bin/env bash

DEST=/u/dramirez/LUSTRE/cbm/users/dramirez/submit_json/

# rsync -av \
#     --include='*.sbash' \
#     --include='*.sh' \
#     --include='*.yaml' \
#     --include='*.yml' \
#     --exclude='*' \
#     ./ "$DEST"

rsync -av -e "ssh " \
    --include='*.sh' \
    --include='*.json' \
    --exclude='*' \
    ./ "dramirez@lustre.hpc.gsi.de:/lustre/cbm/users/dramirez/submit_json/"