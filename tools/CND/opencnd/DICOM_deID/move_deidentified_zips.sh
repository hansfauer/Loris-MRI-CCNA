#!/bin/bash
# Move DICAT *_deidentified.zip outputs out of the working tarchive tree.
set -euo pipefail

SRC=/data/not_backed_up/tarchive
DEST=/data/not_backed_up/tarchive_deID

dry_run=0
limit=0
while (( $# )); do
    case $1 in
        -n|--dry-run)
            dry_run=1
            ;;
        --limit)
            limit=${2:?ERROR: --limit requires a positive integer}
            shift
            ;;
        *)
            echo "Usage: $0 [--dry-run] [--limit N]" >&2
            exit 2
            ;;
    esac
    shift
done
[[ $limit =~ ^[1-9][0-9]*$|^0$ ]] || {
    echo "ERROR: --limit must be a positive integer" >&2
    exit 2
}

[[ -d $SRC ]] || { echo "ERROR: source not found: $SRC" >&2; exit 1; }
(( dry_run )) || mkdir -p "$DEST"

moved=0
renamed=0
declare -A taken  # tracks names claimed this run so a dry run sees collisions too

while IFS= read -r -d '' file; do
    if (( limit && moved >= limit )); then
        break
    fi
    name=$(basename "$file")
    target="$DEST/$name"
    if [[ -e $target || -n ${taken[$target]:-} ]]; then
        stem=${name%.zip}
        n=1
        target="$DEST/${stem}_other.zip"
        while [[ -e $target || -n ${taken[$target]:-} ]]; do
            (( ++n ))
            target="$DEST/${stem}_other${n}.zip"
        done
        echo "DUPLICATE: $name -> $(basename "$target")"
        (( ++renamed ))
    fi
    taken[$target]=1
    if (( dry_run )); then
        echo "WOULD MOVE: $file -> $(basename "$target")"
    else
        mv "$file" "$target"
        echo "MOVED: $file -> $(basename "$target")"
    fi
    (( ++moved ))
done < <(find "$SRC" -maxdepth 3 -type f -name '*_deidentified.zip' -print0)

echo
if (( dry_run )); then
    echo "Dry run: $moved file(s) would move to $DEST ($renamed renamed as duplicates)."
else
    echo "Moved $moved file(s) to $DEST ($renamed renamed as duplicates)."
fi
