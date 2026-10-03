# Generic HLS Wrapper

`generic-wrapper.py` is a lightweight HLS compatibility and normalization wrapper intended for IPTV applications such as Dispatcharr and TVHeadend.

It accepts an HLS master playlist, selects the highest-bandwidth video presentation, resolves its audio configuration, passes the HLS stream through VLC, and then uses FFmpeg to produce a normalized MPEG-TS stream on standard output.

The primary goal is to make troublesome HLS/FAST streams behave like boring, conventional MPEG-TS streams without unnecessarily transcoding the video.

## Architecture

The processing pipeline is:

```text
HLS master playlist
        |
        v
generic-wrapper.py
        |
        +-- Select highest-bandwidth video variant
        |
        +-- Resolve audio presentation
        |      |
        |      +-- Separate EXT-X-MEDIA audio rendition
        |      |
        |      `-- Muxed audio/video variant
        |
        v
       VLC
   HLS demuxing
        |
        v
     MPEG-TS
        |
        v
     FFmpeg
        |
        +-- H.264 video: stream copy
        |
        +-- Audio: decode and re-encode as AAC
        |
        +-- Repair/regenerate timestamps
        |
        +-- Normalize audio timing
        |
        +-- Rebuild MPEG-TS
        |
        v
      stdout
        |
        v
Dispatcharr / TVHeadend / other consumer
```

## Why VLC and FFmpeg?

Some HLS streams, particularly FAST television streams, can contain characteristics that expose bugs or limitations in downstream IPTV software.

Examples include:

- HLS discontinuities
- dynamic ad insertion
- separate audio renditions
- alternate or audio-description tracks
- irregular AAC timestamps
- timestamp discontinuities
- malformed or damaged audio packets
- unusual MPEG-TS transitions

VLC is used as the HLS client because it is generally tolerant of complicated live HLS playlists and discontinuities.

FFmpeg then acts as a stream normalizer.

The video is copied rather than re-encoded, avoiding unnecessary CPU/GPU usage and generation loss.

Audio is decoded and re-encoded as AAC because damaged or irregular source audio is one of the things the wrapper is specifically intended to repair.

## HLS Variant Selection

The wrapper downloads the supplied HLS master playlist and examines its `#EXT-X-STREAM-INF` entries.

The variant with the highest advertised `BANDWIDTH` is selected.

Relative playlist URLs are resolved against the URL of the master playlist.

## Audio Handling

HLS providers commonly package audio in one of two ways.

### Separate audio rendition

A video variant may reference an audio group:

```text
#EXT-X-STREAM-INF:...,AUDIO="audio"
```

The master playlist then contains one or more corresponding:

```text
#EXT-X-MEDIA:TYPE=AUDIO,...
```

entries.

When this occurs, the wrapper selects an audio rendition from the referenced group.

If a rendition has:

```text
DEFAULT=YES
```

it is preferred.

This is particularly useful with services that provide alternate audio tracks such as audio description.

### Muxed audio/video

Some providers put audio directly in the selected video variant and do not specify an `AUDIO` group.

In that case, the wrapper simply passes the selected variant to VLC without constructing a separate audio rendition.

This allows the same wrapper to work with both styles of HLS packaging.

## Stream Normalization

VLC converts the selected HLS presentation into MPEG-TS.

That stream is piped directly into FFmpeg.

The current FFmpeg processing strategy is approximately:

```text
Video:
    H.264 -> stream copy

Audio:
    source audio -> decode -> AAC 192 kbps

Timing:
    generate missing presentation timestamps
    discard corrupt packets
    asynchronously resample audio
    normalize initial timestamps

Output:
    MPEG-TS
```

Video is deliberately **not transcoded**.

This keeps CPU usage low and preserves the original video quality.

## MPEG-TS Layout

The wrapper emits a simple MPEG-TS service with stable stream IDs.

Current defaults are:

```text
Transport Stream ID: 1
Service ID:          1
Video PID:           256
Audio PID:           257
```

FFmpeg is also instructed to resend MPEG-TS headers as necessary.

The intent is to present downstream software with a predictable transport stream regardless of how the original provider packaged the HLS presentation.

## Process Lifecycle

A wrapper invocation normally creates three processes:

```text
generic-wrapper.py
    |
    +-- VLC
    |
    `-- FFmpeg
```

The Python process supervises VLC and FFmpeg and terminates them when the stream ends.

On Linux, child processes also use:

```text
PR_SET_PDEATHSIG
```

so that the kernel sends `SIGTERM` to VLC and FFmpeg if the Python parent unexpectedly disappears.

This is important for IPTV applications where clients frequently:

- change channels
- disconnect unexpectedly
- abort playback
- restart streams
- terminate worker processes

Without explicit process supervision, long-running IPTV servers can accumulate abandoned VLC or FFmpeg processes.

## Usage

The command-line syntax is:

```text
generic-wrapper.py STREAM_URL [USER_AGENT] [CHANNEL_ID]
```

For example:

```bash
./generic-wrapper.py \
    'https://example.com/master.m3u8' \
    'Example IPTV Client/1.0' \
    1234
```

MPEG-TS is written to standard output.

Diagnostic messages from the wrapper, VLC, and FFmpeg are written to standard error.

This distinction is important: **nothing other than MPEG-TS should be written to stdout.**

## Dispatcharr

The wrapper can be used as a Dispatcharr custom stream command.

A typical configuration passes:

```text
{streamUrl}
{userAgent}
{channelId}
```

to the script.

Conceptually:

```text
/path/to/generic-wrapper.py {streamUrl} {userAgent} {channelId}
```

The wrapper's stdout becomes the MPEG-TS stream consumed by Dispatcharr.

Exact configuration depends on the Dispatcharr version and deployment.

## Dependencies

The wrapper requires:

- Linux
- Python 3
- VLC / `cvlc`
- FFmpeg

The following commands should be available in the execution environment:

```bash
python3
cvlc
ffmpeg
```

If the wrapper is running inside a container, all three must be installed inside that container.

## Installation

Copy the script somewhere accessible to the IPTV application:

```bash
cp generic-wrapper.py /usr/local/bin/generic-wrapper
chmod 755 /usr/local/bin/generic-wrapper
```

Verify that it compiles:

```bash
python3 -m py_compile /usr/local/bin/generic-wrapper
```

## Debugging

To see active wrapper processes:

```bash
pgrep -af 'generic-wrapper|vlc|ffmpeg'
```

A running stream should normally resemble:

```text
python3 .../generic-wrapper.py ...
/usr/bin/vlc ...
ffmpeg ...
```

After the client disconnects or changes channels, the corresponding processes should terminate.

A brief overlap between old and new processes during a channel change can be normal while graceful shutdown completes.

Persistent VLC or FFmpeg processes whose parent has disappeared are not normal.

## Testing Manually

Because stdout contains binary MPEG-TS data, redirect it when testing from a shell.

For example:

```bash
./generic-wrapper.py \
    'https://example.com/master.m3u8' \
    'Mozilla/5.0' \
    test \
    > /tmp/test.ts
```

The resulting stream can then be inspected with:

```bash
ffprobe /tmp/test.ts
```

For a live test without creating a continuously growing file:

```bash
timeout 30 ./generic-wrapper.py \
    'https://example.com/master.m3u8' \
    'Mozilla/5.0' \
    test \
    > /tmp/test.ts
```

## Limitations

The wrapper currently expects the supplied URL to be an **HLS master playlist containing `#EXT-X-STREAM-INF` variants**.

It does not currently treat a direct HLS media playlist as an implicit single variant.

The wrapper also intentionally removes subtitle references from the synthetic HLS presentation. Subtitle streams are therefore not preserved.

The current stream mapping expects:

- one video stream
- one audio stream

More complicated multi-audio or multi-video presentations are intentionally reduced to a simple IPTV-friendly presentation.

## Design Goals

The wrapper favors predictable output over preserving every feature of the source presentation.

Its priorities are:

1. Keep the original video whenever possible.
2. Repair problematic audio and timing.
3. Tolerate live HLS discontinuities.
4. Produce simple, conventional MPEG-TS.
5. Minimize CPU usage.
6. Clean up every process when playback ends.

In short:

> Take weird Internet television and make it boring.
