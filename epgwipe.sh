#!/usr/bin/env bash
set -euo pipefail

## Destroy all epg associations if you've messed around
## and have garbage ones.
jq -r '
  .entries[]
  | (.number | tostring) as $n
  | select($n | test("^[0-9]+$"))
  | select(($n | tonumber) >= 500)
  | select((.epggrab // []) | length > 0)
  | [.uuid, .number, .name]
  | @tsv
' /tmp/tvh-channels-before-fast-epg-reset.json |
while IFS=$'\t' read -r uuid number name; do
    printf '%-6s %-45s ' "$number" "$name"

    if curl --fail --digest -s \
      -u "${TVH_ADMIN_USER}:${TVH_ADMIN_PASS}" \
      --data-urlencode "node={\"uuid\":\"${uuid}\",\"epggrab\":[]}" \
      'http://tvheadend.dna.nurgle.net:9981/api/idnode/save' \
      >/dev/null
    then
        echo "cleared"
    else
        echo "FAILED"
    fi
done
