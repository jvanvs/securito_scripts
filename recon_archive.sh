#!/bin/bash
set -euo pipefail

# --- Optional Slack notifications ---
# export SLACK_WEBHOOK="https://hooks.slack.com/services/XXXX/YYYY/ZZZZ"

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <domain>"
  exit 1
fi

DOMAIN="$1"
EXCLUDED_FILE="excluded.txt"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DOMAIN_DIR="$(pwd)/$DOMAIN"
OUTPUT_DIR="$DOMAIN_DIR/$TIMESTAMP-archive"
mkdir -p "$OUTPUT_DIR"

# Outputs
SUBFINDER_OUT="$OUTPUT_DIR/subfinder_out.txt"
CRT_OUT="$OUTPUT_DIR/crtsh_out.txt"
AMASS_OUT="$OUTPUT_DIR/amass_out.txt"
COMBINED_SUBS="$OUTPUT_DIR/combined_subs.txt"
FILTERED_DOMAINS="$OUTPUT_DIR/filtered.txt"
GAU_RAW="$OUTPUT_DIR/gau_raw.txt"
WAYBACK_RAW="$OUTPUT_DIR/wayback_raw.txt"
GAU_PARAMS="$OUTPUT_DIR/gau_params.txt"
WAYBACK_PARAMS="$OUTPUT_DIR/wayback_params.txt"
ARCHIVE_URLS="$OUTPUT_DIR/archive_urls.txt"
ARCHIVE_PARAMS="$OUTPUT_DIR/archive_params.txt"

TOOLS=("subfinder" "crt.sh" "amass" "filter" "gau" "waybackurls" "merge (archive)")
TOTAL_STEPS=${#TOOLS[@]}
STEP=0; LAST_URLS=()

declare -A STAGE_TIMES STAGE_COUNTS
declare -a STAGE_ORDER
SCRIPT_START=$(date +%s)

human_time(){ local s="$1"; printf '%dm %02ds' $((s/60)) $((s%60)); }

notify_summary(){
  local elapsed=$(( $(date +%s) - SCRIPT_START ))
  local urls_total=$( [ -f "$ARCHIVE_URLS" ] && wc -l < "$ARCHIVE_URLS" || echo 0 )
  local params_total=$( [ -f "$ARCHIVE_PARAMS" ] && wc -l < "$ARCHIVE_PARAMS" || echo 0 )

  # Build message
  {
    echo "Archive recon finished for ${DOMAIN} ✅"
    echo "Output dir: ${OUTPUT_DIR}"
    echo "Total time: $(human_time "$elapsed")"
    echo
    echo "Per stage (entries · duration):"
    for s in "${STAGE_ORDER[@]}"; do
      echo "• ${s}: ${STAGE_COUNTS[$s]:-0} · $(human_time "${STAGE_TIMES[$s]:-0}")"
    done
    echo
    echo "Archive URLs total: ${urls_total}"
    echo "Archive params total: ${params_total}"
  } > "$OUTPUT_DIR/_summary.txt"

  # Slack (optional)
  if [[ -n "${SLACK_WEBHOOK:-}" ]]; then
    if command -v jq >/dev/null 2>&1; then
      curl -sS -X POST -H 'Content-type: application/json' \
        --data "$(jq -Rn --arg text "$(cat "$OUTPUT_DIR/_summary.txt")" '{text:$text}')" \
        "$SLACK_WEBHOOK" >/dev/null || true
    else
      echo "[!] jq not found; skipping Slack notification."
    fi
  fi

  echo
  cat "$OUTPUT_DIR/_summary.txt"
  echo
}
trap 'notify_summary' EXIT

update_last_urls(){ local f=$1; mapfile -t lines < <(tail -n 5 "$f" 2>/dev/null || true); LAST_URLS=("${lines[@]}"); }

draw_dashboard(){
  clear
  local percent=$(( (100 * STEP) / (TOTAL_STEPS - 1) ))
  echo "=============================="
  echo "  Archive URLs (GAU + Wayback)"
  echo "=============================="
  echo "Target: $DOMAIN"
  echo "Output: $DOMAIN_DIR"
  echo "Progress: Step $STEP / $((TOTAL_STEPS - 1)) - ${TOOLS[$STEP]}"
  echo "Progress: $percent%"
  echo "------------------------------"
  echo "Last lines:"
  for l in "${LAST_URLS[@]}"; do echo "  $l"; done
  echo "=============================="
}

run_with_dashboard(){
  STEP=$1; local out=$2; shift 2; local cmd=("$@")
  local stage="${TOOLS[$STEP]}"; STAGE_ORDER+=("$stage")
  : > "$out"; local start=$(date +%s)
  if command -v stdbuf &>/dev/null; then
    stdbuf -oL "${cmd[@]}" | while IFS= read -r line; do
      echo "$line" >> "$out"; update_last_urls "$out"; draw_dashboard
    done
  else
    "${cmd[@]}" | while IFS= read -r line; do
      echo "$line" >> "$out"; update_last_urls "$out"; draw_dashboard
    done
  fi
  local end=$(date +%s)
  STAGE_TIMES["$stage"]=$(( end - start ))
  STAGE_COUNTS["$stage"]=$( [ -f "$out" ] && wc -l < "$out" || echo 0 )
}

time_block(){
  local stage="$1"; shift; STAGE_ORDER+=("$stage")
  local start=$(date +%s); bash -c "$*"; local end=$(date +%s)
  STAGE_TIMES["$stage"]=$(( end - start ))
}

########################
# Pipeline (archives)
########################

# 0) subfinder
run_with_dashboard 0 "$SUBFINDER_OUT" subfinder -d "$DOMAIN" -silent

# 1) crt.sh
STEP=1; echo "[*] Querying crt.sh for $DOMAIN"
time_block "crt.sh" '
  curl -s "https://crt.sh/?q=%25.'"$DOMAIN"'&output=json" |
  grep -oP '"'"'"name_value":"[^"]+"'"'"' |
  sed -E '"'"'s/"name_value":"//;s/\\n/\n/g'"'"' |
  tr '"'"'[:upper:]'"'"' '"'"'[:lower:]'"'"' |
  sort -u > "'"$CRT_OUT"'"
'
update_last_urls "$CRT_OUT"; draw_dashboard
STAGE_COUNTS["crt.sh"]=$( [ -f "$CRT_OUT" ] && wc -l < "$CRT_OUT" || echo 0 )

# 2) amass passive
run_with_dashboard 2 "$AMASS_OUT" amass enum -passive -d "$DOMAIN"

# Merge
cat "$SUBFINDER_OUT" "$CRT_OUT" "$AMASS_OUT" | sort -u > "$COMBINED_SUBS"

# 3) filter
STEP=3
time_block "filter" '
  if [[ -f "'"$EXCLUDED_FILE"'" ]]; then
    grep -vFf "'"$EXCLUDED_FILE"'" "'"$COMBINED_SUBS"'" > "'"$FILTERED_DOMAINS"'"
  else
    cp "'"$COMBINED_SUBS"'" "'"$FILTERED_DOMAINS"'"
  fi
'
update_last_urls "$FILTERED_DOMAINS"; draw_dashboard
STAGE_COUNTS["filter"]=$( [ -f "$FILTERED_DOMAINS" ] && wc -l < "$FILTERED_DOMAINS" || echo 0 )

# 4) GAU (passive)
run_with_dashboard 4 "$GAU_RAW" bash -c "cat \"$FILTERED_DOMAINS\" | gau --subs || true"

# 5) Waybackurls (passive)
run_with_dashboard 5 "$WAYBACK_RAW" bash -c "cat \"$FILTERED_DOMAINS\" | waybackurls || true"

# 6) merge
STEP=6
time_block "merge (archive)" '
  cat "'"$GAU_RAW"'" "'"$WAYBACK_RAW"'" | sort -u > "'"$ARCHIVE_URLS"'"
  if command -v unfurl >/dev/null 2>&1; then
    cat "'"$GAU_RAW"'" | unfurl --unique keys > "'"$GAU_PARAMS"'"
    cat "'"$WAYBACK_RAW"'" | unfurl --unique keys > "'"$WAYBACK_PARAMS"'"
  else
    grep -oE "[?&][A-Za-z0-9_.-]+=" "'"$GAU_RAW"'"     | sed "s/^[?&]//;s/=$//" | sort -u > "'"$GAU_PARAMS"'"
    grep -oE "[?&][A-Za-z0-9_.-]+=" "'"$WAYBACK_RAW"'" | sed "s/^[?&]//;s/=$//" | sort -u > "'"$WAYBACK_PARAMS"'"
  fi
  cat "'"$GAU_PARAMS"'" "'"$WAYBACK_PARAMS"'" | sort -u > "'"$ARCHIVE_PARAMS"'"
'
update_last_urls "$ARCHIVE_URLS"; draw_dashboard
STAGE_COUNTS["merge (archive)"]=$( [ -f "$ARCHIVE_URLS" ] && wc -l < "$ARCHIVE_URLS" || echo 0 )

echo "[*] Archive URLs saved: $ARCHIVE_URLS"
echo "[*] Archive params saved: $ARCHIVE_PARAMS"
