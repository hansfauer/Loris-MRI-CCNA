#!/usr/bin/env python3
"""Find and remove DICOMDIR files under the tarchive release directory."""

import argparse
import os
import re
import sys
from pathlib import Path

DEFAULT_ROOT = "/data/not_backed_up/tarchive_release"
PATIENT_RE = re.compile(r"^([A-Za-z]{2,}\d{3,})")


def patient_id_from_path(path: Path, root: Path) -> str:
    for part in path.relative_to(root).parts[:-1]:
        if part.startswith(("DCM_", "ImagingUpload")):
            continue
        m = PATIENT_RE.match(part)
        if m:
            return m.group(1)
    return patient_id_from_dicomdir(path)


def patient_id_from_dicomdir(path: Path) -> str:
    try:
        import pydicom
        ds = pydicom.dcmread(str(path), stop_before_pixels=True)
        for rec in ds.get("DirectoryRecordSequence", []):
            if rec.get("DirectoryRecordType") == "PATIENT":
                m = PATIENT_RE.match(str(rec.get("PatientID", "")))
                if m:
                    return m.group(1)
    except Exception:
        pass
    return "UNKNOWN"


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root", default=DEFAULT_ROOT, help=f"Directory to search (default: {DEFAULT_ROOT})")
    p.add_argument("-n", "--dry-run", action="store_true", help="List files without deleting them")
    args = p.parse_args()

    root = Path(args.root).resolve()
    if not root.is_dir():
        sys.exit(f"Error: {root} is not a directory")

    found = []
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            if name.upper() == "DICOMDIR":
                found.append(Path(dirpath) / name)
    found.sort()

    # Resolve IDs before deleting, since the DICOMDIR fallback needs the file.
    ids = {path: patient_id_from_path(path, root) for path in found}

    removed = failed = 0
    for path in found:
        pid = ids[path]
        if args.dry_run:
            print(f"[DRY RUN] {pid}\t{path}")
            continue
        try:
            path.unlink()
            removed += 1
            print(f"[REMOVED] {pid}\t{path}")
        except OSError as e:
            failed += 1
            print(f"[FAILED]  {pid}\t{path}\t{e}", file=sys.stderr)

    patients = sorted(set(ids.values()))
    print()
    print(f"DICOMDIR files found: {len(found)}")
    print(f"Patients affected:    {len(patients)}")
    if args.dry_run:
        print("Dry run: no files were removed.")
    else:
        print(f"Removed: {removed}  Failed: {failed}")
    if patients:
        print("Patient IDs: " + ", ".join(patients))

    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
