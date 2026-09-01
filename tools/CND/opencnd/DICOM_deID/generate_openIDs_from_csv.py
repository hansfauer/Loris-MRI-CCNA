#!/usr/bin/env python3
"""
generate_openIDs_from_csv.py

Generates new OPEN IDs (PSCID + CandID) for every candidate listed in an input
CSV file. Writes a CSV holding a strict 1-to-1 correspondence between each
candidate's current (PSCID, CandID) and a freshly generated OPEN pair:

    current_PSCID,current_CandID,open_PSCID,open_CandID
    JGH0174,614401,CCNA482915,732014

  - open PSCID  : "CCNA" followed by 6 random digits  (e.g. CCNA482915)
  - open CandID : 6 random digits                     (e.g. 732014)

Both random series are drawn without repetition so the mapping stays 1-to-1
within the generated output.

Input CSV must contain PSCID and CandID columns (header names are matched
case-insensitively; "current_PSCID" / "current_CandID" are also accepted).

Usage:
    ./generate_openIDs_from_csv.py candidates.csv [output.csv]
"""

import csv
import os
import random
import sys
from datetime import datetime

ID_LOW = 100000   # smallest 6-digit number (no leading zero)
ID_HIGH = 999999  # largest 6-digit number

PSCID_ALIASES = ("pscid", "current_pscid")
CANDID_ALIASES = ("candid", "current_candid")


def _find_column(fieldnames, aliases):
    lowered = {name.lower().strip(): name for name in fieldnames if name}
    for alias in aliases:
        if alias in lowered:
            return lowered[alias]
    return None


def load_candidates(path):
    """Load distinct (PSCID, CandID) pairs from the input CSV."""
    with open(path, newline="") as fh:
        reader = csv.DictReader(fh)
        if not reader.fieldnames:
            sys.exit(f"ERROR: input CSV has no header row: {path}")

        pscid_col = _find_column(reader.fieldnames, PSCID_ALIASES)
        candid_col = _find_column(reader.fieldnames, CANDID_ALIASES)
        if not pscid_col or not candid_col:
            sys.exit(
                "ERROR: input CSV must contain PSCID and CandID columns "
                f"(found: {reader.fieldnames})"
            )

        candidates = []
        seen = set()
        for i, row in enumerate(reader, start=2):
            pscid = (row.get(pscid_col) or "").strip()
            candid = (row.get(candid_col) or "").strip()
            if not pscid and not candid:
                continue
            if not pscid or not candid:
                sys.exit(
                    f"ERROR: missing PSCID or CandID on line {i} of {path}"
                )
            key = (pscid, candid)
            if key in seen:
                continue
            seen.add(key)
            candidates.append(key)

    return candidates


def main():
    if len(sys.argv) < 2:
        sys.exit(
            "Usage: generate_openIDs_from_csv.py <input.csv> [output.csv]"
        )

    in_path = sys.argv[1]
    if not os.path.isfile(in_path):
        sys.exit(f"ERROR: input CSV not found: {in_path}")

    out_path = (
        sys.argv[2]
        if len(sys.argv) > 2
        else os.path.join(
            os.path.dirname(os.path.abspath(__file__)),
            f"open_ids_{datetime.now():%Y%m%d_%H%M%S}.csv",
        )
    )

    candidates = load_candidates(in_path)
    n = len(candidates)
    if n == 0:
        sys.exit("ERROR: input CSV contained no candidates.")
    print(f"Loaded {n} candidate(s) from {in_path}.", file=sys.stderr)

    pool_size = ID_HIGH - ID_LOW + 1
    if n > pool_size:
        sys.exit(f"ERROR: {n} candidates exceed the 6-digit ID space.")

    # random.sample draws without repetition -> unique IDs within this run.
    pscid_nums = random.sample(range(ID_LOW, ID_HIGH + 1), n)
    candid_nums = random.sample(range(ID_LOW, ID_HIGH + 1), n)

    with open(out_path, "w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(
            ["current_PSCID", "current_CandID", "open_PSCID", "open_CandID"]
        )
        for (cur_pscid, cur_candid), pnum, cnum in zip(
            candidates, pscid_nums, candid_nums
        ):
            writer.writerow([cur_pscid, cur_candid, f"CCNA{pnum}", cnum])

    print(f"Done. Wrote {n} mappings to: {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
