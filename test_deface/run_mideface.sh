#!/bin/bash
# Run FreeSurfer mideface (Minimally Invasive DeFacing) on converted NIfTI T1w files
# Aligned with MPN mpn_freesurfer_mideface.json Boutiques descriptor logic
# See: https://surfer.nmr.mgh.harvard.edu/fswiki/MiDeFace
#
# Usage: ./run_mideface.sh <CandID> [CandID2 ...]

set -euo pipefail
source "$(dirname "$0")/setup_env.sh"

SRCBASE="/data/hans/BIDS_CND/sourcedata/nifti"
OUTBASE="/data/hans/BIDS_CND/derivatives/mideface"

SUFFIX="${SUFFIX:-T1w}"
case "$SUFFIX" in
    T1w|T2w|PDw|FLAIR) ;;
    *)
        echo "ERROR: Unsupported SUFFIX='$SUFFIX' (expected T1w|T2w|PDw|FLAIR)" >&2
        exit 1
        ;;
esac

deface_subject() {
    local candid=$1
    local input="${SRCBASE}/sub-${candid}/ses-InitialMRI/anat/sub-${candid}_ses-InitialMRI_${SUFFIX}.nii.gz"

    if [ ! -f "$input" ]; then
        echo "WARN: No NIfTI for ${candid}, run conversion first"
        return 1
    fi

    local outdir="${OUTBASE}/sub-${candid}/ses-InitialMRI/anat"
    # Keep QA stats isolated per modality to avoid overwriting when running multiple suffixes.
    local qadir="${outdir}/qa_${SUFFIX}"
    local output="${outdir}/sub-${candid}_ses-InitialMRI_${SUFFIX}_defaced.nii.gz"

    if [ -f "$output" ]; then
        echo "SKIP: ${output} already exists"
        return 0
    fi

    mkdir -p "$qadir"

    mideface --i "$input" \
             --o "$output" \
             --odir "$qadir" \
             --threads 1

    if [ ! -f "$output" ]; then
        echo "ERROR: mideface did not produce output for ${candid}"
        return 1
    fi

    echo "OK mideface: ${candid} -> ${output}"
}

for candid in "$@"; do
    deface_subject "$candid" || true
done
