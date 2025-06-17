#!/bin/bash

#############
# VARIABLES #
#############

TODAY=$(date)
DOMAIN=$1
DIRECTORY=${DOMAIN}_recon
HTML_REPORT="$DIRECTORY/subdomains_report.html"
EXCLUDE_NMAP=false

# Parse flags
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --exclude-nmap) EXCLUDE_NMAP=true ;;
        *) DOMAIN=$1 ;;
    esac
    shift
done

#############
# FUNCTIONS #
#############

cleanup_and_setup(){
    rm -Rf $DIRECTORY
    echo "[ER] Creating directory $DIRECTORY"
    mkdir $DIRECTORY
}

logo(){
echo "
    ---- --  ---       ---   ---- --- ----     
    |   |  | |   | |   |  |  |    |   |  | |\  |
    ---- --  --- ---   |--|  |--  |   |  | | \ |
    |   |  |   |  |    |  \  |    |   |  | |  \|
    --- |  | ---  |    |   | ---  --- ---- |   |
      # Sept 2024
"
}

subfinder_scan(){
    echo "[ER] Running subfinder on $DOMAIN..."
    subfinder -d $DOMAIN -o $DIRECTORY/subfinder_raw.txt
    grep -E "\.${DOMAIN}$" "$DIRECTORY/subfinder_raw.txt" > "$DIRECTORY/subfinder.txt"
}

crt_scan() {
    echo "[ER] Running crt.sh scan on $DOMAIN..."
    curl -s "https://crt.sh/?q=$DOMAIN&output=json" -o "$DIRECTORY/crt"
    jq -r '.[] | .name_value' "$DIRECTORY/crt" | grep -E "\.${DOMAIN}$" > "$DIRECTORY/crt_results.txt"
}

merge_subdomain_lists(){
    cat $DIRECTORY/subfinder.txt $DIRECTORY/crt_results.txt | sort -u > $DIRECTORY/all_results.txt
}

check_responsive(){
    echo "[ER] Checking responsive subdomains..."
    cat $DIRECTORY/all_results.txt | httprobe -c 50 -t 3000 > $DIRECTORY/all_responsive.txt
}

nmap_scan() {
    local subdomain=$1
    echo "[ER] Running Nmap scan on $subdomain..."
    nmap -sV -oN "$DIRECTORY/nmap_$subdomain.txt" "$subdomain"
}

wafw00f_scan() {
    local url=$1
    local subdomain=$2
    echo "[ER] Running WafW00f on $url..."
    wafw00f "$url" > "$DIRECTORY/wafw00f_$subdomain.txt"
}

whatweb_scan() {
    local url=$1
    local subdomain=$2
    echo "[ER] Running WhatWeb on $url..."
    whatweb --log-json="$DIRECTORY/whatweb_$subdomain.json" "$url"
}

find_real_ip() {
    local subdomain=$1
    echo "[ER] Finding real IP for $subdomain..."
    dig +short "$subdomain" > "$DIRECTORY/ip_$subdomain.txt"
}


generate_html_report() {
    echo "[ER] Creating HTML report"

    # Start the HTML file with dark mode styling and interactive elements
    cat <<EOF > "$HTML_REPORT"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Subdomains report - $TODAY</title>
    <style>
        body {
            background-color: #1E1E1E;
            color: #FFFFFF;
            font-family: Arial, sans-serif;
        }
        h1 {
            color: #FFD700;
        }
        ul {
            list-style-type: none;
            padding: 0;
        }
        li {
            padding: 8px 0;
        }
        a {
            color: #64FFDA;
            text-decoration: none;
        }
        a:hover {
            text-decoration: underline;
        }
        .subdomain {
            margin-bottom: 20px;
        }
        .details {
            display: none;
            margin-left: 20px;
        }
    </style>
    <script>
        function toggleDetails(id) {
            var element = document.getElementById(id);
            if (element.style.display === "none") {
                element.style.display = "block";
            } else {
                element.style.display = "none";
            }
        }
    </script>
</head>
<body>
    <h1>Responsive subdomains for $DOMAIN</h1>
    <ul>
EOF

    # Read the input file line by line and generate detailed report
    while IFS= read -r url; do
        subdomain=$(echo $url | awk -F/ '{print $3}')
        safe_subdomain=$(echo $subdomain | sed 's/[^a-zA-Z0-9]/_/g')
        echo "        <li class=\"subdomain\"><a href=\"$url\" target=\"_blank\">$url</a> <button onclick=\"toggleDetails('details_$safe_subdomain')\">Toggle Details</button></li>" >> "$HTML_REPORT"
        echo "        <div id=\"details_$safe_subdomain\" class=\"details\">" >> "$HTML_REPORT"
        
        # Include Nmap results
        if [ -f "$DIRECTORY/nmap_$subdomain.txt" ]; then
            echo "            <h3>Nmap Scan</h3><pre>$(cat $DIRECTORY/nmap_$subdomain.txt)</pre>" >> "$HTML_REPORT"
        fi

        # Include WafW00f results
        if [ -f "$DIRECTORY/wafw00f_$safe_subdomain.txt" ]; then
            echo "            <h3>WafW00f</h3><pre>$(cat $DIRECTORY/wafw00f_$safe_subdomain.txt)</pre>" >> "$HTML_REPORT"
        fi

        # Include WhatWeb results
        if [ -f "$DIRECTORY/whatweb_$safe_subdomain.json" ]; then
            whatweb_output=$(cat "$DIRECTORY/whatweb_$safe_subdomain.json" | jq .)
            echo "            <h3>WhatWeb</h3><pre>$whatweb_output</pre>" >> "$HTML_REPORT"
        fi

        # Include Real IP
        if [ -f "$DIRECTORY/ip_$subdomain.txt" ]; then
            real_ip=$(cat "$DIRECTORY/ip_$subdomain.txt")
            echo "            <h3>Real IP</h3><pre>$real_ip</pre>" >> "$HTML_REPORT"
        fi

        echo "        </div>" >> "$HTML_REPORT"
    done < "$DIRECTORY/all_responsive.txt"

    # End the HTML file
    cat <<EOF >> "$HTML_REPORT"
    </ul>
</body>
</html>
EOF

    echo "[ER] HTML report generated: $HTML_REPORT"
}

################
# EXECUTION    #
################
cleanup_and_setup
logo
echo "[ER] Scan date: $TODAY"
subfinder_scan
crt_scan
merge_subdomain_lists
check_responsive

# Run additional scans on each responsive subdomain with progress messages
total_subdomains=$(wc -l < "$DIRECTORY/all_responsive.txt")
current_subdomain=0

while IFS= read -r url; do
    ((current_subdomain++))
    echo "[ER] Running extra scans on subdomain $current_subdomain/$total_subdomains: $url"
    subdomain=$(echo $url | awk -F/ '{print $3}')
    safe_subdomain=$(echo $subdomain | sed 's/[^a-zA-Z0-9]/_/g')

    # Run Nmap scan only if the flag to exclude it is not set
    if [ "$EXCLUDE_NMAP" = false ]; then
        nmap_scan "$subdomain"
    fi

    wafw00f_scan "$url" "$safe_subdomain"
    whatweb_scan "$url" "$safe_subdomain"
    find_real_ip "$subdomain"

done < "$DIRECTORY/all_responsive.txt"

generate_html_report
