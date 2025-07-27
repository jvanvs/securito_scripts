#!/bin/bash

# Require domain as first argument
if [[ -z "$1" ]]; then
    echo "Usage: $0 <domain>"
    exit 1
fi

DOMAIN="$1"
EXCLUDED_FILE="excluded.txt"
ACTIVE_DOMAINS="active_domains.txt"
FILTERED_DOMAINS="filtered.txt"
SUBFINDER_OUT="subfinder_out.txt"
GAU_URLS="urls_gau.txt"
WAYBACK_URLS="urls_wayback.txt"
FINAL_URLS="final_urls.txt"

# Tools list for dashboard
TOOLS=("subfinder" "httpx" "filter" "gau" "waybackurls" "final merge")

# Variables to track
STEP=0
TOTAL_URLS=0
LAST_URLS=()

# Update last URLs array with latest lines from file
function update_last_urls() {
    local file=$1
    mapfile -t lines < <(tail -n 5 "$file" 2>/dev/null)
    LAST_URLS=("${lines[@]}")
}

# Update total URLs count
function update_url_count() {
    if [[ -f "$FINAL_URLS" ]]; then
        TOTAL_URLS=$(wc -l < "$FINAL_URLS")
    else
        TOTAL_URLS=0
    fi
}

# Draw the ASCII dashboard
function draw_dashboard() {
    clear
    echo "=============================="
    echo "  Subdomain & URL Discovery   "
    echo "=============================="
    echo "Target Domain: $DOMAIN"
    echo "Current step: $STEP - ${TOOLS[$STEP]}"
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

# Run a command with dashboard updates
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

# Step 0: Run subfinder
run_with_dashboard 0 "$SUBFINDER_OUT" subfinder -d "$DOMAIN" -silent

# Step 1: Filter out excluded domains if file exists
STEP=1
if [[ -f "$EXCLUDED_FILE" ]]; then
    grep -vFf "$EXCLUDED_FILE" "$SUBFINDER_OUT" > "$FILTERED_DOMAINS"
else
    cp "$SUBFINDER_OUT" "$FILTERED_DOMAINS"
fi
update_last_urls "$FILTERED_DOMAINS"
draw_dashboard

# Step 2: Run httpx to get active domains
run_with_dashboard 2 "$ACTIVE_DOMAINS" httpx -silent -l "$FILTERED_DOMAINS"

# Step 3: Run gau
run_with_dashboard 3 "$GAU_URLS" bash -c "cat $ACTIVE_DOMAINS | gau --subs | grep '='"

# Step 4: Run waybackurls
run_with_dashboard 4 "$WAYBACK_URLS" bash -c "cat $ACTIVE_DOMAINS | waybackurls | grep '='"

# Step 5: Merge final URL list
cat "$GAU_URLS" "$WAYBACK_URLS" | sort -u > "$FINAL_URLS"
update_last_urls "$FINAL_URLS"
update_url_count
STEP=5
draw_dashboard

echo
echo "✅ Finished! Results saved in $FINAL_URLS"
