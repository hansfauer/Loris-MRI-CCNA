#!/usr/bin/env python3
"""Scrub Series/Study UIDs from native part-phase T2starw BIDS JSON sidecars.

Phase images are not defaced, so their sidecars are not linked to defaced
records and are skipped by ``scrub_defaced_uids.py``. This script selects
COMPASS-ND native NIfTI records named ``*_part-phase_T2starw.nii.gz`` and
applies the same scrubbing, backup, hash refresh, and commit logic.

Examples
========
Preview all phase sidecars::

     python tools/Ingest_defaced/scrub_phase_uids.py

Commit one phase sidecar (path relative to dataDirBasepath)::

     python tools/Ingest_defaced/scrub_phase_uids.py \\
          --json assembly_bids/sub-123/ses-V1/anat/sub-123_ses-V1_run-1_part-phase_T2starw.json --commit
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import scrub_defaced_uids as scrub  # noqa: E402

PHASE_SUFFIX = "_part-phase_T2starw.nii.gz"


def build_phase_plan(
    database: Any,
    type_ids: dict[str, int],
    selected_json: str | None = None,
) -> dict[str, Any]:
    """Build a read-only update plan for all phase T2starw sidecars or one selected sidecar."""
    rows = database.pselect(
        "SELECT f.FileID, f.File FROM files f "
        "JOIN session s ON s.ID = f.SessionID "
        "JOIN Project p ON p.ProjectID = s.ProjectID "
        "WHERE p.Name = %s AND f.OutputType = %s AND f.FileType = %s "
        "AND f.File LIKE %s ORDER BY f.FileID",
        (scrub.PROJECT_NAME, "native", "nii", "%part-phase%T2starw.nii.gz"),
    )
    # SQL LIKE is case-insensitive here; enforce the exact BIDS suffix.
    phase_ids = [int(row["FileID"]) for row in rows if row["File"].endswith(PHASE_SUFFIX)]
    if not phase_ids:
        raise RuntimeError("No native part-phase T2starw NIfTI records found for the configured project")

    placeholders = ",".join(["%s"] * len(phase_ids))
    sidecar_rows = database.pselect(
        "SELECT FileID, Value FROM parameter_file "
        "WHERE ParameterTypeID = %s AND FileID IN (" + placeholders + ")",
        (type_ids[scrub.JSON_PARAMETER_NAME], *phase_ids),
    )
    sidecars_by_phase_id: dict[int, str] = {}
    for row in sidecar_rows:
        file_id = int(row["FileID"])
        if file_id in sidecars_by_phase_id:
            raise RuntimeError(f"Phase FileID {file_id} has duplicate BIDS JSON links")
        if not row["Value"]:
            raise RuntimeError(f"Phase FileID {file_id} has an empty BIDS JSON link")
        sidecars_by_phase_id[file_id] = row["Value"]
    missing_links = sorted(set(phase_ids) - sidecars_by_phase_id.keys())
    if missing_links:
        raise RuntimeError(f"{len(missing_links)} phase scans have no BIDS JSON link: {missing_links}")

    if selected_json is not None:
        _, selected_json = scrub.resolve_sidecar(selected_json)
        sidecars_by_phase_id = {
            file_id: path for file_id, path in sidecars_by_phase_id.items()
            if scrub.resolve_sidecar(path)[1] == selected_json
        }
        if not sidecars_by_phase_id:
            raise RuntimeError("The selected JSON sidecar is not linked to a phase T2starw NIfTI in the project")

    plan = scrub.plan_sidecars(database, type_ids, sidecars_by_phase_id.values())
    plan["phase_count"] = len(sidecars_by_phase_id)
    return plan


def main() -> int:
    """Load configuration, build and report the plan, and write only with --commit."""
    args = scrub.parse_args()
    profile = scrub.load_profile(args.profile)
    database = scrub.connect_database(profile)
    try:
        type_ids = scrub.fetch_parameter_type_ids(database)
        plan = build_phase_plan(database, type_ids, args.json_path)
        changed_json = sum(bool(item["changed_keys"]) for item in plan["json_plans"].values())
        json_key_updates = sum(len(item["changed_keys"]) for item in plan["json_plans"].values())
        print("Mode:", "COMMIT" if args.commit else "DRY RUN")
        print("Phase T2starw NIfTI records:", plan["phase_count"])
        if args.json_path:
            print("Selected JSON sidecar:", args.json_path)
        print("Distinct linked JSON sidecars:", len(plan["json_plans"]))
        print("JSON sidecars requiring edits:", changed_json)
        print("JSON sidecars already scrubbed:", len(plan["json_plans"]) - changed_json)
        print("UID JSON fields to replace:", json_key_updates)
        print("Linked file records to refresh JSON hashes:", plan["linked_file_count"])
        print("UID parameter rows to scrub:", len(plan["uid_updates"]))
        print("JSON hash parameter rows to update:", len(plan["hash_updates"]))
        print("JSON hash parameter rows to insert if missing:", len(plan["hash_inserts"]))
        print("files.SeriesUID: unchanged")
        print("tarchive.DicomArchiveID: unchanged")
        if not args.commit:
            print("Dry run only; no files or database rows were changed.")
            return 0
        backup_dir = scrub.commit_plan(database, type_ids, plan)
        print("Scrubbing committed. JSON backups:", backup_dir)
        return 0
    finally:
        if database.con.open:
            database.con.rollback()
            database.con.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
