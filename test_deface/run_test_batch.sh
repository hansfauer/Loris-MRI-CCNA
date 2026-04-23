#!/bin/bash
# Master test script: orchestrates the full defacing test pipeline
# Runs convert -> mri_deface -> mideface -> mri_reface -> masks -> QC -> gallery
#
# Usage: ./run_test_batch.sh
# Edit TEST_SUBJECTS below to change which subjects to process.
# Optional: SUFFIXES="T1w T2w PDw FLAIR" (default) to limit modalities.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_SUBJECTS="100589 100659 100673 117632"
SUFFIXES_DEFAULT="T1w T2w PDw FLAIR"
SUFFIXES="${SUFFIXES:-$SUFFIXES_DEFAULT}"

echo "============================================"
echo " CCNA COMPASS-ND Defacing Test Pipeline"
echo " Subjects: ${TEST_SUBJECTS}"
echo " Modalities: ${SUFFIXES}"
echo " Started:  $(date)"
echo "============================================"

docker_has_mri_reface=0
if docker images --format '{{.Repository}}' 2>/dev/null | grep -q '^mri_reface$'; then
    docker_has_mri_reface=1
fi

for suffix in $SUFFIXES; do
    export SUFFIX="$suffix"

    echo ""
    echo "=== Step 1.${suffix}: Convert DICOM to NIfTI (${suffix}) ==="
    bash "$SCRIPT_DIR/convert_dcm_to_nii.sh" $TEST_SUBJECTS

    echo ""
    echo "=== Step 2.${suffix}: Run mri_deface (${suffix}) ==="
    bash "$SCRIPT_DIR/run_mri_deface.sh" $TEST_SUBJECTS

    echo ""
    echo "=== Step 3.${suffix}: Run mideface (${suffix}) ==="
    bash "$SCRIPT_DIR/run_mideface.sh" $TEST_SUBJECTS

    echo ""
    echo "=== Step 4.${suffix}: Run mri_reface (${suffix}) ==="
    if [ "$docker_has_mri_reface" -eq 1 ]; then
        bash "$SCRIPT_DIR/run_mri_reface.sh" $TEST_SUBJECTS
    else
        echo "SKIP: mri_reface Docker image not found."
        echo "  Ensure mri_reface_0.3.5_docker.zip is extracted and docker load has been run."
    fi
done

echo ""
echo "=== Step 5: Generate SynthStrip brain masks (T1w only) ==="
bash "$SCRIPT_DIR/generate_brain_masks.sh" $TEST_SUBJECTS

echo ""
echo "=== Step 6: Resample T1w masks into other modalities ==="
bash "$SCRIPT_DIR/resample_masks.sh" $TEST_SUBJECTS

echo ""
echo "=== Step 7: Quantitative QC (defacing_qc.py) per modality ==="
for suffix in $SUFFIXES; do
    python3 "$SCRIPT_DIR/defacing_qc.py" --suffix "$suffix"
done

echo ""
echo "=== Step 8: Generate QA gallery (HTML) ==="
SUFFIXES="$SUFFIXES" bash "$SCRIPT_DIR/generate_qa_gallery.sh"

echo ""
echo "============================================"
echo " Complete. $(date)"
echo " Outputs: /data/hans/BIDS_CND/"
echo "============================================"
