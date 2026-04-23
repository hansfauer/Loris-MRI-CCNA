#!/bin/bash
# Run FreeSurfer mri_deface (legacy) on converted NIfTI T1w files
# Uses GCA templates to identify and remove facial features
# See: https://surfer.nmr.mgh.harvard.edu/fswiki/mri_deface
#
# This is a bonus third comparison method that works out of the box
# with the installed FreeSurfer 7.4.1.
#
# Usage: ./run_mri_deface.sh <CandID> [CandID2 ...]

set -euo pipefail
source "$(dirname "$0")/setup_env.sh"

SRCBASE="/data/hans/BIDS_CND/sourcedata/nifti"
OUTBASE="/data/hans/BIDS_CND/derivatives/mri_deface"

SUFFIX="${SUFFIX:-T1w}"
case "$SUFFIX" in
    T1w|T2w|PDw|FLAIR) ;;
    *)
        echo "ERROR: Unsupported SUFFIX='$SUFFIX' (expected T1w|T2w|PDw|FLAIR)" >&2
        exit 1
        ;;
esac

BRAIN_TEMPLATE="${FREESURFER_HOME}/average/talairach_mixed_with_skull.gca"
FACE_TEMPLATE="${FREESURFER_HOME}/average/face.gca"

if [ ! -f "$BRAIN_TEMPLATE" ] || [ ! -f "$FACE_TEMPLATE" ]; then
    echo "ERROR: GCA templates not found in ${FREESURFER_HOME}/average/"
    exit 1
fi

deface_subject() {
    local candid=$1
    local input="${SRCBASE}/sub-${candid}/ses-InitialMRI/anat/sub-${candid}_ses-InitialMRI_${SUFFIX}.nii.gz"

    if [ ! -f "$input" ]; then
        echo "WARN: No NIfTI for ${candid}, run conversion first"
        return 1
    fi

    local outdir="${OUTBASE}/sub-${candid}/ses-InitialMRI/anat"
    local output="${outdir}/sub-${candid}_ses-InitialMRI_${SUFFIX}_deface-legacy.nii.gz"

    if [ -f "$output" ]; then
        echo "SKIP: ${output} already exists"
        return 0
    fi

    mkdir -p "$outdir"

    mri_deface "$input" "$BRAIN_TEMPLATE" "$FACE_TEMPLATE" "$output"

    echo "OK mri_deface: ${candid} -> ${output}"
}

for candid in "$@"; do
    deface_subject "$candid" || true
done
