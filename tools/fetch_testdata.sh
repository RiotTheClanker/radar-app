#!/usr/bin/env bash
# Fetch sample Level 3 data for decoder tests into tools/testdata/.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p testdata

BUCKET="https://unidata-nexrad-level3.s3.amazonaws.com"
DAY=$(date -u +%Y_%m_%d)

latest() {
  curl -s "$BUCKET/?list-type=2&prefix=TLX_$1_$DAY&max-keys=1000" \
    | grep -o '<Key>[^<]*</Key>' | tail -1 | sed 's/<[^>]*>//g'
}

for prod in N0B N0G; do
  key=$(latest "$prod")
  if [ -n "$key" ]; then
    echo "fetching $key"
    curl -s -o "testdata/latest_$prod" "$BUCKET/$key"
  else
    echo "no $prod data found for today (UTC)" >&2
  fi
done
