#!/usr/bin/env python3
"""
defacing_qc.py  --  Quantitative QC for CCNA COMPASS-ND defacing evaluation.

Computes per-subject, per-algorithm:
  1. Brain Dice coefficient (original vs defaced, within SynthStrip brain mask)
  2. Brain voxel intensity correlation
  3. Face-region residual intensity ratio
  4. Orthogonal QC snapshots (original / defaced side-by-side)

Outputs (per modality when --suffix is used):
  - TSV summary : {DERIV}/defacing_qc_metrics.tsv (T1w) or
                   {DERIV}/defacing_qc_metrics_{suffix}.tsv (non-T1w)
  - PNG snapshots: {DERIV}/qc_snapshots/sub-{id}_{algorithm}_{suffix}_qc.png

Usage:
  python3 defacing_qc.py
"""

import argparse
import json
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import nibabel as nib
import numpy as np
import pandas as pd
from nilearn import plotting
from nilearn.image import resample_to_img
from scipy.ndimage import binary_dilation, binary_erosion, binary_fill_holes
from scipy.stats import pearsonr

# ═══════════════════════════════════════════════════════════════════════════════
# Section A:  Configuration and Path Resolution
# ═══════════════════════════════════════════════════════════════════════════════

SRCBASE = Path("/data/hans/BIDS_CND/sourcedata/nifti")
DERIV   = Path("/data/hans/BIDS_CND/derivatives")
QC_OUT  = DERIV / "qc_snapshots"

SUBJECTS = ["100589", "100659", "100673", "117632"]
SESSION  = "ses-InitialMRI"
SUFFIX   = "T1w"
MASK_SUFFIX = None  # if None, defaults to SUFFIX

ALGORITHMS = {
    "mri_deface": {
        "dir": "mri_deface",
        "filename": "sub-{sid}_{ses}_{suf}_deface-legacy.nii.gz",
    },
    "mideface": {
        "dir": "mideface",
        "filename": "sub-{sid}_{ses}_{suf}_defaced.nii.gz",
    },
    "mri_reface": {
        "dir": "mri_reface",
        "filename": "sub-{sid}_{ses}_{suf}_refaced.nii.gz",
    },
}

ALGO_MODALITY_SUPPORT = {
    "mri_deface": {"T1w", "T2w", "PDw", "FLAIR"},
    "mideface": {"T1w", "T2w", "PDw", "FLAIR"},
    # mri_reface wrapper supports T1/T2/PD/FLAIR imTypes.
    "mri_reface": {"T1w", "T2w", "PDw", "FLAIR"},
}


def get_original_path(sid: str) -> Path:
    """Return absolute path to the original (un-defaced) NIfTI for the current SUFFIX."""
    return (
        SRCBASE / f"sub-{sid}" / SESSION / "anat"
        / f"sub-{sid}_{SESSION}_{SUFFIX}.nii.gz"
    )


def get_defaced_path(sid: str, algo_key: str) -> Path:
    """Return the absolute path to the defaced NIfTI for a given algorithm."""
    algo = ALGORITHMS[algo_key]
    fname = algo["filename"].format(sid=sid, ses=SESSION, suf=SUFFIX)
    return DERIV / algo["dir"] / f"sub-{sid}" / SESSION / "anat" / fname


# ═══════════════════════════════════════════════════════════════════════════════
# Section B:  Scanner Metadata Loader
# ═══════════════════════════════════════════════════════════════════════════════

def load_json_sidecar(sid: str) -> dict:
    """Read the dcm2niix JSON sidecar and return scanner metadata."""
    json_path = (
        SRCBASE / f"sub-{sid}" / SESSION / "anat"
        / f"sub-{sid}_{SESSION}_{SUFFIX}.json"
    )
    if json_path.exists():
        with open(json_path) as fh:
            return json.load(fh)
    return {}


# ═══════════════════════════════════════════════════════════════════════════════
# Section C:  Brain Mask Loading
# ═══════════════════════════════════════════════════════════════════════════════

def _otsu_brain_mask(img_data: np.ndarray) -> np.ndarray:
    """Quick percentile-threshold fallback when SynthStrip masks are absent."""
    nonzero = img_data[img_data > 0]
    if len(nonzero) == 0:
        return np.zeros_like(img_data, dtype=bool)
    threshold = np.percentile(nonzero, 25)
    mask = img_data > threshold
    mask = binary_erosion(mask, iterations=2)
    mask = binary_dilation(mask, iterations=2)
    mask = binary_fill_holes(mask)
    return mask.astype(bool)


def load_brain_mask(sid: str, ref_data: np.ndarray) -> np.ndarray:
    """
    Load a pre-computed SynthStrip/resampled brain mask. If unavailable,
    fall back to a rough Otsu-threshold mask derived from ref_data.
    """
    mask_suf = MASK_SUFFIX or SUFFIX
    mask_path = (
        DERIV / "brain_masks" / f"sub-{sid}" / SESSION / "anat"
        / f"sub-{sid}_{SESSION}_{mask_suf}_brain-mask.nii.gz"
    )
    if mask_path.exists():
        mask_data = nib.load(str(mask_path)).get_fdata()
        return mask_data.astype(bool)

    print(f"  WARN: Brain mask not found for sub-{sid} ({mask_suf}), using Otsu fallback")
    return _otsu_brain_mask(ref_data)


# ═══════════════════════════════════════════════════════════════════════════════
# Section D:  Face Mask Estimation
# ═══════════════════════════════════════════════════════════════════════════════

def compute_face_mask(
    orig_data: np.ndarray, defaced_data: np.ndarray
) -> np.ndarray:
    """
    Estimate the face region as voxels that changed between original and
    defaced.  Works for both zeroing tools (mri_deface, mideface) and
    replacement tools (mri_reface).
    """
    diff = np.abs(orig_data.astype(np.float64) - defaced_data.astype(np.float64))
    nonzero_diff = diff[diff > 0]
    if len(nonzero_diff) == 0:
        return np.zeros_like(orig_data, dtype=bool)
    threshold = max(np.percentile(nonzero_diff, 10), 1.0)
    return diff > threshold


# ═══════════════════════════════════════════════════════════════════════════════
# Section E:  Core Metric Computation
# ═══════════════════════════════════════════════════════════════════════════════

def compute_metrics(sid: str, algo_key: str) -> dict:
    """
    Compute all QC metrics for one (subject, algorithm) pair.

    Returns a dict with: status, dice_brain, brain_corr,
    brain_voxels_lost_pct, face_residual_ratio, face_voxels_zeroed_pct,
    face_voxels_total.
    """
    orig_path   = get_original_path(sid)
    deface_path = get_defaced_path(sid, algo_key)

    nan_row = {
        "subject_id":            sid,
        "algorithm":             algo_key,
        "suffix":                SUFFIX,
        "status":                "MISSING",
        "dice_brain":            np.nan,
        "brain_corr":            np.nan,
        "brain_voxels_lost_pct": np.nan,
        "face_residual_ratio":   np.nan,
        "face_voxels_zeroed_pct": np.nan,
        "face_voxels_total":     np.nan,
    }

    if SUFFIX not in ALGO_MODALITY_SUPPORT.get(algo_key, set()):
        nan_row["status"] = "NOT_APPLICABLE"
        return nan_row

    if not orig_path.exists():
        nan_row["status"] = "NO_ORIGINAL"
        return nan_row
    if not deface_path.exists():
        nan_row["status"] = "FAILED"
        return nan_row

    # ── Load volumes ─────────────────────────────────────────────────────
    orig_img   = nib.load(str(orig_path))
    deface_img = nib.load(str(deface_path))
    orig_data  = orig_img.get_fdata(dtype=np.float64)

    if orig_img.shape != deface_img.shape:
        deface_img = resample_to_img(deface_img, orig_img, interpolation="nearest")

    deface_data = deface_img.get_fdata(dtype=np.float64)

    # ── Brain mask ───────────────────────────────────────────────────────
    brain_mask = load_brain_mask(sid, orig_data)

    # ── Dice coefficient ─────────────────────────────────────────────────
    orig_brain   = (orig_data > 0) & brain_mask
    deface_brain = (deface_data > 0) & brain_mask
    intersection = np.sum(orig_brain & deface_brain)
    dice = (2.0 * intersection) / (np.sum(orig_brain) + np.sum(deface_brain) + 1e-10)

    # ── Brain voxels lost ────────────────────────────────────────────────
    orig_brain_count = np.sum(orig_brain)
    lost = np.sum(orig_brain & ~deface_brain)
    lost_pct = 100.0 * lost / (orig_brain_count + 1e-10)

    # ── Brain intensity correlation ──────────────────────────────────────
    both_nonzero = brain_mask & (orig_data > 0) & (deface_data > 0)
    if np.sum(both_nonzero) > 100:
        r, _ = pearsonr(
            orig_data[both_nonzero].ravel(),
            deface_data[both_nonzero].ravel(),
        )
    else:
        r = np.nan

    # ── Face region analysis ─────────────────────────────────────────────
    face_mask = compute_face_mask(orig_data, deface_data)
    face_total = int(np.sum(face_mask))

    if face_total > 0:
        orig_face_mean   = np.mean(orig_data[face_mask])
        deface_face_mean = np.mean(deface_data[face_mask])
        face_residual    = deface_face_mean / (orig_face_mean + 1e-10)
        face_zeroed      = np.sum((deface_data[face_mask] == 0) & (orig_data[face_mask] > 0))
        face_zeroed_pct  = 100.0 * face_zeroed / face_total
    else:
        face_residual   = np.nan
        face_zeroed_pct = np.nan

    return {
        "subject_id":            sid,
        "algorithm":             algo_key,
        "suffix":                SUFFIX,
        "status":                "OK",
        "dice_brain":            round(float(dice), 6),
        "brain_corr":            round(float(r), 6) if not np.isnan(r) else np.nan,
        "brain_voxels_lost_pct": round(float(lost_pct), 4),
        "face_residual_ratio":   round(float(face_residual), 6),
        "face_voxels_zeroed_pct": round(float(face_zeroed_pct), 2),
        "face_voxels_total":     face_total,
    }


# ═══════════════════════════════════════════════════════════════════════════════
# Section F:  Mideface-Specific QA Parsers
# ═══════════════════════════════════════════════════════════════════════════════

def parse_mideface_stats(sid: str) -> dict:
    """Extract mideface's own QA stats (gmeanratio, nxmask) from stats.dat."""
    stats_path = (
        DERIV
        / "mideface"
        / f"sub-{sid}"
        / SESSION
        / "anat"
        / f"qa_{SUFFIX}"
        / "stats.dat"
    )
    if not stats_path.exists():
        return {}
    result = {}
    with open(stats_path) as fh:
        for line in fh:
            parts = line.strip().split()
            if len(parts) >= 2:
                result[parts[0]] = parts[1]
    return result


def parse_samseg_cost(sid: str) -> float:
    """
    Extract the samseg templateRegistration cost from cost.txt.
    More negative = better.  Values above -0.8 flag registration problems.
    """
    cost_path = (
        DERIV / "mideface" / f"sub-{sid}" / SESSION / "anat"
        / f"qa_{SUFFIX}" / "samseg" / "cost.txt"
    )
    if not cost_path.exists():
        return np.nan
    with open(cost_path) as fh:
        for line in fh:
            if line.startswith("templateRegistration"):
                return float(line.strip().split()[-1])
    return np.nan


# ═══════════════════════════════════════════════════════════════════════════════
# Section G:  QC Snapshot Generator
# ═══════════════════════════════════════════════════════════════════════════════

def generate_qc_snapshot(sid: str, algo_key: str, meta: dict) -> None:
    """
    Produce a 2-row x 3-column PNG: top row = original (sag/cor/ax),
    bottom row = defaced (sag/cor/ax).  Title shows scanner info.
    """
    orig_path   = get_original_path(sid)
    deface_path = get_defaced_path(sid, algo_key)
    if not orig_path.exists() or not deface_path.exists():
        return

    QC_OUT.mkdir(parents=True, exist_ok=True)
    out_png = QC_OUT / f"sub-{sid}_{algo_key}_{SUFFIX}_qc.png"

    orig_img   = nib.load(str(orig_path))
    deface_img = nib.load(str(deface_path))

    fig, axes = plt.subplots(2, 3, figsize=(18, 10))
    display_modes = ["x", "y", "z"]
    labels = {"x": "Sagittal", "y": "Coronal", "z": "Axial"}

    for col, dm in enumerate(display_modes):
        plotting.plot_anat(
            orig_img, display_mode=dm, cut_coords=1,
            axes=axes[0][col], annotate=True, draw_cross=False,
            title=f"Original  ({labels[dm]})",
        )
        plotting.plot_anat(
            deface_img, display_mode=dm, cut_coords=1,
            axes=axes[1][col], annotate=True, draw_cross=False,
            title=f"{algo_key}  ({labels[dm]})",
        )

    vendor = meta.get("Manufacturer", "?")
    model  = meta.get("ManufacturersModelName", "?")
    site   = meta.get("InstitutionName", "?")
    fig.suptitle(
        f"sub-{sid}  |  {algo_key}  |  {vendor} {model} @ {site}",
        fontsize=14, fontweight="bold",
    )
    fig.tight_layout(rect=[0, 0, 1, 0.96])
    fig.savefig(str(out_png), dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Snapshot: {out_png}")


# ═══════════════════════════════════════════════════════════════════════════════
# Section H:  Main Orchestration and Summary
# ═══════════════════════════════════════════════════════════════════════════════

def main() -> None:
    global SUFFIX
    global MASK_SUFFIX

    parser = argparse.ArgumentParser()
    parser.add_argument("--suffix", default="T1w", choices=["T1w", "T2w", "PDw", "FLAIR"])
    parser.add_argument(
        "--mask-suffix",
        default=None,
        choices=["T1w", "T2w", "PDw", "FLAIR"],
        help="Brain mask suffix to use (default: same as --suffix).",
    )
    args = parser.parse_args()

    SUFFIX = args.suffix
    MASK_SUFFIX = args.mask_suffix

    rows: list[dict] = []

    for sid in SUBJECTS:
        meta           = load_json_sidecar(sid)
        samseg_cost    = parse_samseg_cost(sid)
        mideface_stats = parse_mideface_stats(sid)

        for algo_key in ALGORITHMS:
            print(f"Processing sub-{sid} x {algo_key} ...")
            metrics = compute_metrics(sid, algo_key)

            # Attach scanner metadata
            metrics["manufacturer"]      = meta.get("Manufacturer", "")
            metrics["model"]             = meta.get("ManufacturersModelName", "")
            metrics["site"]              = meta.get("InstitutionName", "")
            metrics["series_description"] = meta.get("SeriesDescription", "")

            # Attach mideface-specific fields (blank for other algorithms)
            if algo_key == "mideface":
                metrics["samseg_cost"]        = samseg_cost
                metrics["mideface_gmeanratio"] = mideface_stats.get("gmeanratio", "")
                metrics["mideface_nxmask"]    = mideface_stats.get("nxmask", "")
            else:
                metrics["samseg_cost"]        = ""
                metrics["mideface_gmeanratio"] = ""
                metrics["mideface_nxmask"]    = ""

            rows.append(metrics)

            if metrics["status"] == "OK":
                generate_qc_snapshot(sid, algo_key, meta)

    # ── Write TSV ────────────────────────────────────────────────────────
    df = pd.DataFrame(rows)
    if SUFFIX == "T1w":
        tsv_path = DERIV / "defacing_qc_metrics.tsv"
    else:
        tsv_path = DERIV / f"defacing_qc_metrics_{SUFFIX}.tsv"
    df.to_csv(str(tsv_path), sep="\t", index=False)
    print(f"\nQC metrics written to: {tsv_path}")
    print(df.to_string(index=False))

    # ── Summary flags ────────────────────────────────────────────────────
    print("\n── QC Flags ──")
    any_flags = False
    for _, row in df.iterrows():
        flags = []
        if row["status"] == "FAILED":
            flags.append("ALGORITHM_FAILED")
        dice = row.get("dice_brain", np.nan)
        if not pd.isna(dice) and dice < 0.99:
            flags.append(f"LOW_DICE={dice:.4f}")
        lost = row.get("brain_voxels_lost_pct", 0.0)
        if not pd.isna(lost) and lost > 0.5:
            flags.append(f"BRAIN_LOSS={lost:.2f}%")
        cost = row.get("samseg_cost", "")
        if cost != "" and not pd.isna(cost) and float(cost) > -0.8:
            flags.append(f"BAD_REGISTRATION(cost={float(cost):.3f})")
        if flags:
            any_flags = True
            print(f"  sub-{row['subject_id']} x {row['algorithm']}: {', '.join(flags)}")

    if not any_flags:
        print("  (none)")


if __name__ == "__main__":
    main()
