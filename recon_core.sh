#!/bin/bash
set -euo pipefail

# --- Optional Slack notifications ---
# To enable, export your webhook before running:
# export SLACK_WEBHOOK="https://hooks.slack.com/services/XXXX/YYYY/ZZZZ"

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <domain>"
  exit 1
fi

DOMAIN="$1"
EXCLUDED_FILE="excluded.txt"

# Ask for rate-limits/threads interactively (press Enter for defaults)
echo -n "👉 Enter allowed rate for httpx (requests/sec) [default 1]: "
read USER_RATE
RATE="${USER_RATE:-1}"

echo -n "👉 Enter httpx threads [default 1]: "
read USER_THREADS
THREADS="${USER_THREADS:-1}"

echo -n "👉 Enter Aquatone input rate (lines/sec to stdin) [default 1]: "
read USER_AQ_RATE
AQ_RATE="${USER_AQ_RATE:-1}"

echo -n "👉 Enter Aquatone threads [default 1]: "
read USER_AQ_THREADS
AQ_THREADS="${USER_AQ_THREADS:-1}"

TIMEOUT="${TIMEOUT:-12}"
RETRIES="${RETRIES:-2}"
AQ_HTTP_TIMEOUT="${AQ_HTTP_TIMEOUT:-12}"
AQ_SCREENSHOT_TIMEOUT="${AQ_SCREENSHOT_TIMEOUT:-20}"

echo "✅ Applied: httpx RATE=$RATE THREADS=$THREADS | Aquatone RATE=$AQ_RATE THREADS=$AQ_THREADS"

# Layout: <cwd>/<DOMAIN>/<TIMESTAMP>/
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DOMAIN_DIR="$(pwd)/$DOMAIN"
OUTPUT_DIR="$DOMAIN_DIR/$TIMESTAMP"
mkdir -p "$OUTPUT_DIR"

# Outputs
SUBFINDER_OUT="$OUTPUT_DIR/subfinder_out.txt"
CRT_OUT="$OUTPUT_DIR/crtsh_out.txt"
COMBINED_SUBS="$OUTPUT_DIR/combined_subs.txt"
FILTERED_DOMAINS="$OUTPUT_DIR/filtered.txt"
ACTIVE_DOMAINS="$OUTPUT_DIR/active_domains.txt"
FINAL_URLS="$OUTPUT_DIR/final_urls.txt"     # kept for compatibility (not used in core)
DELTA_REPORT="$OUTPUT_DIR/delta_report.txt"
AQUA_OUT_DIR="$OUTPUT_DIR/aquatone"

# Steps (amass removed)
TOOLS=("subfinder" "crt.sh" "filter" "httpx (rate-limited)" "aquatone (ports small, rate-limited)")
TOTAL_STEPS=${#TOOLS[@]}
STEP=0; TOTAL_URLS=0; LAST_LINES=()

declare -A STAGE_TIMES STAGE_COUNTS
declare -a STAGE_ORDER
SCRIPT_START=$(date +%s)

human_time(){ local s="$1"; printf '%dm %02ds' $((s/60)) $((s%60)); }

notify_summary(){
  local elapsed=$(( $(date +%s) - SCRIPT_START ))
  local lines=()
  lines+=("Recon core finished for ${DOMAIN} ✅")
  lines+=("Output dir: ${OUTPUT_DIR}")
  lines+=("Total time: $(human_time "$elapsed")")
  lines+=("")
  lines+=("Per stage (entries · duration):")
  for s in "${STAGE_ORDER[@]}"; do
    local c="${STAGE_COUNTS[$s]:-0}"
    local t="${STAGE_TIMES[$s]:-0}"
    lines+=("• ${s}: ${c} · $(human_time "$t")")
  done
  lines+=("")
  lines+=("Active hosts: $( [ -f "$ACTIVE_DOMAINS" ] && wc -l < "$ACTIVE_DOMAINS" || echo 0 )")

  local msg; msg="$(printf "%s\n" "${lines[@]}")"

  # Slack (optional)
  if [[ -n "${SLACK_WEBHOOK:-}" ]]; then
    if command -v jq >/dev/null 2>&1; then
      curl -sS -X POST -H 'Content-type: application/json' \
        --data "$(jq -Rn --arg text "$msg" '{text:$text}')" \
        "$SLACK_WEBHOOK" >/dev/null || true
    else
      echo "[!] jq not found; skipping Slack notification."
    fi
  fi

  echo; echo "$msg"; echo
}
trap 'notify_summary' EXIT

update_last_lines(){ local f=$1; mapfile -t lines < <(tail -n 5 "$f" 2>/dev/null || true); LAST_LINES=("${lines[@]}"); }
update_url_count(){ TOTAL_URLS=0; } # not used in core
draw_dashboard(){
  clear
  local percent=$(( (100 * STEP) / (TOTAL_STEPS - 1) ))
  echo "=============================="
  echo "  Recon Core (no archives)"
  echo "=============================="
  echo "Target:  $DOMAIN"
  echo "Output:  $DOMAIN_DIR"
  echo "Progress: Step $STEP / $((TOTAL_STEPS - 1)) - ${TOOLS[$STEP]}"
  echo "Progress: $percent%"
  echo "------------------------------"
  echo "Last 5 output lines:"
  for l in "${LAST_LINES[@]}"; do echo "  $l"; done
  echo "------------------------------"
  echo "Executed so far:"
  for ((i=0;i<=STEP;i++)); do echo "  - ${TOOLS[i]}"; done
  echo "=============================="
}

run_with_dashboard(){
  STEP=$1; local out=$2; shift 2; local cmd=("$@")
  local stage="${TOOLS[$STEP]}"; STAGE_ORDER+=("$stage")
  : > "$out"; local start=$(date +%s)
  if command -v stdbuf &>/dev/null; then
    stdbuf -oL "${cmd[@]}" | while IFS= read -r line; do
      echo "$line" >> "$out"; update_last_lines "$out"; update_url_count; draw_dashboard
    done
  else
    "${cmd[@]}" | while IFS= read -r line; do
      echo "$line" >> "$out"; update_last_lines "$out"; update_url_count; draw_dashboard
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

########################################
# Pipeline
########################################

# 0) subfinder (passive)
run_with_dashboard 0 "$SUBFINDER_OUT" subfinder -d "$DOMAIN" -silent

# 1) crt.sh (passive)
STEP=1; echo "[*] Querying crt.sh for $DOMAIN"
time_block "crt.sh" '
  curl -s "https://crt.sh/?q=%25.'"$DOMAIN"'&output=json" |
  grep -oP '"'"'"name_value":"[^"]+"'"'"' |
  sed -E '"'"'s/"name_value":"//;s/\\n/\n/g'"'"' |
  tr '"'"'[:upper:]'"'"' '"'"'[:lower:]'"'"' |
  sort -u > "'"$CRT_OUT"'"
'
update_last_lines "$CRT_OUT"; draw_dashboard
STAGE_COUNTS["crt.sh"]=$( [ -f "$CRT_OUT" ] && wc -l < "$CRT_OUT" || echo 0 )

# Merge discovery (amass removed)
cat "$SUBFINDER_OUT" "$CRT_OUT" | sort -u > "$COMBINED_SUBS"

# 2) filter (local)
STEP=2
time_block "filter" '
  if [[ -f "'"$EXCLUDED_FILE"'" ]]; then
    grep -vFf "'"$EXCLUDED_FILE"'" "'"$COMBINED_SUBS"'" > "'"$FILTERED_DOMAINS"'"
  else
    cp "'"$COMBINED_SUBS"'" "'"$FILTERED_DOMAINS"'"
  fi
'
update_last_lines "$FILTERED_DOMAINS"; draw_dashboard
STAGE_COUNTS["filter"]=$( [ -f "$FILTERED_DOMAINS" ] && wc -l < "$FILTERED_DOMAINS" || echo 0 )

# 3) httpx (ACTIVE, rate-limited)
run_with_dashboard 3 "$ACTIVE_DOMAINS" \
  httpx -silent -l "$FILTERED_DOMAINS" \
        -rl "$RATE" -threads "$THREADS" \
        -timeout "$TIMEOUT" -retries "$RETRIES" \
        -follow-redirects

# 4) Aquatone (ACTIVE) on ACTIVE_DOMAINS, ports small, with input throttle
mkdir -p "$AQUA_OUT_DIR"

STEP=4
STAGE_ORDER+=("aquatone (ports small, rate-limited)")
start_aq=$(date +%s)
AQUA_INPUT_COUNT=$( [ -f "$ACTIVE_DOMAINS" ] && wc -l < "$ACTIVE_DOMAINS" || echo 0 )

if [[ -s "$ACTIVE_DOMAINS" ]]; then
  if [[ "$AQ_RATE" -gt 0 ]]; then
    # Feed aquatone at AQ_RATE lines/sec via stdin
    awk -v r="$AQ_RATE" '{print; fflush(); if (r>0) system("sleep " 1.0/r)}' "$ACTIVE_DOMAINS" | \
      aquatone -out "$AQUA_OUT_DIR" -ports small \
               -threads "$AQ_THREADS" \
               -http-timeout "$AQ_HTTP_TIMEOUT" \
               -screenshot-timeout "$AQ_SCREENSHOT_TIMEOUT" \
               -silent || true
  else
    cat "$ACTIVE_DOMAINS" | \
      aquatone -out "$AQUA_OUT_DIR" -ports small \
               -threads "$AQ_THREADS" \
               -http-timeout "$AQ_HTTP_TIMEOUT" \
               -screenshot-timeout "$AQ_SCREENSHOT_TIMEOUT" \
               -silent || true
  fi
else
  echo "[*] Aquatone skipped: no ACTIVE_DOMAINS." > "$AQUA_OUT_DIR/_skipped.txt"
fi
end_aq=$(date +%s)
STAGE_TIMES["aquatone (ports small, rate-limited)"]=$(( end_aq - start_aq ))
STAGE_COUNTS["aquatone (ports small, rate-limited)"]="$AQUA_INPUT_COUNT"

# Delta (kept for compatibility; FINAL_URLS not populated in core)
LAST_DIR=$(ls -dt "$DOMAIN_DIR"/*/ 2>/dev/null | grep -v "$TIMESTAMP" | head -n 1 || true)
LAST_FINAL="${LAST_DIR%/}/final_urls.txt"
if [[ -n "${LAST_DIR:-}" && -f "$LAST_FINAL" ]]; then
  echo "[*] Generating delta report (note: no final_urls in core)..."
  : > "$DELTA_REPORT"
  echo "✅ Delta report saved to $DELTA_REPORT"
else
  echo "[*] No previous run to compare for delta (core)."
fi

# Cleanup: keep last 10 runs for THIS domain
echo -e "\n🧹 Cleaning up old results for ${DOMAIN} (keeping last 10)..."
ls -dt "$DOMAIN_DIR"/*/ 2>/dev/null | tail -n +11 | xargs -r rm -rf
echo "✅ Cleanup complete."
