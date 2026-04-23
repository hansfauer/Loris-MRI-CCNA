#!/bin/bash
# Resample T1w SynthStrip brain masks into T2w/PDw/FLAIR voxel grids.
#
# This exists because SynthStrip masks are generated only for T1w, while
# downstream QC is run per modality.
#
# Usage: ./resample_masks.sh [CandID ...]
# If no CandIDs are given, uses the same default subjects as generate_brain_masks.sh.

set -euo pipefail
source "$(dirname "$0")/setup_env.sh"

SRCBASE="/data/hans/BIDS_CND/sourcedata/nifti"
MASKDIR="/data/hans/BIDS_CND/derivatives/brain_masks"
SESSION="ses-InitialMRI"

DEFAULT_SUBJECTS="100589 100659 100673 117632"
SUBJECTS="${*:-$DEFAULT_SUBJECTS}"

NON_T1_SUFFIXES="T2w PDw FLAIR"

python3 - "$SRCBASE" "$MASKDIR" "$SESSION" $SUBJECTS <<'PY'
import sys
from pathlib import Path

import numpy as np
import nibabel as nib
from nilearn.image import resample_to_img

SRCBASE = Path(sys.argv[1])
MASKDIR = Path(sys.argv[2])
SESSION = sys.argv[3]

suffixes = ["T2w", "PDw", "FLAIR"]

# remaining args: subject ids
subjs = sys.argv[4:]

def resample_mask(t1_mask_path: Path, target_img_path: Path, out_mask_path: Path) -> bool:
    if not t1_mask_path.exists() or not target_img_path.exists():
        return False

    t1_mask = nib.load(str(t1_mask_path))
    targ_img = nib.load(str(target_img_path))

    # nearest-neighbor keeps the mask binary during resampling
    resampled = resample_to_img(t1_mask, targ_img, interpolation="nearest")
    data = resampled.get_fdata()
    data = (data > 0.5).astype(np.uint8)
    out_img = nib.Nifti1Image(data, resampled.affine)

    out_mask_path.parent.mkdir(parents=True, exist_ok=True)
    out_img.to_filename(str(out_mask_path))
    return True

for sid in subjs:
    sid = sid.strip()
    t1_mask_path = (
        MASKDIR / f"sub-{sid}" / SESSION / "anat" /
        f"sub-{sid}_{SESSION}_T1w_brain-mask.nii.gz"
    )

    for suf in suffixes:
        target_img_path = (
            SRCBASE / f"sub-{sid}" / SESSION / "anat" /
            f"sub-{sid}_{SESSION}_{suf}.nii.gz"
        )
        out_mask_path = (
            MASKDIR / f"sub-{sid}" / SESSION / "anat" /
            f"sub-{sid}_{SESSION}_{suf}_brain-mask.nii.gz"
        )

        if out_mask_path.exists():
            continue

        ok = resample_mask(t1_mask_path, target_img_path, out_mask_path)
        if ok:
            print(f"OK: sub-{sid} {suf} brain-mask created")
        else:
            print(f"WARN: sub-{sid} {suf} mask not created (missing T1w mask or target image)")

PY

