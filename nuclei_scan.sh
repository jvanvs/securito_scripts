#!/bin/bash

# Check if domain is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <domain>"
  exit 1
fi

# Set variables
DOMAIN=$1
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.36"
X_FORWARDED_FOR="192.168.1.100"
COOKIE="cf_clearance=your_clearance_cookie_here"
RATE_LIMIT=10

# Run Nuclei with the specified parameters
nuclei -u "$DOMAIN" \
  -H "User-Agent: $USER_AGENT" \
  -H "X-Forwarded-For: $X_FORWARDED_FOR" \
  -H "Cookie: $COOKIE" \
  -rl "$RATE_LIMIT" \
  -fr

