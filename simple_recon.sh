#!/bin/bash
set -euo pipefail

# --- Optional Slack notifications ---
# Uncomment and set your webhook locally, keep it commented when committing
# SLACK_WEBHOOK="https://hooks.slack.com/services/XXXX/YYYY/ZZZZ"

# Require domain as first argument
if [[ -z "$1" ]]; then
    echo "Usage: $0 <domain>"
    exit 1
fi

DOMAIN="$1"
EXCLUDED_FILE="excluded.txt"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_DIR="results/$TIMESTAMP"
mkdir -p "$OUTPUT_DIR"

# Output files
SUBFINDER_OUT="$OUTPUT_DIR/subfinder_out.txt"
CRT_OUT="$OUTPUT_DIR/crtsh_out.txt"
COMBINED_SUBS="$OUTPUT_DIR/combined_subs.txt"
FILTERED_DOMAINS="$OUTPUT_DIR/filtered.txt"
ACTIVE_DOMAINS="$OUTPUT_DIR/active_domains.txt"
GAU_URLS="$OUTPUT_DIR/urls_gau.txt"
WAYBACK_URLS="$OUTPUT_DIR/urls_wayback.txt"
FINAL_URLS="$OUTPUT_DIR/final_urls.txt"
DELTA_REPORT="$OUTPUT_DIR/delta_report.txt"

# Steps
TOOLS=("subfinder" "crt.sh" "filter" "httpx" "gau" "waybackurls" "final merge")
TOTAL_STEPS=${#TOOLS[@]}
STEP=0
TOTAL_URLS=0
LAST_URLS=()

# Timing + counts
declare -A STAGE_TIMES
declare -A STAGE_COUNTS
declare -a STAGE_ORDER
SCRIPT_START=$(date +%s)

human_time() {
  local secs="$1"
  printf '%dm %02ds' $((secs/60)) $((secs%60))
}

notify_summary() {
  local total_elapsed=$(( $(date +%s) - SCRIPT_START ))
  local lines=()
  lines+=("Recon finished for ${DOMAIN} ✅")
  lines+=("Total time: $(human_time "$total_elapsed")")
  lines+=("")
  lines+=("Per stage (entries · duration):")
  for s in "${STAGE_ORDER[@]}"; do
    local c="${STAGE_COUNTS[$s]:-0}"
    local t="${STAGE_TIMES[$s]:-0}"
    lines+=("• ${s}: ${c} · $(human_time "$t")")
  done
  lines+=("")
  lines+=("Final URLs: $( [ -f "$FINAL_URLS" ] && wc -l < "$FINAL_URLS" || echo 0 )")

  local msg
  msg="$(printf "%s\n" "${lines[@]}")"

  # Slack (optional)
  if [[ -n "${SLACK_WEBHOOK:-}" ]]; then
    if ! command -v jq >/dev/null 2>&1; then
      echo "[!] jq not found; skipping Slack notification."
    else
      curl -sS -X POST -H 'Content-type: application/json' \
        --data "$(jq -Rn --arg text "$msg" '{text:$text}')" \
        "$SLACK_WEBHOOK" >/dev/null || true
    fi
  fi

  echo
  echo "$msg"
  echo
}

trap 'notify_summary' EXIT

update_last_urls() {
    local file=$1
    mapfile -t lines < <(tail -n 5 "$file" 2>/dev/null || true)
    LAST_URLS=("${lines[@]}")
}

update_url_count() {
    if [[ -f "$FINAL_URLS" ]]; then
        TOTAL_URLS=$(wc -l < "$FINAL_URLS")
    else
        TOTAL_URLS=0
    fi
}

draw_dashboard() {
    clear
    local percent=$(( (100 * STEP) / (TOTAL_STEPS - 1) ))
    echo "=============================="
    echo "  Subdomain & URL Discovery"
    echo "=============================="
    echo "Target Domain: $DOMAIN"
    echo "Progress: Step $STEP / $((TOTAL_STEPS - 1)) - ${TOOLS[$STEP]}"
    echo "Progress: $percent%"
    echo "Total URLs discovered: $TOTAL_URLS"
    echo "------------------------------"
    echo "Last 5 URLs processed/discovered:"
    for url in "${LAST_URLS[@]}"; do
        echo "  $url"
    done
    echo "------------------------------"
    echo "Tools executed so far:"
    for ((i=0; i<=STEP; i++)); do
        echo "  - ${TOOLS[i]}"
    done
    echo "=============================="
}

run_with_dashboard() {
    STEP=$1
    output_file=$2
    shift 2
    local cmd=("$@")
    local stage_name="${TOOLS[$STEP]}"
    STAGE_ORDER+=("$stage_name")

    : > "$output_file"
    local start=$(date +%s)

    if command -v stdbuf &>/dev/null; then
        stdbuf -oL "${cmd[@]}" | while IFS= read -r line; do
            echo "$line" >> "$output_file"
            update_last_urls "$output_file"
            update_url_count
            draw_dashboard
        done
    else
        "${cmd[@]}" | while IFS= read -r line; do
            echo "$line" >> "$output_file"
            update_last_urls "$output_file"
            update_url_count
            draw_dashboard
        done
    fi

    local end=$(date +%s)
    STAGE_TIMES["$stage_name"]=$(( end - start ))
    STAGE_COUNTS["$stage_name"]=$( [ -f "$output_file" ] && wc -l < "$output_file" || echo 0 )
}

time_block() {
  local stage_name="$1"; shift
  STAGE_ORDER+=("$stage_name")
  local start=$(date +%s)
  bash -c "$*"
  local end=$(date +%s)
  STAGE_TIMES["$stage_name"]=$(( end - start ))
}

########################################
# Pipeline
########################################

# Step 0: subfinder
run_with_dashboard 0 "$SUBFINDER_OUT" subfinder -d "$DOMAIN" -silent

# Step 1: crt.sh
STEP=1
echo "[*] Querying crt.sh for $DOMAIN"
time_block "crt.sh" '
  curl -s "https://crt.sh/?q=%25.'"$DOMAIN"'&output=json" |
    grep -oP '"'"'"name_value":"[^"]+"'"'"' |
    sed -E '"'"'s/"name_value":"//;s/\\n/\n/g'"'"' |
    tr '"'"'[:upper:]'"'"' '"'"'[:lower:]'"'"' |
    sort -u > "'"$CRT_OUT"'"
'
update_last_urls "$CRT_OUT"
draw_dashboard
STAGE_COUNTS["crt.sh"]=$( [ -f "$CRT_OUT" ] && wc -l < "$CRT_OUT" || echo 0 )

# Combine subfinder + crt.sh
cat "$SUBFINDER_OUT" "$CRT_OUT" | sort -u > "$COMBINED_SUBS"

# Step 2: Filter excluded
STEP=2
time_block "filter" '
  if [[ -f "'"$EXCLUDED_FILE"'" ]]; then
      grep -vFf "'"$EXCLUDED_FILE"'" "'"$COMBINED_SUBS"'" > "'"$FILTERED_DOMAINS"'"
  else
      cp "'"$COMBINED_SUBS"'" "'"$FILTERED_DOMAINS"'"
  fi
'
update_last_urls "$FILTERED_DOMAINS"
draw_dashboard
STAGE_COUNTS["filter"]=$( [ -f "$FILTERED_DOMAINS" ] && wc -l < "$FILTERED_DOMAINS" || echo 0 )

# Step 3: httpx
run_with_dashboard 3 "$ACTIVE_DOMAINS" httpx -silent -l "$FILTERED_DOMAINS"

# Step 4: gau
run_with_dashboard 4 "$GAU_URLS" bash -c "cat $ACTIVE_DOMAINS | gau --subs | grep '='"

# Step 5: waybackurls
run_with_dashboard 5 "$WAYBACK_URLS" bash -c "cat $ACTIVE_DOMAINS | waybackurls | grep '='"

# Step 6: Merge URLs
STEP=6
STAGE_ORDER+=("final merge")
start_merge=$(date +%s)
cat "$GAU_URLS" "$WAYBACK_URLS" | sort -u > "$FINAL_URLS"
update_last_urls "$FINAL_URLS"
update_url_count
draw_dashboard
end_merge=$(date +%s)
STAGE_TIMES["final merge"]=$(( end_merge - start_merge ))
STAGE_COUNTS["final merge"]=$( [ -f "$FINAL_URLS" ] && wc -l < "$FINAL_URLS" || echo 0 )

# Delta report
LAST_DIR=$(ls -dt results/*/ 2>/dev/null | grep -v "$TIMESTAMP" | head -n 1 || true)
LAST_FINAL="${LAST_DIR%/}/final_urls.txt"
if [[ -n "${LAST_DIR:-}" && -f "$LAST_FINAL" ]]; then
    echo "[*] Generating delta report..."
    comm -13 <(sort "$LAST_FINAL") <(sort "$FINAL_URLS") > "$DELTA_REPORT"
    echo "✅ Delta report saved to $DELTA_REPORT"
    echo "New URLs since last run: $(wc -l < "$DELTA_REPORT")"
else
    echo "[*] No previous run to compare for delta."
fi

# Cleanup old runs
echo -e "\n🧹 Cleaning up old results (keeping last 3)..."
ls -dt results/*/ 2>/dev/null | tail -n +4 | xargs -r rm -rf
echo "✅ Cleanup complete."

echo
echo "✅ Done! Results are in: $OUTPUT_DIR"
# notify_summary runs automatically at EXIT
