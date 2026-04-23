#!/bin/bash
# Convert CCNA DICOM structural files to NIfTI (.nii.gz) via tarchive extraction + dcm2niix.
# Converts one anatomical contrast at a time (T1w/T2w/PDw/FLAIR) and keeps only that series.
#
# Usage:
#   SUFFIX=T1w ./convert_dcm_to_nii.sh <CandID> [CandID2 ...]
#   ./convert_dcm_to_nii.sh --suffix T2w <CandID> [CandID2 ...]
#   ./convert_dcm_to_nii.sh --suffix FLAIR --list subjects.txt
#   ./convert_dcm_to_nii.sh [--suffix <T1w|T2w|PDw|FLAIR>] --build-lookup   (build cache without converting)

set -euo pipefail
source "$(dirname "$0")/setup_env.sh"

SUFFIX="${SUFFIX:-T1w}"
if [ "${1:-}" = "--suffix" ]; then
    SUFFIX="${2:?ERROR: --suffix requires a value (T1w|T2w|PDw|FLAIR)}"
    shift 2
fi

case "$SUFFIX" in
    T1w|T2w|PDw|FLAIR) ;;
    *)
        echo "ERROR: Unsupported SUFFIX='$SUFFIX' (expected T1w|T2w|PDw|FLAIR)" >&2
        exit 1
        ;;
esac

TARCHIVE_DIR="/ccna-prod-data/ccna/data/tarchive"
OUTBASE="/data/hans/BIDS_CND/sourcedata/nifti"
LOOKUP_FILE="/data/hans/BIDS_CND/sourcedata/tarchive_lookup.tsv"
TMPBASE="/data/hans/tmp_dcm_extract"

# Series description patterns for each anatomical suffix.
# Note: these are best-effort heuristics; if your site naming differs, tighten patterns.
case "$SUFFIX" in
    T1w)
        PATTERNS="T1_3D|Sag_3D_T1|MPRAGE|t1_mprage|3D_T1|T1w|SAG.*T1|t1_sag"
        ;;
    T2w)
        # Include PD_T2 dual-echo series; echo choice is resolved via EchoTime (see select_pd_t2_by_te.py).
        # Avoid FLAIR-only series via negative matching in the dual-echo helper, not here.
        PATTERNS="T2w|3D_T2|T2_3D|Sag_3D_T2|T2_SPACE|T2w_|PD_T2|PD_T2_FS|Ax_PD_T2"
        ;;
    PDw)
        PATTERNS="PDw|PD_|pd|proton.density|proton_density|pd_weighted|PD_T2|PD_T2_FS|Ax_PD_T2"
        ;;
    FLAIR)
        PATTERNS="FLAIR|T2_FLAIR|Sag.*FLAIR|3D_FLAIR|t2_flair"
        ;;
esac

build_lookup() {
    echo "Building tarchive -> CandID lookup cache (this takes ~5 min on first run)..."
    mkdir -p "$(dirname "$LOOKUP_FILE")"
    local tmpfile="${LOOKUP_FILE}.tmp"
    : > "$tmpfile"

    for yeardir in "$TARCHIVE_DIR"/20*/; do
        [ -d "$yeardir" ] || continue
        for tarfile in "$yeardir"*.tar; do
            [ -f "$tarfile" ] || continue
            local meta
            meta=$(tar tf "$tarfile" 2>/dev/null | grep '\.meta$' | head -1) || continue
            [ -z "$meta" ] && continue

            local patient_name
            patient_name=$(tar xf "$tarfile" -O "$meta" 2>/dev/null \
                | grep "Patient Name" | head -1 \
                | sed 's/.*:\s*//' | xargs) || continue
            [ -z "$patient_name" ] && continue

            # Extract CandID from {PSCID}_{CandID}_{VisitLabel} pattern
            local candid
            candid=$(echo "$patient_name" | grep -oP '(?<=_)\d{6}(?=_)') || continue
            [ -z "$candid" ] && continue

            printf '%s\t%s\t%s\n' "$candid" "$tarfile" "$patient_name" >> "$tmpfile"
        done
    done

    sort -t$'\t' -k1,1 "$tmpfile" > "$LOOKUP_FILE"
    rm -f "$tmpfile"
    local count
    count=$(wc -l < "$LOOKUP_FILE")
    echo "Lookup cache built: ${count} entries in ${LOOKUP_FILE}"
}

ensure_lookup() {
    if [ ! -f "$LOOKUP_FILE" ] || [ ! -s "$LOOKUP_FILE" ]; then
        build_lookup
    fi
}

find_tarchive() {
    local candid=$1
    ensure_lookup
    # Return the first Initial_MRI tarchive for this CandID
    # grep may return 1 (no match), so guard against set -e with || true
    local result=""
    result=$(grep -P "^${candid}\t" "$LOOKUP_FILE" | grep -i "Initial_MRI" | head -1 | cut -f2 || true)
    if [ -z "$result" ]; then
        result=$(grep -P "^${candid}\t" "$LOOKUP_FILE" | head -1 | cut -f2 || true)
    fi
    echo "$result"
}

convert_subject() {
    local candid=$1
    local nii_gz="${OUTBASE}/sub-${candid}/ses-InitialMRI/anat/sub-${candid}_ses-InitialMRI_${SUFFIX}.nii.gz"

    if [ -f "$nii_gz" ]; then
        echo "SKIP: ${nii_gz} already exists"
        return 0
    fi

    local tarfile
    tarfile=$(find_tarchive "$candid")
    if [ -z "$tarfile" ] || [ ! -f "$tarfile" ]; then
        echo "WARN: No tarchive found for CandID ${candid}, skipping"
        return 1
    fi
    echo "Found tarchive for ${candid}: $(basename "$tarfile")"

    # Create temp extraction directory
    local tmpdir="${TMPBASE}/${candid}_$$"
    mkdir -p "$tmpdir"
    trap "rm -rf '$tmpdir'" RETURN

    # Extract the inner tar.gz from the outer tar
    local inner_tgz=""
    inner_tgz=$(tar tf "$tarfile" 2>/dev/null | grep '\.tar\.gz$' | head -1 || true)
    if [ -z "$inner_tgz" ]; then
        echo "WARN: No inner .tar.gz found in $(basename "$tarfile"), skipping"
        return 1
    fi

    echo "  Extracting DICOMs to ${tmpdir}..."
    tar xf "$tarfile" -O "$inner_tgz" | tar xzf - -C "$tmpdir"

    # Find the DICOM directory (may be nested several levels)
    local dcm_dir=""
    dcm_dir=$(find "$tmpdir" -type d -name "DICOM" | head -1 || true)
    if [ -z "$dcm_dir" ]; then
        dcm_dir=$(find "$tmpdir" -mindepth 1 -maxdepth 3 -type d | head -1 || true)
    fi
    if [ -z "$dcm_dir" ] || [ ! -d "$dcm_dir" ]; then
        echo "WARN: No DICOM directory found in extraction for ${candid}, skipping"
        return 1
    fi

    # Run dcm2niix on the extracted DICOMs into a staging area
    local staging="${tmpdir}/nifti_staging"
    mkdir -p "$staging"

    echo "  Running dcm2niix..."
    dcm2niix -z y -b y -f "%s_%d" -o "$staging" "$dcm_dir" > "${tmpdir}/dcm2niix.log" 2>&1 || true

    local selector_script
    selector_script="$(cd "$(dirname "$0")" && pwd)/select_pd_t2_by_te.py"

    # Find the requested SUFFIX NIfTI among the converted files
    local t1_nii=""
    local t1_json=""

    # Dual-echo PD+T2: same series name (e.g. *_PD_T2_*_e1 / *_e2). Disambiguate by EchoTime in JSON
    # (shorter TE → PDw, longer TE → T2w), with _e1/_e2 fallback if TE is missing.
    if [ "$SUFFIX" = "PDw" ] || [ "$SUFFIX" = "T2w" ]; then
        local picked=""
        picked=$(python3 "$selector_script" "$staging" "$SUFFIX" 2>/dev/null) || true
        if [ -n "$picked" ] && [ -f "$picked" ]; then
            t1_nii="$picked"
            local basename_nii
            basename_nii=$(basename "$t1_nii" .nii.gz)
            t1_json="${staging}/${basename_nii}.json"
            echo "  Selected ${SUFFIX} via dual-echo TE/heuristic: ${basename_nii}"
        fi
    fi

    if [ -z "$t1_nii" ]; then
        for nii in "$staging"/*.nii.gz; do
            [ -f "$nii" ] || continue
            local basename_nii
            basename_nii=$(basename "$nii" .nii.gz)
            if echo "$basename_nii" | grep -qiE "$PATTERNS"; then
                # Exclude FLAIR when asking for T2w (names can contain "T2" and "FLAIR").
                if [ "$SUFFIX" = "T2w" ] && echo "$basename_nii" | grep -qiE "FLAIR"; then
                    continue
                fi
                t1_nii="$nii"
                t1_json="${staging}/${basename_nii}.json"
                break
            fi
        done
    fi

    if [ -z "$t1_nii" ]; then
        echo "WARN: No ${SUFFIX} series found in dcm2niix output for ${candid}"
        echo "  Available series:"
        ls "$staging"/*.nii.gz 2>/dev/null | xargs -I{} basename {} .nii.gz | sed 's/^/    /'
        return 1
    fi

    # Move T1w to final BIDS location
    local outdir="${OUTBASE}/sub-${candid}/ses-InitialMRI/anat"
    mkdir -p "$outdir"

    cp "$t1_nii" "$nii_gz"
    if [ -f "$t1_json" ]; then
        cp "$t1_json" "${outdir}/sub-${candid}_ses-InitialMRI_${SUFFIX}.json"
    fi

    echo "OK: ${candid} -> ${nii_gz}"
}

# --- Main ---
if [ "${1:-}" = "--build-lookup" ]; then
    build_lookup
    exit 0
fi

if [ "${1:-}" = "--list" ]; then
    while IFS= read -r candid; do
        [ -z "$candid" ] && continue
        convert_subject "$candid" || true
    done < "$2"
else
    for candid in "$@"; do
        convert_subject "$candid" || true
    done
fi
