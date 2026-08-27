#!/bin/sh
# Run inside browserless container to screenshot HTML files
# Usage: sh screenshot-receipts.sh <token> <html_file> <output_jpg>

TOKEN="$1"
HTML_FILE="$2"
OUTPUT_FILE="$3"

curl -s -X POST "http://localhost:3003/screenshot?token=${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$(cat <<EOF | tr -d '\n'
{"html":$(cat "$HTML_FILE" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),"options":{"type":"jpeg","quality":80,"fullPage":true}}
EOF
)" \
  --output "$OUTPUT_FILE"
