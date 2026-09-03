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

# One Level 2 volume, from KICX Cedar City: the highest radar in the network,
# and so the site where the antenna altitude matters most and where getting it
# wrong is most visible. tests/level2_test.rs reads its site block.
#
# A few megabytes rather than the few kilobytes above, hence a separate fetch
# and its own skip -- a Level 2 volume is a whole scan of every moment.
L2_BUCKET="https://unidata-nexrad-level2.s3.amazonaws.com"
l2_latest() {
  local day
  for back in 0 1; do
    day=$(date -u -d "-$back day" +%Y/%m/%d 2>/dev/null) || day=$(date -u +%Y/%m/%d)
    curl -s "$L2_BUCKET/?list-type=2&prefix=$day/$1/&max-keys=400" \
      | grep -o '<Key>[^<]*</Key>' | sed 's/<[^>]*>//g' \
      | grep -v '_MDM$' | tail -1 | grep . && return 0
  done
  return 1
}

if key=$(l2_latest KICX); then
  echo "fetching $key"
  curl -s -o "testdata/latest_l2_kicx" "$L2_BUCKET/$key"
else
  echo "no KICX Level 2 volume found in the last two days (UTC)" >&2
fi
