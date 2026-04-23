#!/bin/bash
# Convert CCNA MINC T1w files to NIfTI (.nii.gz) for defacing tests
# Usage: ./convert_mnc_to_nii.sh <CandID> [CandID2 ...]
#    or: ./convert_mnc_to_nii.sh --list subjects.txt

set -euo pipefail
source "$(dirname "$0")/setup_env.sh"

ASSEMBLY="/ccna-prod-data/ccna/data/assembly"
OUTBASE="/data/hans/BIDS_CND/sourcedata/nifti"

convert_subject() {
    local candid=$1
    local mnc_file="${ASSEMBLY}/${candid}/Initial_MRI/mri/native/ccna_${candid}_Initial_MRI_3d_t1w_001.mnc"

    if [ ! -f "$mnc_file" ]; then
        echo "WARN: No T1w MINC file for ${candid}, skipping"
        return 1
    fi

    local outdir="${OUTBASE}/sub-${candid}/ses-InitialMRI/anat"
    local nii_gz="${outdir}/sub-${candid}_ses-InitialMRI_T1w.nii.gz"

    if [ -f "$nii_gz" ]; then
        echo "SKIP: ${nii_gz} already exists"
        return 0
    fi

    mkdir -p "$outdir"
    local nii_file="${outdir}/sub-${candid}_ses-InitialMRI_T1w.nii"

    mnc2nii -nii -short "$mnc_file" "$nii_file"
    gzip -f "$nii_file"
    echo "OK: ${candid} -> ${nii_gz}"
}

if [ "$1" = "--list" ]; then
    while IFS= read -r candid; do
        [ -z "$candid" ] && continue
        convert_subject "$candid" || true
    done < "$2"
else
    for candid in "$@"; do
        convert_subject "$candid" || true
    done
fi
