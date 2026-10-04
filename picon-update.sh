#!/usr/bin/env bash
set -euo pipefail

### REPLACE THESE WITH YOUR ACTUAL SETTINGS ###

HDHR="http://${YOUR_HDHOMERUN_IP_OR_HOSTNAME}"
TVH="http://${YOUR_TVHEADEND_IP_OR_HOSTHANE:PORT}"
TVH_USER="${YOUR_TVHEADEND_USER}"
TVH_PASS="${YOUR_TVHEADEND_PASS}"

PICON_DIR="${/YOUR/PICON/DIRECTORY}"

### END REPLACEMENT ###
mkdir -p "$PICON_DIR"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

echo "Fetching HDHomeRun authentication..."
AUTH=$(
    curl -fsS "$HDHR/discover.json" |
    jq -r '.DeviceAuth'
)

if [[ -z "$AUTH" || "$AUTH" == "null" ]]; then
    echo "ERROR: Couldn't obtain DeviceAuth"
    exit 1
fi

echo "Fetching SiliconDust guide..."
curl -fsS \
    "https://api.hdhomerun.com/api/guide?DeviceAuth=${AUTH}&Duration=1" \
    -o "$tmpdir/guide.json"

echo "Fetching TVHeadend channels..."
curl --digest -fsS -u "${TVH_USER}:${TVH_PASS}" \
    "${TVH}/api/channel/grid?limit=10000" \
    -o "$tmpdir/tvh.json"

downloaded=0
existing=0
no_guide=0
no_image=0
