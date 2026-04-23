#!/bin/bash
# run_mri_reface_ct.sh — Full-FOV CT defacing via crop → mri_reface → merge.
#
# Handles CT scans that include neck and shoulders by:
#   1. Auto-detecting the head/neck boundary (Hounsfield-unit bone-area analysis)
#   2. Cropping to a head-centered axial slab (~220 mm)
#   3. Running mri_reface (Docker) on the head crop only
#   4. Merging the refaced head back into the original full-FOV volume
#
# The neck/shoulder region in the output is bit-identical to the original.
#
# Usage:
#   ./run_mri_reface_ct.sh <input_ct.nii.gz> <output_dir>
# or:
#   CT_INPUT=/path/to/ct.nii.gz CT_OUTDIR=/path/to/outdir \
#     [CT_IMTYPE=CT] [CT_Z_TOP=<idx>] [CT_Z_CUT=<idx>] \
#     ./run_mri_reface_ct.sh
#
# Environment overrides:
#   CT_INPUT    — path to input CT NIfTI (.nii.gz or .nii)
#   CT_OUTDIR   — output directory
#   CT_IMTYPE   — mri_reface -imType flag (default: CT)
#   CT_Z_TOP    — override most-superior skull slice index (skips auto-detection)
#   CT_Z_CUT    — override first-slice-to-keep index (base of head crop)
#
# Outputs in <output_dir>:
#   <stem>_refaced.nii.gz          — full-FOV CT with face replaced
#   work/<stem>_headcrop.nii.gz    — intermediate head-only crop
#   work/<stem>_headcrop_refaced.nii.gz  — mri_reface output on the crop
#   work/<stem>_crop.json          — cut-slice sidecar
#   work/qc/                       — QC PNG renders from mri_reface
#
# Deterministic re-runs: if <stem>_refaced.nii.gz already exists, the script
# exits immediately.
#
# Prerequisites (same as run_mri_reface.sh):
#   - Docker with the "mri_reface" image loaded
#   - /data/hans/mri_reface_docker/mri_reface_docker/run_mri_reface_docker.sh
#   - setup_env.sh (FreeSurfer + MINC toolkit)
#   - Python 3 with nibabel and numpy (loris-mri-python conda env)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/setup_env.sh"

# ---------------------------------------------------------------------------
# Resolve input / output from positional args or env vars
# ---------------------------------------------------------------------------
if [ $# -ge 1 ]; then
    CT_INPUT="${1}"
fi
if [ $# -ge 2 ]; then
    CT_OUTDIR="${2}"
fi

: "${CT_INPUT:?CT_INPUT is required (set via argument or env var)}"
: "${CT_OUTDIR:?CT_OUTDIR is required (set via argument or env var)}"

CT_INPUT="$(readlink -f "${CT_INPUT}")"
CT_OUTDIR="$(readlink -f "${CT_OUTDIR}")"
CT_IMTYPE="${CT_IMTYPE:-CT}"

if [ ! -f "${CT_INPUT}" ]; then
    echo "ERROR: Input file not found: ${CT_INPUT}" >&2
    exit 1
fi

# Derive stem from input filename (strip .nii or .nii.gz)
stem="$(basename "${CT_INPUT}")"
stem="${stem%.nii.gz}"
stem="${stem%.nii}"

# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------
WORKDIR="${CT_OUTDIR}/work"
QCDIR="${WORKDIR}/qc"
mkdir -p "${WORKDIR}" "${QCDIR}"

# ---------------------------------------------------------------------------
# Final output — skip everything if already done
# ---------------------------------------------------------------------------
FINAL_OUT="${CT_OUTDIR}/${stem}_refaced.nii.gz"
if [ -f "${FINAL_OUT}" ]; then
    echo "SKIP: ${FINAL_OUT} already exists"
    exit 0
fi

HEADCROP="${WORKDIR}/${stem}_headcrop.nii.gz"
HEADCROP_SIDECAR="${WORKDIR}/${stem}_headcrop.json"
HEADCROP_REFACED="${WORKDIR}/${stem}_headcrop_refaced.nii.gz"

# ---------------------------------------------------------------------------
# Activate the Python environment that has nibabel / numpy
# ---------------------------------------------------------------------------
CONDA_ENV="loris-mri-python"
if command -v conda >/dev/null 2>&1; then
    eval "$(conda shell.bash hook 2>/dev/null || true)"
    conda activate "${CONDA_ENV}" 2>/dev/null || true
fi
# Fallback: try the expected conda base path
if ! python3 -c "import nibabel" 2>/dev/null; then
    CONDA_PREFIX="${CONDA_PREFIX:-/opt/conda}"
    if [ -f "${CONDA_PREFIX}/envs/${CONDA_ENV}/bin/python3" ]; then
        PYTHON3="${CONDA_PREFIX}/envs/${CONDA_ENV}/bin/python3"
    else
        echo "ERROR: nibabel not importable. Activate ${CONDA_ENV} conda env and retry." >&2
        exit 1
    fi
fi
PYTHON3="${PYTHON3:-python3}"

HELPER="${SCRIPT_DIR}/ct_head_crop_merge.py"

# ---------------------------------------------------------------------------
# Step 1: detect head/neck boundary and crop to head slab
# ---------------------------------------------------------------------------
if [ ! -f "${HEADCROP}" ] || [ ! -f "${HEADCROP_SIDECAR}" ]; then
    echo "==> Step 1: detecting head/neck boundary and cropping..."
    detect_args=()
    [ -n "${CT_Z_TOP:-}" ] && detect_args+=(--z-top "${CT_Z_TOP}")
    [ -n "${CT_Z_CUT:-}" ] && detect_args+=(--z-cut "${CT_Z_CUT}")
    "${PYTHON3}" "${HELPER}" detect-and-crop \
        "${CT_INPUT}" "${HEADCROP}" \
        "${detect_args[@]+"${detect_args[@]}"}"
else
    echo "==> Step 1: head crop already exists, skipping detect-and-crop."
fi

# ---------------------------------------------------------------------------
# Step 2: run mri_reface on the head crop
# ---------------------------------------------------------------------------
if [ ! -f "${HEADCROP_REFACED}" ]; then
    echo "==> Step 2: running mri_reface on head crop..."
    REFACE_INPUT="${HEADCROP}" \
    REFACE_OUTDIR="${WORKDIR}" \
    REFACE_IMTYPE="${CT_IMTYPE}" \
        "${SCRIPT_DIR}/run_mri_reface.sh"

    # mri_reface saves QC renders to REFACE_OUTDIR; move them to work/qc/
    # (run_mri_reface.sh names the output <stem>_refaced.nii.gz)
    refaced_candidate="${WORKDIR}/${stem}_headcrop_refaced.nii.gz"
    if [ ! -f "${refaced_candidate}" ]; then
        echo "ERROR: Expected mri_reface output not found: ${refaced_candidate}" >&2
        echo "Check the mri_reface Docker run for errors." >&2
        exit 1
    fi
    find "${WORKDIR}" -maxdepth 1 -name '*.png' -exec mv -t "${QCDIR}/" {} + 2>/dev/null || true
else
    echo "==> Step 2: refaced head crop already exists, skipping mri_reface."
fi

# ---------------------------------------------------------------------------
# Step 3: merge refaced head back into original full-FOV volume
# ---------------------------------------------------------------------------
echo "==> Step 3: merging refaced head back into full-FOV volume..."
"${PYTHON3}" "${HELPER}" merge \
    "${CT_INPUT}" \
    "${HEADCROP_REFACED}" \
    "${HEADCROP_SIDECAR}" \
    "${FINAL_OUT}"

echo ""
echo "==> Done: ${FINAL_OUT}"
echo "    QC renders: ${QCDIR}/"
