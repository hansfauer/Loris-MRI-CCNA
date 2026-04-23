#!/usr/bin/env python3
"""
Pick the correct NIfTI from a dual PD/T2 (dual-echo) sequence using EchoTime from
dcm2niix JSON sidecars.

Convention (typical Siemens-style PD/T2 FSE):
  - Shorter TE → PD-weighted (PDw)
  - Longer TE  → T2-weighted (T2w)

Exits:
  0  stdout = path to chosen .nii.gz
  2  no suitable dual-echo candidates (caller should use basename-only logic)
  1  error
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


# Basenames that look like combined PD+T2 dual-echo (dcm2niix often names e.g. 701_PD_T2_FS_e1).
DUAL_PD_T2_RE = re.compile(
    r"PD[_ ]?T2|T2[_ ]?PD|P[_ ]?T2[_ ]?FS|PDT2",
    re.IGNORECASE,
)


def load_echo_time_sec(json_path: Path) -> float | None:
    if not json_path.is_file():
        return None
    try:
        with json_path.open() as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None

    # dcm2niix / BIDS-style: EchoTime in seconds; some exports use ms as a plain number.
    raw = data.get("EchoTime")
    if raw is None:
        return None
    try:
        v = float(raw)
    except (TypeError, ValueError):
        return None

    # Heuristic: values >> 0.5 are almost certainly milliseconds (e.g. 8.9, 89).
    if v > 0.5:
        return v / 1000.0
    return v


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("staging", type=Path, help="dcm2niix output directory")
    ap.add_argument(
        "suffix",
        choices=("PDw", "T2w"),
        help="Which contrast to select within the dual-echo pair",
    )
    args = ap.parse_args()
    staging: Path = args.staging
    if not staging.is_dir():
        print("staging not a directory", file=sys.stderr)
        return 1

    dual_niis: list[Path] = [
        n
        for n in sorted(staging.glob("*.nii.gz"))
        if DUAL_PD_T2_RE.search(n.name[: -len(".nii.gz")])
    ]
    if len(dual_niis) < 2:
        return 2

    # Prefer EchoTime from JSON (seconds or ms → normalized).
    with_te: list[tuple[float, Path]] = []
    for nii in dual_niis:
        stem = nii.name[: -len(".nii.gz")]
        te = load_echo_time_sec(staging / f"{stem}.json")
        if te is not None:
            with_te.append((te, nii))

    if len(with_te) >= 2:
        if args.suffix == "PDw":
            chosen = min(with_te, key=lambda x: x[0])[1]
        else:
            chosen = max(with_te, key=lambda x: x[0])[1]
        print(chosen.resolve())
        return 0

    # Fallback: dual-echo series often named ..._e1 / ..._e2 with shorter TE first (PD-like).
    echo_idx: list[tuple[int, Path]] = []
    for nii in dual_niis:
        stem = nii.name[: -len(".nii.gz")]
        m = re.search(r"_e(\d+)$", stem, re.IGNORECASE)
        if m:
            echo_idx.append((int(m.group(1)), nii))

    if len(echo_idx) >= 2:
        if args.suffix == "PDw":
            chosen = min(echo_idx, key=lambda x: x[0])[1]
        else:
            chosen = max(echo_idx, key=lambda x: x[0])[1]
        print(chosen.resolve())
        return 0

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
