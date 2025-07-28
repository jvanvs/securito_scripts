#!/bin/bash

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

function update_last_urls() {
    local file=$1
    mapfile -t lines < <(tail -n 5 "$file" 2>/dev/null)
    LAST_URLS=("${lines[@]}")
}

function update_url_count() {
    if [[ -f "$FINAL_URLS" ]]; then
        TOTAL_URLS=$(wc -l < "$FINAL_URLS")
    else
        TOTAL_URLS=0
    fi
}

function draw_dashboard() {
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

function run_with_dashboard() {
    STEP=$1
    output_file=$2
    shift 2
    local cmd=("$@")

    : > "$output_file"

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
}

# Step 0: subfinder
run_with_dashboard 0 "$SUBFINDER_OUT" subfinder -d "$DOMAIN" -silent

# Step 1: crt.sh
STEP=1
echo "[*] Querying crt.sh for $DOMAIN"
curl -s "https://crt.sh/?q=%25.$DOMAIN&output=json" |
    grep -oP '"name_value":"[^"]+"' |
    sed -E 's/"name_value":"//;s/\\n/\n/g' |
    tr '[:upper:]' '[:lower:]' |
    sort -u > "$CRT_OUT"
update_last_urls "$CRT_OUT"
draw_dashboard

# Combine subfinder + crt.sh
cat "$SUBFINDER_OUT" "$CRT_OUT" | sort -u > "$COMBINED_SUBS"

# Step 2: Filter excluded
STEP=2
if [[ -f "$EXCLUDED_FILE" ]]; then
    grep -vFf "$EXCLUDED_FILE" "$COMBINED_SUBS" > "$FILTERED_DOMAINS"
else
    cp "$COMBINED_SUBS" "$FILTERED_DOMAINS"
fi
update_last_urls "$FILTERED_DOMAINS"
draw_dashboard

# Step 3: httpx
run_with_dashboard 3 "$ACTIVE_DOMAINS" httpx -silent -l "$FILTERED_DOMAINS"

# Step 4: gau
run_with_dashboard 4 "$GAU_URLS" bash -c "cat $ACTIVE_DOMAINS | gau --subs | grep '='"

# Step 5: waybackurls
run_with_dashboard 5 "$WAYBACK_URLS" bash -c "cat $ACTIVE_DOMAINS | waybackurls | grep '='"

# Step 6: Merge URLs
STEP=6
cat "$GAU_URLS" "$WAYBACK_URLS" | sort -u > "$FINAL_URLS"
update_last_urls "$FINAL_URLS"
update_url_count
draw_dashboard

# Delta report
LAST_DIR=$(ls -dt results/*/ | grep -v "$TIMESTAMP" | head -n 1)
LAST_FINAL="$LAST_DIR/final_urls.txt"
if [[ -f "$LAST_FINAL" ]]; then
    echo "[*] Generating delta report..."
    comm -13 <(sort "$LAST_FINAL") <(sort "$FINAL_URLS") > "$DELTA_REPORT"
    echo "✅ Delta report saved to $DELTA_REPORT"
    echo "New URLs since last run: $(wc -l < "$DELTA_REPORT")"
else
    echo "[*] No previous run to compare for delta."
fi

# Cleanup old runs
echo -e "\n🧹 Cleaning up old results (keeping last 3)..."
ls -dt results/*/ | tail -n +4 | xargs -r rm -rf
echo "✅ Cleanup complete."

echo
echo "✅ Done! Results are in: $OUTPUT_DIR"
