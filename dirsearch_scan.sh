#!/bin/bash

# Check if the user provided a domain
if [ -z "$1" ]; then
    echo "Usage: $0 <domain>"
    exit 1
fi

# Domain to scan (passed as a parameter)
DOMAIN=$1

# Default configuration values
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.36"
X_FORWARDED_FOR="192.168.1.100"
THREADS=25
DELAY=3
COOKIE="cf_clearance=example_cookie_value"
EXCLUDE_STATUS="403,429"

# Command to run Dirsearch with the specified options
dirsearch -u "$DOMAIN" \
  --user-agent "$USER_AGENT" \
  --header "X-Forwarded-For: $X_FORWARDED_FOR" \
  -t "$THREADS" \
  --delay="$DELAY" \
  --follow-redirects \
  --cookie "$COOKIE" \
  --exclude-status="$EXCLUDE_STATUS"


