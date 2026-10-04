#!/usr/bin/env bash
set -euo pipefail

### CONFIGURATION #############################################################

HDHR="http://${YOUR_HDHOMERUN_IP_OR_HOSTNAME}"
TVH="http://${YOUR_TVHEADEND_IP_OR_HOSTNAME:PORT}"

TVH_USER="${YOUR_TVHEADEND_USER}"
TVH_PASS="${YOUR_TVHEADEND_PASS}"

PICON_DIR="${YOUR/PICON/DIRECTORY}"

# Only required for --normalize. Prefer exporting these in the environment.
TVH_ADMIN_USER="${TVH_ADMIN_USER:-}"
TVH_ADMIN_PASS="${TVH_ADMIN_PASS:-}"

### END CONFIGURATION #########################################################

NORMALIZE=0
OVERWRITE=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [--overwrite] [--normalize]

Options:
  --overwrite   Replace existing picon artwork with current
                SiliconDust/HDHomeRun artwork.
  --normalize   Convert legacy file:// OTA icons to canonical
                TVHeadend picon:// icons. Requires TVH_ADMIN_USER
                and TVH_ADMIN_PASS.
  -h, --help    Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --overwrite) OVERWRITE=1 ;;
        --normalize) NORMALIZE=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if (( NORMALIZE )) && [[ -z "$TVH_ADMIN_USER" || -z "$TVH_ADMIN_PASS" ]]; then
    echo "ERROR: --normalize requires TVH_ADMIN_USER and TVH_ADMIN_PASS" >&2
    exit 1
fi

mkdir -p "$PICON_DIR"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

echo "Fetching HDHomeRun authentication..."
AUTH=$(curl -fsS "$HDHR/discover.json" | jq -r '.DeviceAuth')

if [[ -z "$AUTH" || "$AUTH" == "null" ]]; then
    echo "ERROR: Couldn't obtain DeviceAuth" >&2
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

if (( NORMALIZE )); then
    echo "Fetching TVHeadend services..."
    curl --digest -fsS -u "${TVH_ADMIN_USER}:${TVH_ADMIN_PASS}" \
        "${TVH}/api/mpegts/service/grid?limit=10000" \
        -o "$tmpdir/services.json"

    echo "Fetching TVHeadend multiplexes..."
    curl --digest -fsS -u "${TVH_ADMIN_USER}:${TVH_ADMIN_PASS}" \
        "${TVH}/api/mpegts/mux/grid?limit=10000" \
        -o "$tmpdir/muxes.json"
fi

downloaded=0
overwritten=0
existing=0
no_guide=0
no_image=0
local_icons=0
other_icons=0
normalized=0
normalize_failed=0

if (( NORMALIZE )); then
    echo
    echo "Normalizing local OTA icons..."

    while IFS=$'\t' read -r number name icon channel_uuid; do
        [[ "$icon" == file://* ]] || continue

        major=${number%%.*}
        if [[ "$number" == *.* ]]; then
            minor=${number#*.}
        else
            minor=0
        fi

        if [[ ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ ]]; then
            printf "%-7s %-25s cannot parse channel number\n" "$number" "$name"
            ((++normalize_failed))
            continue
        fi

        service=$(
            jq -c --argjson major "$major" --argjson minor "$minor" '
                [.entries[] |
                 select(.lcn == $major and (.lcn_minor // 0) == $minor)]
                | if length == 1 then .[0] else empty end
            ' "$tmpdir/services.json"
        )

        if [[ -z "$service" ]]; then
            printf "%-7s %-25s cannot uniquely match service\n" "$number" "$name"
            ((++normalize_failed))
            continue
        fi

        sid=$(jq -r '.sid // empty' <<<"$service")
        mux_uuid=$(jq -r '.multiplex_uuid // empty' <<<"$service")

        if [[ -z "$sid" || -z "$mux_uuid" ]]; then
            printf "%-7s %-25s service missing SID/mux\n" "$number" "$name"
            ((++normalize_failed))
            continue
        fi

        mux=$(
            jq -c --arg uuid "$mux_uuid" '
                [.entries[] | select(.uuid == $uuid)]
                | if length == 1 then .[0] else empty end
            ' "$tmpdir/muxes.json"
        )

        if [[ -z "$mux" ]]; then
            printf "%-7s %-25s cannot uniquely match mux\n" "$number" "$name"
            ((++normalize_failed))
            continue
        fi

        delsys=$(jq -r '.delsys // empty' <<<"$mux")
        tsid=$(jq -r '.tsid // empty' <<<"$mux")

        if [[ "$delsys" != "ATSC-T" ]]; then
            printf "%-7s %-25s skipping non-ATSC-T mux (%s)\n" \
                "$number" "$name" "${delsys:-unknown}"
            ((++normalize_failed))
            continue
        fi

        if [[ ! "$sid" =~ ^[0-9]+$ || ! "$tsid" =~ ^[0-9]+$ ]]; then
            printf "%-7s %-25s invalid SID/TSID\n" "$number" "$name"
            ((++normalize_failed))
            continue
        fi

        printf -v sid_hex '%X' "$sid"
        printf -v tsid_hex '%X' "$tsid"

        filename="1_0_0_${sid_hex}_${tsid_hex}_10000_DDDD0000_0_0_0.png"
        new_icon="picon://${filename}"

        printf "%-7s %-25s normalize:\n" "$number" "$name"
        printf "        %s\n" "$icon"
        printf "     -> %s\n" "$new_icon"

        node=$(
            jq -cn --arg uuid "$channel_uuid" --arg icon "$new_icon" \
                '{uuid:$uuid, icon:$icon}'
        )

        if curl --digest -fsS \
            -u "${TVH_ADMIN_USER}:${TVH_ADMIN_PASS}" \
            --data-urlencode "node=${node}" \
            "${TVH}/api/idnode/save" >/dev/null
        then
            ((++normalized))
        else
            echo "        ERROR: TVHeadend update failed"
            ((++normalize_failed))
        fi

    done < <(
        jq -r '
            .entries
            | map(select(.number != null))
            | sort_by(
                (.number | tostring | split(".")[0] | tonumber? // 999999999),
                (.number | tostring | split(".")[1] // "0" | tonumber? // 0)
              )
            | .[]
            | [(.number|tostring), (.name//""), (.icon//""), .uuid]
            | @tsv
        ' "$tmpdir/tvh.json"
    )

    echo
    echo "Normalization:"
    echo "  Normalized:          $normalized"
    echo "  Failed/skipped:      $normalize_failed"

    if (( normalized > 0 )); then
        echo
        echo "Refreshing TVHeadend channels..."
        curl --digest -fsS -u "${TVH_USER}:${TVH_PASS}" \
            "${TVH}/api/channel/grid?limit=10000" \
            -o "$tmpdir/tvh.json"
    fi
fi

echo
echo "Checking picon artwork..."

while IFS=$'\t' read -r number name icon; do
    if [[ "$icon" != picon://*.png ]]; then
        if [[ "$icon" == file://* ]]; then
            printf "%-7s %-25s local icon: %s\n" "$number" "$name" "$icon"
            ((++local_icons))
        else
            ((++other_icons))
        fi
        continue
    fi

    image_url=$(
        jq -r --arg num "$number" '
            .[] | select(.GuideNumber == $num) | .ImageURL // empty
        ' "$tmpdir/guide.json" | head -1
    )

    if [[ -z "$image_url" ]]; then
        if jq -e --arg num "$number" \
            '.[] | select(.GuideNumber == $num)' \
            "$tmpdir/guide.json" >/dev/null
        then
            printf "%-7s %-25s no artwork\n" "$number" "$name"
            ((++no_image))
        else
            printf "%-7s %-25s not in HDHomeRun guide\n" "$number" "$name"
            ((++no_guide))
        fi
        continue
    fi

    filename=${icon#picon://}
    dest="${PICON_DIR}/${filename}"

    if [[ -s "$dest" && "$OVERWRITE" -eq 0 ]]; then
        printf "%-7s %-25s exists: %s\n" "$number" "$name" "$filename"
        ((++existing))
        continue
    fi

    if [[ -s "$dest" ]]; then
        action="overwrite"
        printf "%-7s %-25s overwrite: %s\n" "$number" "$name" "$filename"
    else
        action="download"
        printf "%-7s %-25s -> %s\n" "$number" "$name" "$filename"
    fi

    if curl -fLsS "$image_url" -o "${dest}.tmp"; then
        mv "${dest}.tmp" "$dest"
        if [[ "$action" == "overwrite" ]]; then
            ((++overwritten))
        else
            ((++downloaded))
        fi
    else
        echo "        ERROR downloading $image_url"
        rm -f "${dest}.tmp"
    fi
done < <(
    jq -r '
        .entries
        | map(select(.number != null))
        | sort_by(
            (.number | tostring | split(".")[0] | tonumber? // 999999999),
            (.number | tostring | split(".")[1] // "0" | tonumber? // 0)
          )
        | .[]
        | [(.number|tostring), (.name//""), (.icon//"")]
        | @tsv
    ' "$tmpdir/tvh.json"
)

echo
echo "Finished:"
if (( NORMALIZE )); then
    echo "  Normalized:          $normalized"
    echo "  Normalize failures:  $normalize_failed"
fi
echo "  Downloaded:          $downloaded"
echo "  Overwritten:         $overwritten"
echo "  Already present:     $existing"
echo "  No HDHR guide match: $no_guide"
echo "  No HDHR artwork:     $no_image"
echo "  Local file icons:    $local_icons"
echo "  Other icons:         $other_icons"




































































































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
