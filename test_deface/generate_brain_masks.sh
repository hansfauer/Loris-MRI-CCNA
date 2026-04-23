#!/bin/bash
# Generate SynthStrip brain masks for each original T1w NIfTI.
# These binary masks serve as ground-truth brain ROIs for the defacing QC
# script (defacing_qc.py), which uses them to verify that no brain tissue
# was removed by any of the defacing algorithms.
#
# Prerequisites: FreeSurfer >= 7.3 (provides mri_synthstrip)
# Usage: ./generate_brain_masks.sh [CandID ...]
#   If no CandIDs are given, processes the default test-batch subjects.

set -euo pipefail
source "$(dirname "$0")/setup_env.sh"

SRCBASE="/data/hans/BIDS_CND/sourcedata/nifti"
MASKDIR="/data/hans/BIDS_CND/derivatives/brain_masks"

DEFAULT_SUBJECTS="100589 100659 100673 117632"
SUBJECTS="${*:-$DEFAULT_SUBJECTS}"

for sid in $SUBJECTS; do
    input="${SRCBASE}/sub-${sid}/ses-InitialMRI/anat/sub-${sid}_ses-InitialMRI_T1w.nii.gz"
    outdir="${MASKDIR}/sub-${sid}/ses-InitialMRI/anat"
    stripped="${outdir}/sub-${sid}_ses-InitialMRI_T1w_brain.nii.gz"
    mask="${outdir}/sub-${sid}_ses-InitialMRI_T1w_brain-mask.nii.gz"

    if [ -f "$mask" ]; then
        echo "SKIP: ${mask} already exists"
        continue
    fi

    if [ ! -f "$input" ]; then
        echo "WARN: No input NIfTI for sub-${sid}, skipping"
        continue
    fi

    mkdir -p "$outdir"

    echo "SynthStrip: sub-${sid} ..."
    mri_synthstrip -i "$input" -o "$stripped" -m "$mask"
    echo "  -> ${mask}"
done

echo "Done. Brain masks written under ${MASKDIR}/"
