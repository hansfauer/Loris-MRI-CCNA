#!/bin/bash
# Generate an HTML QA gallery from mideface --pics output and mri_reface renders
# Collects before/after PNGs and animated GIFs, flags registration issues
#
# Usage: ./generate_qa_gallery.sh
# View:
#   On VM:    cd /data/hans/BIDS_CND/derivatives && python3 -m http.server 8888
#   Locally:  ssh -L 8888:localhost:8888 lorisadmin@<VM_IP>
#   Browser:  http://localhost:8888/qa_gallery.html
#
# Or mount via SSHFS and open qa_gallery.html directly in your browser.

set -euo pipefail

DERIV_DIR="/data/hans/BIDS_CND/derivatives"
MIDFACE_DIR="${DERIV_DIR}/mideface"
REFACE_DIR="${DERIV_DIR}/mri_reface"
GALLERY="${DERIV_DIR}/qa_gallery.html"
GENERATED_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
SUFFIXES="${SUFFIXES:-T1w T2w PDw FLAIR}"

cat > "$GALLERY" <<HEADER
<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<title>CCNA Defacing QA Gallery</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #1a1a2e; color: #eee; margin: 2em; }
  h1 { color: #e94560; border-bottom: 2px solid #e94560; padding-bottom: 0.3em; }
  h3 { color: #aaa; margin-top: 0.2em; }
  .summary { background: #16213e; padding: 1em; border-radius: 8px; margin-bottom: 2em; }
  .summary span.count { color: #4ecca3; font-weight: bold; font-size: 1.2em; }
  .subject { border: 1px solid #333; margin: 1em 0; padding: 1em; border-radius: 8px; background: #16213e; }
  .subject h2 { color: #fff; background: #0f3460; display: inline-block; padding: 4px 16px; border-radius: 4px; margin-top: 0; }
  .method { margin: 0.8em 0; }
  .method-label { color: #4ecca3; font-weight: bold; margin-bottom: 0.3em; }
  .images { display: flex; gap: 1em; flex-wrap: wrap; align-items: flex-start; }
  .images figure { margin: 0; text-align: center; }
  .images img { max-width: 350px; border: 2px solid #555; border-radius: 4px; cursor: pointer; transition: transform 0.2s; }
  .images img:hover { transform: scale(1.05); }
  figcaption { font-size: 0.85em; color: #aaa; margin-top: 4px; }
  .cost { font-family: monospace; margin-top: 0.5em; }
  .cost.warn { color: #e94560; font-weight: bold; }
  .cost.ok { color: #4ecca3; }
  .no-pics { color: #888; font-style: italic; }
</style>
</head><body>
<h1>CCNA COMPASS-ND Defacing QA Gallery</h1>
<p>Generated: ${GENERATED_DATE}</p>
HEADER

subject_count=0
warn_count=0

# Collect all subject CandIDs from both mideface and mri_reface outputs
all_candids=""
for d in $(ls -d "$MIDFACE_DIR"/sub-* "$REFACE_DIR"/sub-* 2>/dev/null); do
    [ -d "$d" ] || continue
    cid=$(echo "$d" | grep -oP 'sub-\K[0-9]+')
    all_candids="$all_candids $cid"
done
all_candids=$(echo "$all_candids" | tr ' ' '\n' | sort -u)

for candid in $all_candids; do
    subject_count=$((subject_count + 1))

    cat >> "$GALLERY" <<SUBJ
<div class="subject"><h2>sub-${candid}</h2>
SUBJ

    for suffix in $SUFFIXES; do
        code="sub-${candid}_ses-InitialMRI_${suffix}"

        # --- mideface section ---
        qadir="$MIDFACE_DIR/sub-${candid}/ses-InitialMRI/anat/qa_${suffix}"
        if [ -d "$qadir" ]; then
            echo "<div class=\"method\"><div class=\"method-label\">mideface (FreeSurfer MiDeFace) [${suffix}]</div><div class=\"images\">" >> "$GALLERY"
            has_pics=0

            before="$qadir/${code}.face-before.png"
            after="$qadir/${code}.face-after.png"
            gif="$qadir/${code}.before+after.gif"

            if [ -f "$before" ]; then
                relpath=$(realpath --relative-to="$DERIV_DIR" "$before")
                echo "<figure><img src=\"${relpath}\" alt=\"Before\"><figcaption>Before (original)</figcaption></figure>" >> "$GALLERY"
                has_pics=1
            fi
            if [ -f "$after" ]; then
                relpath=$(realpath --relative-to="$DERIV_DIR" "$after")
                echo "<figure><img src=\"${relpath}\" alt=\"After mideface\"><figcaption>After (mideface)</figcaption></figure>" >> "$GALLERY"
                has_pics=1
            fi
            if [ -f "$gif" ]; then
                relpath=$(realpath --relative-to="$DERIV_DIR" "$gif")
                echo "<figure><img src=\"${relpath}\" alt=\"Animated\"><figcaption>Animated comparison</figcaption></figure>" >> "$GALLERY"
                has_pics=1
            fi

            if [ "$has_pics" -eq 0 ]; then
                echo "<p class=\"no-pics\">No QA images generated (--pics may not have been used)</p>" >> "$GALLERY"
            fi

            echo '</div>' >> "$GALLERY"

            costfile="$qadir/samseg/cost.txt"
            if [ -f "$costfile" ]; then
                cost=$(grep 'templateRegistration' "$costfile" 2>/dev/null | awk '{print $NF}' || true)
                if [ -n "$cost" ]; then
                    check=$(echo "$cost > -0.8" | bc -l 2>/dev/null || echo "0")
                    if [ "$check" = "1" ]; then
                        css_class="warn"
                        warn_count=$((warn_count + 1))
                        label="CHECK REGISTRATION"
                    else
                        css_class="ok"
                        label="OK"
                    fi
                    echo "<p class=\"cost ${css_class}\">Samseg registration cost: ${cost} [${label}]</p>" >> "$GALLERY"
                fi
            fi

            echo '</div>' >> "$GALLERY"
        fi

        # --- mri_reface section ---
        refacedir="$REFACE_DIR/sub-${candid}/ses-InitialMRI/anat"
        if [ -d "$refacedir" ]; then
            before_png=$(find "$refacedir" -maxdepth 1 -type f -name "${code}.png" 2>/dev/null | head -1 || true)
            after_png=$(find "$refacedir" -maxdepth 1 -type f -name "${code}_deFaced.png" 2>/dev/null | head -1 || true)

            if [ -n "${before_png:-}" ] || [ -n "${after_png:-}" ]; then
                echo "<div class=\"method\"><div class=\"method-label\">mri_reface (Mayo Clinic / NITRC) [${suffix}]</div><div class=\"images\">" >> "$GALLERY"

                if [ -n "${before_png:-}" ] && [ -f "$before_png" ]; then
                    relpath=$(realpath --relative-to="$DERIV_DIR" "$before_png")
                    echo "<figure><img src=\"${relpath}\" alt=\"Before\"><figcaption>Before (original)</figcaption></figure>" >> "$GALLERY"
                fi
                if [ -n "${after_png:-}" ] && [ -f "$after_png" ]; then
                    relpath=$(realpath --relative-to="$DERIV_DIR" "$after_png")
                    echo "<figure><img src=\"${relpath}\" alt=\"After mri_reface\"><figcaption>After (mri_reface)</figcaption></figure>" >> "$GALLERY"
                fi

                echo '</div></div>' >> "$GALLERY"
            fi
        fi
    done

    echo '</div>' >> "$GALLERY"
done

if [ "$subject_count" -eq 0 ]; then
    echo "<p class=\"no-pics\">No defacing output found. Run the pipeline first.</p>" >> "$GALLERY"
fi

# Insert summary at top (after header)
summary_file=$(mktemp)
cat > "$summary_file" <<SUMMARY
<div class="summary">
  <p>Subjects processed: <span class="count">${subject_count}</span></p>
  <p>Registration warnings (cost &gt; -0.8): <span class="count" style="color: $([ "$warn_count" -gt 0 ] && echo '#e94560' || echo '#4ecca3')">${warn_count}</span></p>
</div>
SUMMARY

{
    head_end=$(grep -n "Generated:" "$GALLERY" | tail -1 | cut -d: -f1)
    head -n "$head_end" "$GALLERY"
    cat "$summary_file"
    tail -n +"$((head_end + 1))" "$GALLERY"
} > "${GALLERY}.tmp" && mv "${GALLERY}.tmp" "$GALLERY"
rm -f "$summary_file"

echo "</body></html>" >> "$GALLERY"

echo "Gallery written to: $GALLERY"
echo "Subjects: ${subject_count}, Warnings: ${warn_count}"
echo ""
echo "To view remotely:"
echo "  1. On VM:    cd ${DERIV_DIR} && python3 -m http.server 8888"
echo "  2. Locally:  ssh -L 8888:localhost:8888 lorisadmin@<VM_IP>"
echo "  3. Browser:  http://localhost:8888/qa_gallery.html"
