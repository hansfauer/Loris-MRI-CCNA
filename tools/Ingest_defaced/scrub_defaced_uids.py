#!/usr/bin/env python3
"""Scrub Series/Study UIDs from defaced BIDS JSON and linked file parameters.

Workflow
========
1. Load the Python database profile named by --profile from
    ``$LORIS_CONFIG/.loris_mri`` and connect to its database.
2. Find COMPASS-ND ``files`` records with OutputType ``defaced`` and FileType
    ``nii``. Their ``bids_json_file`` parameters identify sidecars to process.
3. Validate each referenced path is a relative, regular file under
    ``assembly_bids``. Parse each JSON object and replace present
    ``SeriesInstanceUID`` and ``StudyInstanceUID`` values with
    ``__SCRUBBED__``.
4. Find every ``parameter_file`` row referencing those shared sidecars. Plan
    UID-parameter updates for all linked original and defaced FileIDs, and
    calculate a new BLAKE2b hash for the serialized scrubbed JSON for every
    linked FileID.
5. Print counts. By default this is a dry run: no sidecar or database changes
    are made. Use ``--commit`` only after reviewing the plan.

Examples
========
Preview all sidecars linked to defaced NIfTIs::

     python tools/Ingest_defaced/scrub_defaced_uids.py

Preview one sidecar (path relative to dataDirBasepath)::

     python tools/Ingest_defaced/scrub_defaced_uids.py \\
          --json assembly_bids/sub-123/ses-V1/anat/scan.json

Commit that one sidecar after QC mapping and review::

     python tools/Ingest_defaced/scrub_defaced_uids.py \\
          --json assembly_bids/sub-123/ses-V1/anat/scan.json --commit

On commit, original JSON bytes are copied under a timestamped, permission-
restricted directory in ``/data/ccnaopen/data/backups`` before replacement.
Database parameter updates use a transaction. Since the filesystem and SQL
database cannot share one atomic transaction, the script stages JSON files and
attempts to restore changed sidecars from backup if a database operation fails.

The sidecars are shared by original and defaced records, so they are edited in
place and all database records referencing them get refreshed JSON hashes.
``files.SeriesUID`` and ``tarchive.DicomArchiveID`` are deliberately preserved.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
MRI_ROOT = SCRIPT_DIR.parents[1]
PYTHON_ROOT = MRI_ROOT / "python"
DATA_DIR = Path("/data/ccnaopen/data")
BIDS_ROOT = DATA_DIR / "assembly_bids"
BACKUP_ROOT = DATA_DIR / "backups"
PROJECT_NAME = "COMPASS-ND"
UID_JSON_KEYS = ("SeriesInstanceUID", "StudyInstanceUID")
UID_PARAMETER_NAMES = ("series_instance_uid", "study_instance_uid")
JSON_PARAMETER_NAME = "bids_json_file"
JSON_HASH_PARAMETER_NAME = "bids_json_file_blake2b_hash"
SCRUBBED_VALUE = "__SCRUBBED__"


def parse_args() -> argparse.Namespace:
    """Parse profile, optional single-sidecar scope, and explicit commit mode."""
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "-p", "--profile", default="database_config.py",
        help="Python database profile in $LORIS_CONFIG/.loris_mri (default: database_config.py)",
    )
    parser.add_argument(
        "--commit", action="store_true",
        help="Back up and write the UID scrubbing changes; default is dry-run only",
    )
    parser.add_argument(
        "--json", dest="json_path",
        help="Limit the run to one JSON sidecar, relative to dataDirBasepath (for example assembly_bids/sub-123/ses-V1/anat/scan.json)",
    )
    return parser.parse_args()


def load_profile(profile_name: str) -> Any:
    """Load database settings from the standard LORIS-MRI Python profile directory."""
    sys.path.insert(0, str(PYTHON_ROOT))
    loris_config = os.environ.get("LORIS_CONFIG")
    if not loris_config:
        raise RuntimeError("LORIS_CONFIG is not set")
    profile_path = Path(loris_config) / ".loris_mri" / profile_name
    if not profile_path.is_file() or profile_path.suffix != ".py":
        raise RuntimeError(f"Python database profile not found: {profile_path}")
    spec = importlib.util.spec_from_file_location("uid_scrub_database_profile", profile_path)
    if spec is None or spec.loader is None:
        raise RuntimeError("Could not load the selected database profile")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if not hasattr(module, "mysql"):
        raise RuntimeError("The selected profile does not define mysql database settings")
    return module


def connect_database(profile: Any) -> Any:
    """Connect through the repository Database wrapper with writes held in a transaction."""
    sys.path.insert(0, str(PYTHON_ROOT))
    from lib.database import Database

    database = Database(profile.mysql, verbose=False)
    database.connect()
    database.con.autocommit(False)
    return database


def fetch_parameter_type_ids(database: Any) -> dict[str, int]:
    """Resolve required parameter types up front so missing schema support fails early."""
    names = (JSON_PARAMETER_NAME, JSON_HASH_PARAMETER_NAME, *UID_PARAMETER_NAMES)
    placeholders = ",".join(["%s"] * len(names))
    rows = database.pselect(
        f"SELECT Name, ParameterTypeID FROM parameter_type WHERE Name IN ({placeholders})",
        names,
    )
    result = {row["Name"]: int(row["ParameterTypeID"]) for row in rows}
    missing = sorted(set(names) - result.keys())
    if missing:
        raise RuntimeError("Missing parameter types: " + ", ".join(missing))
    return result


def resolve_sidecar(relative_path: str) -> tuple[Path, str]:
    """Resolve a database-relative BIDS JSON path and reject traversal, symlinks, or escapes."""
    relative = PurePosixPath(relative_path)
    if relative.is_absolute() or ".." in relative.parts:
        raise RuntimeError("BIDS JSON reference is not a safe relative path")
    bids_root = BIDS_ROOT.resolve(strict=True)
    sidecar = (DATA_DIR / Path(*relative.parts)).resolve(strict=True)
    if not sidecar.is_file() or not sidecar.is_relative_to(bids_root):
        raise RuntimeError("BIDS JSON sidecar is missing or outside assembly_bids")
    current = DATA_DIR
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise RuntimeError("Symlinked BIDS JSON paths are not supported")
    return sidecar, relative.as_posix()


def read_json_plan(sidecar: Path, relative_path: str) -> dict[str, Any]:
    """Read one JSON object, replace only UID fields, and calculate its output hash in memory."""
    raw = sidecar.read_bytes()
    try:
        document = json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RuntimeError(f"Invalid JSON sidecar: {relative_path}") from error
    if not isinstance(document, dict):
        raise RuntimeError(f"JSON sidecar root is not an object: {relative_path}")
    changed_keys = [
        key for key in UID_JSON_KEYS
        if key in document and document[key] != SCRUBBED_VALUE
    ]
    for key in changed_keys:
        document[key] = SCRUBBED_VALUE
    encoded = (json.dumps(document, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    digest = hashlib.blake2b(encoded).hexdigest()
    return {
        "path": sidecar,
        "relative_path": relative_path,
        "original_bytes": raw,
        "updated_bytes": encoded,
        "hash": digest,
        "changed_keys": changed_keys,
    }


def build_plan(
    database: Any,
    type_ids: dict[str, int],
    selected_json: str | None = None,
) -> dict[str, Any]:
    """Build a read-only update plan for all defaced scans or one selected sidecar.

    A sidecar may be shared by the native and defaced records. The plan therefore
    includes all FileIDs whose bids_json_file parameter points to that same path.
    """
    defaced_rows = database.pselect(
        "SELECT f.FileID FROM files f "
        "JOIN session s ON s.ID = f.SessionID "
        "JOIN Project p ON p.ProjectID = s.ProjectID "
        "WHERE p.Name = %s AND f.OutputType = %s AND f.FileType = %s "
        "ORDER BY f.FileID",
        (PROJECT_NAME, "defaced", "nii"),
    )
    if not defaced_rows:
        raise RuntimeError("No defaced NIfTI records found for the configured project")

    defaced_ids = [int(row["FileID"]) for row in defaced_rows]
    id_placeholders = ",".join(["%s"] * len(defaced_ids))
    sidecar_rows = database.pselect(
        "SELECT FileID, Value FROM parameter_file "
        "WHERE ParameterTypeID = %s AND FileID IN (" + id_placeholders + ")",
        (type_ids[JSON_PARAMETER_NAME], *defaced_ids),
    )
    sidecars_by_defaced_id: dict[int, str] = {}
    for row in sidecar_rows:
        file_id = int(row["FileID"])
        if file_id in sidecars_by_defaced_id:
            raise RuntimeError(f"Defaced FileID {file_id} has duplicate BIDS JSON links")
        if not row["Value"]:
            raise RuntimeError(f"Defaced FileID {file_id} has an empty BIDS JSON link")
        sidecars_by_defaced_id[file_id] = row["Value"]
    missing_links = sorted(set(defaced_ids) - sidecars_by_defaced_id.keys())
    if missing_links:
        raise RuntimeError(f"{len(missing_links)} defaced scans have no BIDS JSON link")

    if selected_json is not None:
        _, selected_json = resolve_sidecar(selected_json)
        sidecars_by_defaced_id = {
            file_id: path for file_id, path in sidecars_by_defaced_id.items()
            if resolve_sidecar(path)[1] == selected_json
        }
        if not sidecars_by_defaced_id:
            raise RuntimeError(
                "The selected JSON sidecar is not linked to a defaced NIfTI in the project"
            )
        defaced_ids = sorted(sidecars_by_defaced_id)

    json_plans: dict[str, dict[str, Any]] = {}
    for relative_path in sorted(set(sidecars_by_defaced_id.values())):
        sidecar, normalized = resolve_sidecar(relative_path)
        json_plans[normalized] = read_json_plan(sidecar, normalized)

    all_references = database.pselect(
        "SELECT FileID, Value FROM parameter_file WHERE ParameterTypeID = %s",
        (type_ids[JSON_PARAMETER_NAME],),
    )
    file_ids_by_sidecar: dict[str, set[int]] = {path: set() for path in json_plans}
    for row in all_references:
        if row["Value"] in file_ids_by_sidecar:
            file_ids_by_sidecar[row["Value"]].add(int(row["FileID"]))
    for relative_path, linked_ids in file_ids_by_sidecar.items():
        if not linked_ids:
            raise RuntimeError(f"No database records reference sidecar: {relative_path}")
        json_plans[relative_path]["file_ids"] = sorted(linked_ids)

    all_file_ids = sorted({file_id for ids in file_ids_by_sidecar.values() for file_id in ids})
    linked_placeholders = ",".join(["%s"] * len(all_file_ids))
    uid_rows = database.pselect(
        "SELECT FileID, ParameterTypeID, Value FROM parameter_file "
        "WHERE ParameterTypeID IN (%s, %s) AND FileID IN (" + linked_placeholders + ")",
        (*[type_ids[name] for name in UID_PARAMETER_NAMES], *all_file_ids),
    )
    uid_updates = [
        (SCRUBBED_VALUE, int(row["FileID"]), int(row["ParameterTypeID"]))
        for row in uid_rows if row["Value"] != SCRUBBED_VALUE
    ]

    hash_rows = database.pselect(
        "SELECT FileID, Value FROM parameter_file "
        "WHERE ParameterTypeID = %s AND FileID IN (" + linked_placeholders + ")",
        (type_ids[JSON_HASH_PARAMETER_NAME], *all_file_ids),
    )
    existing_hashes = {int(row["FileID"]) for row in hash_rows}
    hash_updates = []
    hash_inserts = []
    now = int(dt.datetime.now().timestamp())
    for plan in json_plans.values():
        for file_id in plan["file_ids"]:
            values = (plan["hash"], now, file_id, type_ids[JSON_HASH_PARAMETER_NAME])
            if file_id in existing_hashes:
                hash_updates.append(values)
            else:
                hash_inserts.append((file_id, type_ids[JSON_HASH_PARAMETER_NAME], plan["hash"], now))

    return {
        "defaced_count": len(defaced_ids),
        "json_plans": json_plans,
        "uid_updates": uid_updates,
        "hash_updates": hash_updates,
        "hash_inserts": hash_inserts,
        "linked_file_count": len(all_file_ids),
    }


def write_backups(plan: dict[str, Any]) -> Path:
    """Copy only sidecars that will change, preserving their relative paths in a private backup."""
    BACKUP_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup_dir = BACKUP_ROOT / f"uid_scrub_{stamp}"
    backup_dir.mkdir(mode=0o700)
    for relative_path, item in plan["json_plans"].items():
        if not item["changed_keys"]:
            continue
        destination = backup_dir / Path(*PurePosixPath(relative_path).parts)
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        shutil.copy2(item["path"], destination)
    return backup_dir


def stage_json_files(plan: dict[str, Any]) -> list[tuple[Path, Path]]:
    """Write scrubbed JSON to temporary sibling files without replacing originals yet."""
    staged: list[tuple[Path, Path]] = []
    try:
        for item in plan["json_plans"].values():
            if not item["changed_keys"]:
                continue
            fd, temporary_name = tempfile.mkstemp(prefix=".uid-scrub-", dir=item["path"].parent)
            temporary = Path(temporary_name)
            with os.fdopen(fd, "wb") as output:
                output.write(item["updated_bytes"])
                output.flush()
                os.fsync(output.fileno())
            os.chmod(temporary, stat.S_IMODE(item["path"].stat().st_mode))
            staged.append((temporary, item["path"]))
    except Exception:
        for temporary, _ in staged:
            temporary.unlink(missing_ok=True)
        raise
    return staged


def commit_plan(database: Any, type_ids: dict[str, int], plan: dict[str, Any]) -> Path:
    """Back up sidecars, update linked parameter rows, replace JSON, then commit SQL.

    The DB transaction rolls back on failure. Any sidecars already replaced are
    restored from the private backup; a process or host crash still requires
    manual comparison with that backup because filesystem writes are not atomic
    with the database transaction.
    """
    backup_dir = write_backups(plan)
    staged = stage_json_files(plan)
    replaced: list[tuple[Path, Path]] = []
    cursor = database.con.cursor()
    try:
        database.con.begin()
        cursor.executemany(
            "UPDATE parameter_file SET Value = %s "
            "WHERE FileID = %s AND ParameterTypeID = %s",
            plan["uid_updates"],
        )
        cursor.executemany(
            "UPDATE parameter_file SET Value = %s, InsertTime = %s "
            "WHERE FileID = %s AND ParameterTypeID = %s",
            plan["hash_updates"],
        )
        cursor.executemany(
            "INSERT INTO parameter_file (FileID, ParameterTypeID, Value, InsertTime) "
            "VALUES (%s, %s, %s, %s) "
            "ON DUPLICATE KEY UPDATE Value = VALUES(Value), InsertTime = VALUES(InsertTime)",
            plan["hash_inserts"],
        )
        for temporary, destination in staged:
            os.replace(temporary, destination)
            replaced.append((temporary, destination))
        database.con.commit()
    except Exception:
        database.con.rollback()
        for temporary, destination in reversed(replaced):
            relative = destination.relative_to(DATA_DIR.resolve()).as_posix()
            backup = backup_dir / relative
            if backup.is_file():
                fd, restore_name = tempfile.mkstemp(prefix=".uid-restore-", dir=destination.parent)
                with os.fdopen(fd, "wb") as restored:
                    restored.write(backup.read_bytes())
                    restored.flush()
                    os.fsync(restored.fileno())
                os.chmod(restore_name, stat.S_IMODE(destination.stat().st_mode))
                os.replace(restore_name, destination)
        raise
    finally:
        cursor.close()
        for temporary, _ in staged:
            temporary.unlink(missing_ok=True)
    return backup_dir


def main() -> int:
    """Load configuration, build and report the plan, and write only with --commit."""
    args = parse_args()
    profile = load_profile(args.profile)
    database = connect_database(profile)
    try:
        type_ids = fetch_parameter_type_ids(database)
        plan = build_plan(database, type_ids, args.json_path)
        changed_json = sum(bool(item["changed_keys"]) for item in plan["json_plans"].values())
        unchanged_json = len(plan["json_plans"]) - changed_json
        json_key_updates = sum(len(item["changed_keys"]) for item in plan["json_plans"].values())
        print("Mode:", "COMMIT" if args.commit else "DRY RUN")
        print("Defaced NIfTI records:", plan["defaced_count"])
        if args.json_path:
            print("Selected JSON sidecar:", args.json_path)
        print("Distinct linked JSON sidecars:", len(plan["json_plans"]))
        print("JSON sidecars requiring edits:", changed_json)
        print("JSON sidecars already scrubbed:", unchanged_json)
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
        backup_dir = commit_plan(database, type_ids, plan)
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
