# TVHeadend Picon Updater

`picon-update` downloads channel artwork from the SiliconDust/HDHomeRun guide service and installs it as picons for existing TVHeadend channels.

It is intended for installations where TVHeadend already has channels configured with `picon://` icon references, but the corresponding image files are missing.

The script uses the TVHeadend channel number to match each channel against the SiliconDust guide and downloads the guide artwork into the appropriate picon filename.

## How It Works

The basic workflow is:

```text
HDHomeRun
    |
    +-- discover.json
    |       |
    |       `-- DeviceAuth
    |
    v
SiliconDust Guide API
    |
    +-- GuideNumber
    +-- ImageURL
    |
    |       match on channel number
    |
    v
TVHeadend API
    |
    +-- channel number
    +-- channel name
    +-- picon:// filename
    |
    v
Local picon directory
```

The script:

1. Queries the HDHomeRun device for its `DeviceAuth` value.
2. Uses that value to retrieve guide information from the SiliconDust guide API.
3. Retrieves the TVHeadend channel list through the TVHeadend API.
4. Examines channels that already have a `picon://` icon assignment.
5. Matches the TVHeadend channel number against SiliconDust's `GuideNumber`.
6. Retrieves the corresponding `ImageURL`.
7. Downloads the artwork using the filename already specified by TVHeadend.
8. Leaves existing picon files untouched.

The result is that TVHeadend's existing picon assignments begin resolving to actual artwork without modifying the channel configuration itself.

## Requirements

The script requires:

- Bash
- `curl`
- `jq`
- an HDHomeRun device
- TVHeadend
- access to the SiliconDust guide service
- write access to the TVHeadend picon directory

Verify the required command-line tools with:

```bash
command -v curl jq
```

## Configuration

The script contains several variables that must be configured for the local installation:

```bash
HDHR="http://${YOUR_HD_HOMERUN_IP_OR_HOSTNAME}"
TVH="http://${YOUR_TV_HEADEND_SERVER}:9981"

TVH_USER="${TVHEADEND_USER}"
TVH_PASS="${TVHEADEND_PASS}"

PICON_DIR="${YOUR/PICON/DIR}"
```

For example:

```bash
HDHR="http://hdhomerun.example.net"
TVH="http://tvheadend.example.net:9981"

TVH_USER="tv"
TVH_PASS="change-me"

PICON_DIR="/var/lib/tvheadend/picons"
```

The picon directory must correspond to the directory TVHeadend uses to resolve `picon://` URLs.

## TVHeadend Authentication

The script accesses:

```text
/api/channel/grid
```

using HTTP Digest authentication.

The configured TVHeadend user therefore needs permission to access the channel API.

Credentials are supplied to `curl` using:

```bash
curl --digest -u "${TVH_USER}:${TVH_PASS}"
```

For a private home installation, credentials may be placed directly in the script.

For a shared repository, credentials should **not** be committed to source control. Use environment variables, a configuration file excluded by `.gitignore`, or another credential-management mechanism instead.

## HDHomeRun Authentication

The script first requests:

```text
/discover.json
```

from the HDHomeRun device.

The response contains a `DeviceAuth` value:

```json
{
  "DeviceAuth": "..."
}
```

That token is then used to query the SiliconDust guide API.

If the script cannot obtain a valid `DeviceAuth`, it exits immediately rather than attempting to continue with incomplete guide information.

## SiliconDust Guide Data

Guide data is retrieved from:

```text
https://api.hdhomerun.com/api/guide
```

using the HDHomeRun's `DeviceAuth`.

The script requests a short guide interval because it is interested primarily in channel metadata and artwork rather than program listings.

For each channel, the useful fields are:

```text
GuideNumber
ImageURL
```

`GuideNumber` is used to identify the channel.

`ImageURL` identifies the artwork to download.

## Matching Channels

The important assumption made by this script is:

> The TVHeadend channel number corresponds to the SiliconDust `GuideNumber`.

For example:

```text
TVHeadend:

number = 8.1
name   = WFAA
icon   = picon://some_filename.png
```

and:

```text
SiliconDust:

GuideNumber = 8.1
ImageURL    = https://...
```

are considered the same channel.

The script does **not** attempt fuzzy matching based on channel names.

This is intentional. Channel names can vary considerably between TVHeadend, broadcast metadata, XMLTV sources, and SiliconDust.

Channel numbers provide a much more deterministic match for OTA television.

## Picon Selection

Only TVHeadend channels whose icon begins with:

```text
picon://
```

and ends in:

```text
.png
```

are processed.

For example:

```text
picon://1_0_0_1_B01_10000_DDDD0000_0_0_0.png
```

The `picon://` prefix is removed and the remaining filename is used directly:

```text
1_0_0_1_B01_10000_DDDD0000_0_0_0.png
```

If the configured picon directory is:

```text
/var/lib/tvheadend/picons
```

the downloaded image becomes:

```text
/var/lib/tvheadend/picons/1_0_0_1_B01_10000_DDDD0000_0_0_0.png
```

The script therefore does not need to understand or generate TVHeadend's picon naming scheme.

It simply honors the picon filename TVHeadend has already assigned to the channel.

## Existing Artwork

Existing non-empty picon files are not replaced.

The script checks:

```bash
[[ -s "$dest" ]]
```

before downloading artwork.

This makes it safe to run repeatedly without unnecessarily downloading the same images or overwriting manually supplied artwork.

To deliberately replace existing artwork, remove the corresponding picon file before running the script again.

## Safe Downloads

Artwork is initially downloaded to a temporary filename:

```text
filename.png.tmp
```

Only after `curl` successfully completes is the file renamed to its final picon filename.

This prevents an interrupted or failed download from leaving behind a partial file that would subsequently be mistaken for valid artwork.

## Usage

Make the script executable:

```bash
chmod +x picon-update
```

Then run it:

```bash
./picon-update
```

The script prints the result for each relevant channel.

Example output might look like:

```text
8.1     WFAA                      -> 1_0_0_1_B01_10000_DDDD0000_0_0_0.png
11.1    KTVT                      exists: 1_0_0_2_B01_10000_DDDD0000_0_0_0.png
21.1    KTXA                      no artwork
27.1    KDFI                      not in HDHomeRun guide
```

## Summary

At completion, the script prints statistics similar to:

```text
Finished:
  Downloaded:          59
  Already present:     1
  No HDHR guide match: 16
  No HDHR artwork:     9
  Not a picon:         347
```

The categories mean:

| Result | Meaning |
|---|---|
| `Downloaded` | A matching guide entry and artwork were found and the picon was downloaded. |
| `Already present` | The expected picon file already exists and is non-empty. |
| `No HDHR guide match` | No SiliconDust guide entry has the same channel number. |
| `No HDHR artwork` | The channel exists in the SiliconDust guide but has no `ImageURL`. |
| `Not a picon` | The TVHeadend channel does not currently have a compatible `picon://...png` icon assignment. |

## Temporary Files

Guide and TVHeadend API responses are stored in a temporary directory created with:

```bash
mktemp -d
```

A shell trap removes the directory when the script exits:

```bash
trap 'rm -rf "$tmpdir"' EXIT
```

This includes normal completion and most error exits.

## Error Handling

The script uses:

```bash
set -euo pipefail
```

This causes it to stop when:

- a command unexpectedly fails
- an undefined variable is referenced
- a command in a pipeline fails

Individual artwork downloads are handled separately so that failure to download one channel logo does not prevent the script from attempting the remaining channels.

## Limitations

The script is primarily designed for **HDHomeRun/OTA channels** represented in both TVHeadend and the SiliconDust guide.

It does not attempt to obtain artwork for arbitrary IPTV or FAST channels that are not represented in the HDHomeRun guide.

It also depends on channel-number agreement between TVHeadend and SiliconDust. If a channel has been assigned a different number in TVHeadend, it will not match automatically.

The script does not:

- create TVHeadend picon assignments
- modify TVHeadend channels
- generate picon filenames
- replace existing artwork
- fuzzy-match channels by name
- retrieve artwork for arbitrary IPTV channels

Its job is deliberately narrow:

> Find missing files for picon assignments TVHeadend already knows about, using SiliconDust's guide artwork as the source.

## Automation

Because existing artwork is left untouched, the script can safely be run periodically.

For example, from cron:

```cron
17 4 * * 0 /usr/local/bin/picon-update
```

This example runs the updater once per week.

Periodic execution can pick up artwork for newly added TVHeadend channels without repeatedly downloading existing picons.

## Troubleshooting

To verify that the HDHomeRun is reachable:

```bash
curl -s "$HDHR/discover.json" | jq .
```

To inspect the TVHeadend channel API:

```bash
curl --digest -s \
    -u "${TVH_USER}:${TVH_PASS}" \
    "${TVH}/api/channel/grid?limit=10000" |
jq .
```

To find a particular channel in the SiliconDust guide data:

```bash
jq --arg num "8.1" '
    .[] |
    select(.GuideNumber == $num)
' guide.json
```

If artwork was downloaded successfully but does not appear in TVHeadend, verify:

1. `PICON_DIR` points to the directory TVHeadend actually uses for picons.
2. The TVHeadend process can read the downloaded files.
3. The channel's icon value is the expected `picon://` filename.
4. TVHeadend or the client does not have an older icon cached.
