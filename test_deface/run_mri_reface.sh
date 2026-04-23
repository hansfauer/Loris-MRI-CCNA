#!/bin/bash
# Run mri_reface (Mayo Clinic / NITRC) via Docker on converted NIfTI T1w files
# Uses the official Docker wrapper script run_mri_reface_docker.sh
# See: https://www.nitrc.org/projects/mri_reface
#
# Prerequisites (once):
#   1. Docker installed with data-root on /data/hans/docker (ext4 loopback)
#   2. mri_reface 0.3.5 Docker zip downloaded from NITRC:
#        https://mri_reface.projects.nitrc.org/mri_reface_0.3.5_docker.zip
#      and extracted to:
#        /data/hans/mri_reface_docker/mri_reface_docker/
#   3. Docker image loaded:
#        cd /data/hans/mri_reface_docker/mri_reface_docker
#        docker load < mri_reface_docker_image
#      (image repository name: "mri_reface")
#
# Usage:
#   ./run_mri_reface.sh <CandID> [CandID2 ...]
#
# One-shot (any path, e.g. BIDS CT under RADcure):
#   REFACE_INPUT=/path/to/vol.nii.gz REFACE_OUTDIR=/path/to/outdir \
#     [REFACE_IMTYPE=CT] ./run_mri_reface.sh
#   REFACE_IMTYPE defaults to AUTO (wrapper infers from filename); use CT for CT volumes.

set -euo pipefail
source "$(dirname "$0")/setup_env.sh"

SRCBASE="/data/hans/BIDS_CND/sourcedata/nifti"
OUTBASE="/data/hans/BIDS_CND/derivatives/mri_reface"
DOCKER_WRAPPER="/data/hans/mri_reface_docker/mri_reface_docker/run_mri_reface_docker.sh"

SUFFIX="${SUFFIX:-T1w}"
case "$SUFFIX" in
    T1w|T2w|PDw|FLAIR) ;;
    *)
        echo "ERROR: Unsupported SUFFIX='$SUFFIX' (expected T1w|T2w|PDw|FLAIR)" >&2
        exit 1
        ;;
esac

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker command not found. Install docker.io and try again."
    exit 1
fi

if [ ! -x "$DOCKER_WRAPPER" ]; then
    echo "ERROR: Docker wrapper not found or not executable at $DOCKER_WRAPPER"
    echo "Ensure mri_reface_0.3.5_docker.zip is extracted under /data/hans/mri_reface_docker/."
    exit 1
fi

# Decompress if needed, run Docker refacer, gzip *_deFaced.nii -> <stem>_refaced.nii.gz in outdir.
reface_one_file() {
    local input=$1
    local outdir=$2
    local imtype=$3

    if [ ! -f "$input" ]; then
        echo "ERROR: Input not found: $input" >&2
        return 1
    fi

    outdir=$(readlink -f "$outdir")
    mkdir -p "$outdir"

    local tmpnii
    local cleanup_tmp=
    if [[ "$input" == *.nii.gz ]]; then
        local base
        base=$(basename "$input" .nii.gz)
        tmpnii="${outdir}/${base}.nii"
        gunzip -ck "$input" > "$tmpnii"
        cleanup_tmp=1
    elif [[ "$input" == *.nii ]]; then
        tmpnii=$(readlink -f "$input")
    else
        echo "ERROR: Input must be .nii or .nii.gz: $input" >&2
        return 1
    fi

    local basen
    basen=$(basename "$tmpnii" .nii)
    local output="${outdir}/${basen}_refaced.nii.gz"

    if [ -f "$output" ]; then
        echo "SKIP: ${output} already exists"
        [ -n "$cleanup_tmp" ] && rm -f "$tmpnii"
        return 0
    fi

    echo "Running mri_reface (Docker) for ${basen} (imType=${imtype})..."
    if command -v script >/dev/null 2>&1; then
        script -q -c "bash \"$DOCKER_WRAPPER\" \"$tmpnii\" \"$outdir\" -imType \"$imtype\" -saveQCRenders 1" /dev/null
    else
        bash "$DOCKER_WRAPPER" "$tmpnii" "$outdir" -imType "$imtype" -saveQCRenders 1
    fi

    [ -n "$cleanup_tmp" ] && rm -f "$tmpnii"

    local defaced_nii
    defaced_nii=$(find "$outdir" -maxdepth 1 -type f -name '*_deFaced.nii' 2>/dev/null | head -1 || true)
    if [ -n "${defaced_nii:-}" ]; then
        gzip -f "$defaced_nii"
        mv "${defaced_nii}.gz" "$output"
    fi

    if [ -f "$output" ]; then
        echo "OK reface (Docker): ${basen} -> ${output}"
        return 0
    fi
    echo "ERROR: mri_reface Docker did not produce a NIfTI output for ${basen}" >&2
    return 1
}

if [ -n "${REFACE_INPUT:-}" ]; then
    : "${REFACE_OUTDIR:?Set REFACE_OUTDIR when REFACE_INPUT is set}"
    input_abs=$(readlink -f "$REFACE_INPUT")
    reface_one_file "$input_abs" "$(readlink -f "$REFACE_OUTDIR")" "${REFACE_IMTYPE:-AUTO}"
    exit $?
fi

reface_subject() {
    local candid=$1
    local input="${SRCBASE}/sub-${candid}/ses-InitialMRI/anat/sub-${candid}_ses-InitialMRI_${SUFFIX}.nii.gz"

    if [ ! -f "$input" ]; then
        echo "WARN: No NIfTI for ${candid} (${SUFFIX}), run conversion first"
        return 1
    fi

    local imtype=""
    case "$SUFFIX" in
        T1w) imtype="T1" ;;
        T2w) imtype="T2" ;;
        PDw) imtype="PD" ;;
        FLAIR) imtype="FLAIR" ;;
    esac

    local outdir="${OUTBASE}/sub-${candid}/ses-InitialMRI/anat"
    local output="${outdir}/sub-${candid}_ses-InitialMRI_${SUFFIX}_refaced.nii.gz"

    if [ -f "$output" ]; then
        echo "SKIP: ${output} already exists"
        return 0
    fi

    mkdir -p "$outdir"

    # mri_reface requires uncompressed .nii (not .nii.gz).
    # Decompress to a temp file, run, then clean up.
    local tmpnii="${outdir}/sub-${candid}_ses-InitialMRI_${SUFFIX}.nii"
    gunzip -ck "$input" > "$tmpnii"

    echo "Running mri_reface (Docker) for sub-${candid}..."
    if command -v script >/dev/null 2>&1; then
        # The upstream wrapper uses `docker run -ti`, so provide a pseudo-TTY.
        script -q -c "bash \"$DOCKER_WRAPPER\" \"$tmpnii\" \"$outdir\" -imType \"$imtype\" -saveQCRenders 1" /dev/null
    else
        bash "$DOCKER_WRAPPER" "$tmpnii" "$outdir" -imType "$imtype" -saveQCRenders 1
    fi

    rm -f "$tmpnii"

    # mri_reface outputs *_deFaced.nii (uncompressed). Find it and gzip to BIDS name.
    local defaced_nii
    defaced_nii=$(find "$outdir" -maxdepth 1 -type f -name '*_deFaced.nii' 2>/dev/null | head -1 || true)
    if [ -n "${defaced_nii:-}" ]; then
        gzip -f "$defaced_nii"
        mv "${defaced_nii}.gz" "$output"
    fi

    if [ -f "$output" ]; then
        echo "OK reface (Docker): ${candid} -> ${output}"
    else
        echo "ERROR: mri_reface Docker did not produce a NIfTI output for ${candid}"
        return 1
    fi
}

for candid in "$@"; do
    reface_subject "$candid" || true
done
