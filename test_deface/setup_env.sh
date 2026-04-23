#!/bin/bash
# Environment setup for CCNA defacing test pipeline
# Sources MINC toolkit (for mnc2nii) and FreeSurfer (for mideface/mri_deface)

# --- Production data safety guard ---
# /ccna-prod-data is an NFS mount that MUST remain read-only.
# Verify at script startup; abort if the mount is ever writable.
PROD_DATA="/ccna-prod-data"
if mountpoint -q "$PROD_DATA" 2>/dev/null; then
    mount_opts=$(mount | grep " ${PROD_DATA} " | head -1)
    if echo "$mount_opts" | grep -qv '\bro\b'; then
        echo "FATAL: ${PROD_DATA} is NOT mounted read-only. Aborting to protect production data." >&2
        echo "Mount info: ${mount_opts}" >&2
        exit 1
    fi
elif [ -d "$PROD_DATA" ]; then
    if [ -w "$PROD_DATA" ]; then
        echo "FATAL: ${PROD_DATA} appears writable and is not a read-only mount. Aborting." >&2
        exit 1
    fi
fi
export CCNA_PROD_DATA_RO="$PROD_DATA"

source /opt/minc/1.9.18/minc-toolkit-config.sh

export FREESURFER_HOME=/data/hans/freesurfer
# SetUpFreeSurfer.sh uses unguarded variable checks and commands that return
# non-zero (e.g. grep on missing patterns). Relax strict mode for sourcing.
set +eu
source "$FREESURFER_HOME/SetUpFreeSurfer.sh"
set -eu
export FS_LICENSE="$FREESURFER_HOME/license.txt"
