#!/bin/bash
# Move DICAT *_deidentified.zip outputs out of the working tarchive tree.
set -euo pipefail

SRC=/data/not_backed_up/tarchive
DEST=/data/not_backed_up/tarchive_deID

dry_run=0
[[ ${1:-} == "-n" || ${1:-} == "--dry-run" ]] && dry_run=1

[[ -d $SRC ]] || { echo "ERROR: source not found: $SRC" >&2; exit 1; }
(( dry_run )) || mkdir -p "$DEST"

moved=0
skipped=0

while IFS= read -r -d '' file; do
    target="$DEST/$(basename "$file")"
    if [[ -e $target ]]; then
        echo "SKIP (name already in destination): $file"
        (( ++skipped ))
        continue
    fi
    if (( dry_run )); then
        echo "WOULD MOVE: $file"
    else
        mv "$file" "$target"
        echo "MOVED: $file"
    fi
    (( ++moved ))
done < <(find "$SRC" -type f -name '*_deidentified.zip' -print0)

echo
if (( dry_run )); then
    echo "Dry run: $moved file(s) would move to $DEST, $skipped skipped."
else
    echo "Moved $moved file(s) to $DEST, skipped $skipped."
fi
