#!/usr/bin/env python3
"""
ct_head_crop_merge.py — Axial crop/merge helper for CT defacing pipeline.

Subcommands
-----------
detect-and-crop  <input.nii.gz> <head_crop.nii.gz>
    Detect the head/neck boundary via per-slice bone-area analysis,
    crop axially to the head-only slab, save crop + JSON sidecar.

merge  <original.nii.gz> <refaced_crop.nii.gz> <sidecar.json> <output.nii.gz>
    Overwrite the head z-range in the original full-FOV array with the
    refaced voxels; geometry (dims, affine, header) is identical to original.

Usage
-----
    python ct_head_crop_merge.py detect-and-crop in.nii.gz out_crop.nii.gz
    python ct_head_crop_merge.py merge original.nii.gz refaced_crop.nii.gz sidecar.json out.nii.gz

Design notes
------------
- Orientation-aware: never hard-codes axis=2. Determines the S/I axis from
  nibabel.aff2axcodes(affine).
- dtype-safe: output NIfTI shares the original's data dtype and header.
- scl_slope / scl_inter: if present these are preserved verbatim; data is
  always handled as loaded (after nibabel applies any slope/inter).
- Merge sanity: asserts the refaced crop shape matches the recorded slab.
"""

import argparse
import json
import sys
from pathlib import Path

import nibabel as nib
import numpy as np


# ---------------------------------------------------------------------------
# Orientation helpers
# ---------------------------------------------------------------------------

def _superior_axis(img: nib.Nifti1Image) -> tuple[int, int]:
    """Return (axis_index, step_sign) for the superior direction.

    step_sign = +1  → increasing index moves more superior
    step_sign = -1  → decreasing index moves more superior
    """
    codes = nib.aff2axcodes(img.affine)  # e.g. ('L', 'A', 'S') or ('R', 'P', 'I')
    for ax, code in enumerate(codes):
        if code == 'S':
            return ax, +1
        if code == 'I':
            return ax, -1
    raise RuntimeError(f"Cannot find S/I axis in affine axis codes {codes}")


# ---------------------------------------------------------------------------
# detect-and-crop
# ---------------------------------------------------------------------------

# Bone HU threshold — cortical + trabecular overlap; shoulders have no skull.
_BONE_HU_THRESHOLD = 200
# Minimum bone pixels in a slice to count as "skull present".
_BONE_AREA_MIN_VOXELS = 200
# Target slab height in mm (vertex to well below chin).
_HEAD_HEIGHT_MM = 220
# Minimum expected number of slices in a head crop (sanity check).
_MIN_HEAD_SLICES = 60


def _detect_head_slab(img: nib.Nifti1Image) -> tuple[int, int, int, float]:
    """Return (sup_axis, z_top, z_cut, slice_thickness_mm).

    z_top  = most-superior array-index that belongs to the skull
    z_cut  = first array-index to keep (base of slab, neck/shoulder boundary)

    Both indices are expressed in the sense that slices[z_cut : z_top + 1]
    is the head slab along sup_axis.
    """
    sup_axis, step_sign = _superior_axis(img)
    # get_fdata is nibabel's optimised path: decompresses once, applies
    # slope/intercept, and returns a writeable float64 array.
    data = img.get_fdata(dtype=np.float32)

    zooms = img.header.get_zooms()
    slice_thickness = float(zooms[sup_axis])

    n_slices = data.shape[sup_axis]

    # bone_counts[i] = number of voxels with HU > threshold in slice i
    # Vectorised: sum over all axes except sup_axis in one pass.
    other_axes = tuple(ax for ax in range(data.ndim) if ax != sup_axis)
    bone_counts = (data > _BONE_HU_THRESHOLD).sum(axis=other_axes)  # shape (n_slices,)

    # Identify skull-containing slices
    has_skull = bone_counts >= _BONE_AREA_MIN_VOXELS

    if not has_skull.any():
        raise RuntimeError(
            "No skull-containing slices found (bone area never reached "
            f"{_BONE_AREA_MIN_VOXELS} voxels above {_BONE_HU_THRESHOLD} HU). "
            "Check that the input is a CT scan with HU values."
        )

    # Find the most-superior skull slice
    skull_indices = np.where(has_skull)[0]

    if step_sign == +1:
        # increasing index → more superior: z_top is the max skull index
        z_top = int(skull_indices.max())
    else:
        # increasing index → more inferior: z_top is the min skull index
        z_top = int(skull_indices.min())

    head_slices = int(round(_HEAD_HEIGHT_MM / slice_thickness))

    if step_sign == +1:
        z_cut = max(0, z_top - head_slices)
    else:
        # inferior-to-superior storage: z_top is a small index; slab extends
        # upward in index space
        z_cut = min(n_slices - 1, z_top + head_slices)

    n_head = abs(z_top - z_cut) + 1
    if n_head < _MIN_HEAD_SLICES:
        raise RuntimeError(
            f"Head slab only {n_head} slices ({n_head * slice_thickness:.0f} mm). "
            "Expected at least 60. Inspect the scan and run with --z-cut / --z-top overrides."
        )

    print(
        f"[detect] sup_axis={sup_axis} step_sign={step_sign:+d} "
        f"slice_thickness={slice_thickness} mm  "
        f"z_top={z_top}  z_cut={z_cut}  slab={n_head} slices "
        f"({n_head * slice_thickness:.0f} mm)",
        flush=True,
    )
    return sup_axis, z_top, z_cut, slice_thickness


def _crop_image(
    img: nib.Nifti1Image,
    sup_axis: int,
    step_sign: int,
    z_cut: int,
    z_top: int,
) -> nib.Nifti1Image:
    """Return a new NIfTI image containing only the head slab."""
    data = np.asarray(img.dataobj)

    # Build slicing tuple — take slices [lo : hi+1] along sup_axis
    if step_sign == +1:
        lo, hi = z_cut, z_top + 1          # hi is exclusive
    else:
        lo, hi = z_top, z_cut + 1

    idx: list = [slice(None)] * data.ndim
    idx[sup_axis] = slice(lo, hi)
    crop_data = data[tuple(idx)].copy()

    # Shift affine origin so that voxel [0,0,0] of crop maps to the same
    # world coordinate as voxel [lo,lo,lo,...,lo] in the original.
    new_affine = img.affine.copy()
    shift_indices = [0] * data.ndim
    shift_indices[sup_axis] = lo
    world_shift = img.affine[:3, :3] @ np.array(shift_indices[:3], dtype=float)
    new_affine[:3, 3] = img.affine[:3, 3] + world_shift

    new_header = img.header.copy()
    new_header.set_data_shape(crop_data.shape)
    new_header.set_sform(new_affine, code=int(img.header.get('sform_code')))
    new_header.set_qform(new_affine, code=int(img.header.get('qform_code')))

    return nib.Nifti1Image(crop_data, new_affine, new_header)


def cmd_detect_and_crop(args: argparse.Namespace) -> None:
    input_path = Path(args.input)
    crop_path = Path(args.crop_output)
    sidecar_path = crop_path.with_suffix("").with_suffix(".json")
    if crop_path.suffix == ".gz":
        sidecar_path = Path(str(crop_path).replace(".nii.gz", ".json"))

    # Override slice indices if supplied on CLI
    img = nib.load(str(input_path))
    sup_axis, step_sign = _superior_axis(img)

    if args.z_top is not None or args.z_cut is not None:
        zooms = img.header.get_zooms()
        slice_thickness = float(zooms[sup_axis])
        z_top = int(args.z_top) if args.z_top is not None else _auto_z_top(img, sup_axis, step_sign)
        z_cut_default = max(0, z_top - int(round(_HEAD_HEIGHT_MM / slice_thickness))) if step_sign == +1 else \
                        min(img.shape[sup_axis] - 1, z_top + int(round(_HEAD_HEIGHT_MM / slice_thickness)))
        z_cut = int(args.z_cut) if args.z_cut is not None else z_cut_default
        n_head = abs(z_top - z_cut) + 1
        print(
            f"[detect] Manual override: sup_axis={sup_axis} step_sign={step_sign:+d} "
            f"z_top={z_top}  z_cut={z_cut}  slab={n_head}",
            flush=True,
        )
    else:
        sup_axis, z_top, z_cut, _ = _detect_head_slab(img)
        step_sign = _superior_axis(img)[1]

    crop_img = _crop_image(img, sup_axis, step_sign, z_cut, z_top)

    crop_path.parent.mkdir(parents=True, exist_ok=True)
    nib.save(crop_img, str(crop_path))
    print(f"[crop] saved → {crop_path}", flush=True)

    lo = z_cut if step_sign == +1 else z_top
    hi = z_top if step_sign == +1 else z_cut

    sidecar = {
        "input": str(input_path.resolve()),
        "sup_axis": sup_axis,
        "step_sign": step_sign,
        "z_cut": z_cut,
        "z_top": z_top,
        "slice_lo": lo,
        "slice_hi": hi,
        "n_slices_crop": int(crop_img.shape[sup_axis]),
        "input_shape": list(img.shape),
        "crop_shape": list(crop_img.shape),
    }
    sidecar_path.write_text(json.dumps(sidecar, indent=2))
    print(f"[crop] sidecar → {sidecar_path}", flush=True)


# ---------------------------------------------------------------------------
# merge
# ---------------------------------------------------------------------------

def cmd_merge(args: argparse.Namespace) -> None:
    orig_path = Path(args.original)
    refaced_path = Path(args.refaced_crop)
    sidecar_path = Path(args.sidecar)
    out_path = Path(args.output)

    sidecar = json.loads(sidecar_path.read_text())
    sup_axis: int = sidecar["sup_axis"]
    slice_lo: int = sidecar["slice_lo"]
    slice_hi: int = sidecar["slice_hi"]
    n_slices_crop: int = sidecar["n_slices_crop"]
    orig_shape: list = sidecar["input_shape"]

    orig_img = nib.load(str(orig_path))
    refaced_img = nib.load(str(refaced_path))

    if list(orig_img.shape) != orig_shape:
        raise RuntimeError(
            f"Original shape {orig_img.shape} does not match sidecar {orig_shape}. "
            "Wrong original file?"
        )

    if refaced_img.shape[sup_axis] != n_slices_crop:
        raise RuntimeError(
            f"Refaced crop has {refaced_img.shape[sup_axis]} slices along axis {sup_axis} "
            f"but sidecar expected {n_slices_crop}. "
            "mri_reface may have changed dimensions — cannot safely merge."
        )

    expected_crop_shape = list(orig_shape)
    expected_crop_shape[sup_axis] = n_slices_crop
    if list(refaced_img.shape) != expected_crop_shape:
        raise RuntimeError(
            f"Refaced crop shape {refaced_img.shape} does not match expected {expected_crop_shape}."
        )

    orig_data = np.array(orig_img.dataobj).copy()
    refaced_data = np.asarray(refaced_img.dataobj)

    # Overwrite the head slab in the original array
    idx: list = [slice(None)] * orig_data.ndim
    idx[sup_axis] = slice(slice_lo, slice_hi + 1)
    orig_data[tuple(idx)] = refaced_data

    # Save with the original image's header and affine (geometry unchanged)
    out_img = nib.Nifti1Image(orig_data, orig_img.affine, orig_img.header.copy())
    out_path.parent.mkdir(parents=True, exist_ok=True)
    nib.save(out_img, str(out_path))
    print(f"[merge] saved → {out_path}", flush=True)

    # Sanity check: verify neck/shoulder slices are bit-identical to original
    neck_idx: list = [slice(None)] * orig_data.ndim
    neck_idx[sup_axis] = slice(0, slice_lo)
    orig_check = np.asarray(orig_img.dataobj)[tuple(neck_idx)]
    merged_check = np.asarray(nib.load(str(out_path)).dataobj)[tuple(neck_idx)]
    if not np.array_equal(orig_check, merged_check):
        print(
            "WARNING: neck/shoulder region is NOT bit-identical to the original. "
            "This is unexpected — check for dtype conversion issues.",
            file=sys.stderr,
        )
    else:
        print(
            f"[merge] neck/shoulder region (slices 0–{slice_lo - 1}) "
            "is bit-identical to original. OK",
            flush=True,
        )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Axial crop/merge helper for the CT defacing pipeline.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # detect-and-crop
    p_crop = sub.add_parser(
        "detect-and-crop",
        help="Auto-detect head/neck boundary and save head-only crop + JSON sidecar.",
    )
    p_crop.add_argument("input", help="Input full-FOV CT (.nii or .nii.gz)")
    p_crop.add_argument("crop_output", help="Output head crop (.nii.gz)")
    p_crop.add_argument(
        "--z-top", type=int, default=None,
        help="Override: most-superior slice index of skull (skips auto-detection).",
    )
    p_crop.add_argument(
        "--z-cut", type=int, default=None,
        help="Override: first slice to keep (base of head crop).",
    )

    # merge
    p_merge = sub.add_parser(
        "merge",
        help="Overwrite head-slab slices in original with refaced crop.",
    )
    p_merge.add_argument("original",     help="Original full-FOV CT (.nii.gz)")
    p_merge.add_argument("refaced_crop", help="mri_reface output on the head crop (.nii.gz)")
    p_merge.add_argument("sidecar",      help="JSON sidecar produced by detect-and-crop")
    p_merge.add_argument("output",       help="Output full-FOV refaced CT (.nii.gz)")

    args = parser.parse_args()
    if args.command == "detect-and-crop":
        cmd_detect_and_crop(args)
    elif args.command == "merge":
        cmd_merge(args)


if __name__ == "__main__":
    main()
