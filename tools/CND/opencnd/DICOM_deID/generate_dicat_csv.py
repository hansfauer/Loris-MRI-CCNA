#!/usr/bin/env python3
"""
generate_dicat_csv.py

Build a headerless CSV for DICAT mass de-identification from untarred DICOM
archives produced by untar_tarchives_from_pscid_list.pl.

Each output row (no header) is:

    <DICOM_DIR>,<new_PatientName>,<new_PatientID>,<PatientBirthDate>,<DateAcquired>

where:
  - DICOM_DIR         : path to the untarred DICOM study directory
  - new_PatientName   : open_PSCID_open_CandID_<Visit_label>
  - new_PatientID     : open_PSCID
  - PatientBirthDate  : original DoB truncated to MM/YYYY
  - DateAcquired      : acquisition date truncated to MM/YYYY

Intended use with DICAT and fields_to_zap_for_open_science XML, e.g.:

    python mass_deidentify.py \\
      -c dicat_batch.csv \\
      -x fields_to_zap_for_open_science.xml

Note: stock DICAT mass_deidentify currently maps CSV columns as
DCM_DIR, PatientName, DOB, Sex. This script writes the five columns above
(PatientID + DateAcquired included) so you can extend DICAT / the zap XML
to apply those editable fields.

Usage:
    ./generate_dicat_csv.py \\
        --untar-dir /path/to/extracted_tarchives \\
        [--open-ids openIDs_CND.csv] \\
        [--output dicat_batch.csv] \\
        [--profile database_config] \\
        [--summary untar_tarchives_summary.tsv]
"""

from __future__ import annotations

import argparse
import csv
import importlib.util
import os
import re
import sys
from datetime import datetime
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_OPEN_IDS = SCRIPT_DIR / "openIDs_CND.csv"
DEFAULT_SUMMARY_NAME = "untar_tarchives_summary.tsv"


def parse_args():
    p = argparse.ArgumentParser(
        description=(
            "Generate a headerless DICAT CSV from untarred DICOM archives "
            "and open ID mappings."
        )
    )
    p.add_argument(
        "--untar-dir",
        required=True,
        help="Root directory produced by untar_tarchives_from_pscid_list.pl",
    )
    p.add_argument(
        "--open-ids",
        default=str(DEFAULT_OPEN_IDS),
        help=f"CSV mapping current->open IDs (default: {DEFAULT_OPEN_IDS})",
    )
    p.add_argument(
        "--output",
        default=None,
        help="Output CSV path (default: <untar-dir>/dicat_batch.csv)",
    )
    p.add_argument(
        "--summary",
        default=None,
        help=(
            "Path to untar_tarchives_summary.tsv "
            f"(default: <untar-dir>/{DEFAULT_SUMMARY_NAME})"
        ),
    )
    p.add_argument(
        "--profile",
        default=None,
        help=(
            "Python DB config in $LORIS_CONFIG/.loris_mri "
            "(e.g. database_config). If set, DoB is read from candidate.DoB; "
            "otherwise DoB is read from the first DICOM file."
        ),
    )
    p.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Print progress to stderr",
    )
    return p.parse_args()


def load_open_ids(path: str) -> dict[str, tuple[str, str]]:
    """Return {current_PSCID: (open_PSCID, open_CandID)}."""
    mapping: dict[str, tuple[str, str]] = {}
    with open(path, newline="") as fh:
        reader = csv.DictReader(fh)
        if not reader.fieldnames:
            sys.exit(f"ERROR: empty open-ids CSV: {path}")

        lowered = {h.lower().strip(): h for h in reader.fieldnames if h}
        cur_pscid = lowered.get("current_pscid") or lowered.get("pscid")
        open_pscid = lowered.get("open_pscid")
        open_candid = lowered.get("open_candid")
        if not cur_pscid or not open_pscid or not open_candid:
            sys.exit(
                "ERROR: open-ids CSV must contain current_PSCID, open_PSCID, "
                f"open_CandID (found: {reader.fieldnames})"
            )

        for row in reader:
            pscid = (row.get(cur_pscid) or "").strip()
            ops = (row.get(open_pscid) or "").strip()
            ocand = (row.get(open_candid) or "").strip()
            if not pscid or not ops or not ocand:
                continue
            mapping[pscid] = (ops, ocand)

    if not mapping:
        sys.exit(f"ERROR: no open ID mappings found in {path}")
    return mapping


def load_summary(path: str) -> list[dict[str, str]]:
    with open(path, newline="") as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        if not reader.fieldnames:
            sys.exit(f"ERROR: empty summary TSV: {path}")
        rows = [dict(row) for row in reader]
    return rows


def to_mm_yyyy(value: str | None) -> str:
    """Convert common date strings to MM/YYYY; return '' if unparseable."""
    if value is None:
        return ""
    s = str(value).strip()
    if not s or s.lower() in {"none", "null", "0000-00-00", "00000000"}:
        return ""

    # Already MM/YYYY
    m = re.fullmatch(r"(\d{1,2})/(\d{4})", s)
    if m:
        return f"{int(m.group(1)):02d}/{m.group(2)}"

    candidates = [
        "%Y-%m-%d",
        "%Y/%m/%d",
        "%Y%m%d",
        "%Y-%m-%d %H:%M:%S",
        "%d/%m/%Y",
        "%m/%d/%Y",
    ]
    # Truncate time if present without matching full datetime formats
    date_part = s.split()[0]
    for fmt in candidates:
        try:
            dt = datetime.strptime(date_part if "%H" not in fmt else s, fmt)
            return f"{dt.month:02d}/{dt.year}"
        except ValueError:
            continue

    # YYYY-MM or YYYY/MM
    m = re.fullmatch(r"(\d{4})[-/](\d{1,2})", s)
    if m:
        return f"{int(m.group(2)):02d}/{m.group(1)}"

    return ""


def is_dicom_file(path: Path) -> bool:
    try:
        with path.open("rb") as fh:
            fh.seek(128)
            return fh.read(4) == b"DICM"
    except OSError:
        return False


def find_dicom_dir(extract_dir: Path, inner_tar: str) -> Path | None:
    """Locate the inner DICOM study directory under an extract folder."""
    if not extract_dir.is_dir():
        return None

    if inner_tar:
        stem = re.sub(r"\.tar\.gz$", "", inner_tar, flags=re.IGNORECASE)
        candidate = extract_dir / stem
        if candidate.is_dir():
            return candidate.resolve()

    # Fallback: first subdirectory that contains at least one DICOM file
    for root, _dirs, files in os.walk(extract_dir):
        root_path = Path(root)
        if root_path == extract_dir:
            # Prefer nested study dirs over loose files next to .meta/.log
            continue
        for name in files:
            if is_dicom_file(root_path / name):
                return root_path.resolve()

    # Last resort: DICOM files directly in extract_dir
    for name in os.listdir(extract_dir):
        p = extract_dir / name
        if p.is_file() and is_dicom_file(p):
            return extract_dir.resolve()

    return None


def connect_db(profile_name: str):
    """Load $LORIS_CONFIG/.loris_mri/<profile>.py and return a Database."""
    if "LORIS_CONFIG" not in os.environ:
        sys.exit("ERROR: LORIS_CONFIG is not set")

    profile_path = (
        Path(os.environ["LORIS_CONFIG"]) / ".loris_mri" / profile_name
    )
    if not profile_path.is_file():
        # allow omitting .py
        if not profile_name.endswith(".py"):
            profile_path = Path(str(profile_path) + ".py")
    if not profile_path.is_file():
        sys.exit(f"ERROR: profile not found: {profile_path}")

    # Ensure LORIS-MRI python libs are importable
    mri_python = Path(__file__).resolve().parents[3] / "python"
    if str(mri_python) not in sys.path:
        sys.path.insert(0, str(mri_python))

    spec = importlib.util.spec_from_file_location("loris_profile", profile_path)
    if spec is None or spec.loader is None:
        sys.exit(f"ERROR: cannot load profile: {profile_path}")
    config = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(config)

    if not hasattr(config, "mysql"):
        sys.exit(f"ERROR: no mysql credentials in {profile_path}")

    from lib.database import Database

    db = Database(config.mysql, False)
    db.connect()
    return db


def load_dobs_from_db(db, pscids: list[str]) -> dict[str, str]:
    """Return {PSCID: DoB} for the requested PSCIDs."""
    if not pscids:
        return {}
    placeholders = ",".join(["%s"] * len(pscids))
    query = (
        f"SELECT PSCID, DoB FROM candidate WHERE PSCID IN ({placeholders})"
    )
    rows = db.pselect(query, tuple(pscids))
    out: dict[str, str] = {}
    for row in rows:
        pscid = str(row.get("PSCID") or "").strip()
        dob = row.get("DoB")
        if pscid:
            out[pscid] = "" if dob is None else str(dob)
    return out


def read_dob_from_dicom(dicom_dir: Path) -> str:
    """Read PatientBirthDate from the first DICOM in dicom_dir."""
    try:
        import pydicom
    except ImportError:
        return ""

    for root, _dirs, files in os.walk(dicom_dir):
        for name in files:
            path = Path(root) / name
            if not is_dicom_file(path):
                continue
            try:
                ds = pydicom.dcmread(str(path), stop_before_pixels=True)
                return str(getattr(ds, "PatientBirthDate", "") or "")
            except Exception:
                continue
    return ""


def usable_summary_row(row: dict[str, str]) -> bool:
    status = (row.get("Status") or "").strip()
    return status in {"EXTRACTED", "SKIPPED_DEST_EXISTS"}


def main():
    args = parse_args()
    untar_dir = Path(args.untar_dir).resolve()
    if not untar_dir.is_dir():
        sys.exit(f"ERROR: untar dir not found: {untar_dir}")

    summary_path = Path(args.summary) if args.summary else untar_dir / DEFAULT_SUMMARY_NAME
    if not summary_path.is_file():
        sys.exit(
            f"ERROR: summary TSV not found: {summary_path}\n"
            "Run untar_tarchives_from_pscid_list.pl first, or pass --summary."
        )

    open_ids_path = Path(args.open_ids)
    if not open_ids_path.is_file():
        sys.exit(f"ERROR: open-ids CSV not found: {open_ids_path}")

    out_path = (
        Path(args.output).resolve()
        if args.output
        else untar_dir / "dicat_batch.csv"
    )

    open_map = load_open_ids(str(open_ids_path))
    summary_rows = load_summary(str(summary_path))
    usable = [r for r in summary_rows if usable_summary_row(r)]

    if args.verbose:
        print(
            f"Loaded {len(open_map)} open ID mappings; "
            f"{len(usable)} usable summary rows from {summary_path}",
            file=sys.stderr,
        )

    pscids = sorted(
        {
            (r.get("PSCID") or "").strip()
            for r in usable
            if (r.get("PSCID") or "").strip()
        }
    )

    dob_by_pscid: dict[str, str] = {}
    db = None
    if args.profile:
        db = connect_db(args.profile)
        dob_by_pscid = load_dobs_from_db(db, pscids)
        if args.verbose:
            print(
                f"Loaded DoB for {len(dob_by_pscid)}/{len(pscids)} PSCIDs from DB",
                file=sys.stderr,
            )

    written = 0
    skipped = 0
    warnings: list[str] = []

    with out_path.open("w", newline="") as fh:
        writer = csv.writer(fh, quoting=csv.QUOTE_MINIMAL)
        for row in usable:
            pscid = (row.get("PSCID") or "").strip()
            visit = (row.get("Visit_label") or "").strip() or "Initial_MRI"
            date_acq = (row.get("DateAcquired") or "").strip()
            extract_dir = Path((row.get("ExtractDir") or "").strip())
            inner_tar = (row.get("InnerTar") or "").strip()

            if not pscid:
                skipped += 1
                warnings.append("skip row with empty PSCID")
                continue

            if pscid not in open_map:
                skipped += 1
                warnings.append(f"{pscid}: no open ID mapping")
                continue

            open_pscid, open_candid = open_map[pscid]
            new_patient_name = f"{open_pscid}_{open_candid}_{visit}"
            new_patient_id = open_pscid

            if not extract_dir.is_absolute():
                extract_dir = untar_dir / extract_dir
            dicom_dir = find_dicom_dir(extract_dir, inner_tar)
            if dicom_dir is None:
                skipped += 1
                warnings.append(f"{pscid}: no DICOM dir under {extract_dir}")
                continue

            dob_raw = dob_by_pscid.get(pscid, "")
            if not dob_raw:
                dob_raw = read_dob_from_dicom(dicom_dir)

            dob_mm_yyyy = to_mm_yyyy(dob_raw)
            acq_mm_yyyy = to_mm_yyyy(date_acq)
            if not acq_mm_yyyy:
                # Fallback: StudyDate from DICOM if summary date missing
                try:
                    import pydicom

                    for root, _dirs, files in os.walk(dicom_dir):
                        for name in files:
                            path = Path(root) / name
                            if not is_dicom_file(path):
                                continue
                            ds = pydicom.dcmread(
                                str(path), stop_before_pixels=True
                            )
                            acq_mm_yyyy = to_mm_yyyy(
                                str(getattr(ds, "StudyDate", "") or "")
                            )
                            break
                        if acq_mm_yyyy:
                            break
                except Exception:
                    pass

            if not dob_mm_yyyy:
                warnings.append(f"{pscid}: missing/unparseable DoB")
            if not acq_mm_yyyy:
                warnings.append(f"{pscid}: missing/unparseable DateAcquired")

            writer.writerow(
                [
                    str(dicom_dir),
                    new_patient_name,
                    new_patient_id,
                    dob_mm_yyyy,
                    acq_mm_yyyy,
                ]
            )
            written += 1
            if args.verbose:
                print(
                    f"{pscid} -> {dicom_dir} | {new_patient_name} | "
                    f"{new_patient_id} | {dob_mm_yyyy} | {acq_mm_yyyy}",
                    file=sys.stderr,
                )

    if db is not None:
        db.disconnect()

    print(
        f"Wrote {written} row(s) to {out_path} "
        f"(skipped {skipped}).",
        file=sys.stderr,
    )
    if warnings:
        # Deduplicate while preserving order
        seen = set()
        uniq = []
        for w in warnings:
            if w not in seen:
                seen.add(w)
                uniq.append(w)
        print(f"{len(uniq)} warning(s):", file=sys.stderr)
        for w in uniq[:50]:
            print(f"  {w}", file=sys.stderr)
        if len(uniq) > 50:
            print(f"  ... and {len(uniq) - 50} more", file=sys.stderr)


if __name__ == "__main__":
    main()
