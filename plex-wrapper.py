#!/usr/bin/env python3

import os
import subprocess
import sys
import urllib.parse
import urllib.request
import re
import tempfile


DEFAULT_USER_AGENT = "Mozilla/5.0"


def log(message):
    # NEVER log to stdout. Dispatcharr expects MPEG-TS there.
    print(message, file=sys.stderr, flush=True)



def attr(line, name):
    """
    Return an HLS attribute value, quoted or unquoted.
    """
    m = re.search(
        rf'(?:^|,){re.escape(name)}=(?:"([^"]*)"|([^,]*))',
        line.split(":", 1)[1]
    )
    if not m:
        return None
    return m.group(1) if m.group(1) is not None else m.group(2)


def absolute_media_uri(line, master_url):
    """
    Rewrite URI="..." in EXT-X-MEDIA to an absolute URL.
    """
    m = re.search(r'URI="([^"]+)"', line)
    if not m:
        return line

    absolute = urllib.parse.urljoin(master_url, m.group(1))
    return line[:m.start(1)] + absolute + line[m.end(1):]


def get_best_presentation(source_url, user_agent):
    req = urllib.request.Request(
        source_url,
        headers={"User-Agent": user_agent}
    )

    with urllib.request.urlopen(req, timeout=15) as response:
        master_url = response.geturl()
        master = response.read().decode("utf-8")

    lines = master.splitlines()

    best_bandwidth = -1
    best_stream_inf = None
    best_video_uri = None

    for i, line in enumerate(lines):
        if not line.startswith("#EXT-X-STREAM-INF:"):
            continue

        bandwidth = attr(line, "BANDWIDTH")

        try:
            bandwidth = int(bandwidth)
        except (TypeError, ValueError):
            continue

        # URI is the next non-comment, non-empty line.
        uri = None

        for candidate in lines[i + 1:]:
            candidate = candidate.strip()

            if not candidate:
                continue

            if candidate.startswith("#"):
                continue

            uri = candidate
            break

        if uri is not None and bandwidth > best_bandwidth:
            best_bandwidth = bandwidth
            best_stream_inf = line
            best_video_uri = urllib.parse.urljoin(master_url, uri)

    if best_stream_inf is None:
        raise RuntimeError("No HLS video variants found")
    audio_group = attr(best_stream_inf, "AUDIO")

    if not audio_group:
    # Plex/Pluto streams may carry audio directly in the selected
    # video rendition rather than using a separate EXT-X-MEDIA
    # AUDIO group.
        log(
            f"Selected variant has no AUDIO group; "
            f"using muxed A/V variant: {best_video_uri}"
        )

        synthetic = "\n".join([
            "#EXTM3U",
            "#EXT-X-VERSION:5",
            best_stream_inf,
            best_video_uri,
            "",
        ])

        return synthetic, best_bandwidth

    # Find audio renditions belonging to this video variant.
    audio_candidates = []

    for line in lines:
        if not line.startswith("#EXT-X-MEDIA:"):
            continue

        if attr(line, "TYPE") != "AUDIO":
            continue

        if attr(line, "GROUP-ID") != audio_group:
            continue

        audio_candidates.append(line)

    if not audio_candidates:
        raise RuntimeError(
            f"No audio renditions found for AUDIO group {audio_group!r}"
        )

    # Prefer DEFAULT=YES. This avoids accidentally selecting
    # Pluto's audio-description rendition.
    audio_line = next(
        (
            line for line in audio_candidates
            if attr(line, "DEFAULT") == "YES"
        ),
        audio_candidates[0],
    )

    audio_line = absolute_media_uri(audio_line, master_url)

    #
    # Build one-video / one-audio master.
    #
    # Remove SUBTITLES because we intentionally aren't carrying them.
    #
    stream_inf = re.sub(
        r',SUBTITLES="[^"]*"',
        '',
        best_stream_inf
    )

    synthetic = "\n".join([
        "#EXTM3U",
        "#EXT-X-VERSION:5",
        audio_line,
        stream_inf,
        best_video_uri,
        "",
    ])

    return synthetic, best_bandwidth


def main():
    if len(sys.argv) < 2:
        print(
            f"Usage: {sys.argv[0]} STREAM_URL [USER_AGENT] [CHANNEL_ID]",
            file=sys.stderr,
        )
        return 2

    source_url = sys.argv[1]

    user_agent = (
        sys.argv[2]
        if len(sys.argv) >= 3 and sys.argv[2]
        else DEFAULT_USER_AGENT
    )

    channel_id = (
        sys.argv[3]
        if len(sys.argv) >= 4
        else "unknown"
    )

    vlc = None
    ffmpeg = None
    synthetic_path = None

    try:
        synthetic_master, bandwidth = get_best_presentation(
            source_url,
            user_agent,
        )

        log(f"{channel_id}: selected bandwidth {bandwidth}")

        with tempfile.NamedTemporaryFile(
            mode="w",
            suffix=".m3u8",
            prefix="pluto-",
            delete=False,
        ) as f:
            synthetic_path = f.name
            f.write(synthetic_master)

        log(f"{channel_id}: starting VLC")

        vlc_cmd = [
            "cvlc",
            "-I", "dummy",
            synthetic_path,
            f"--http-user-agent={user_agent}",
            "--no-spu",
            "--no-video-title-show",
            "--sout",
            "#standard{access=fd,mux=ts,dst=1}",
        ]

        vlc = subprocess.Popen(
            vlc_cmd,
            stdout=subprocess.PIPE,
            stderr=sys.stderr,
            bufsize=0,
        )

        ffmpeg_cmd = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel", "info",

            "-analyzeduration", "5000000",
            "-probesize", "5000000",

            "-i", "pipe:0",

            "-map", "0:v:0",
            "-map", "0:a:0",

            "-c", "copy",

            "-mpegts_transport_stream_id", "1",
            "-mpegts_service_id", "1",

            # Keep elementary-stream PIDs stable.
            "-streamid", "0:256",
            "-streamid", "1:257",

            # Re-emit PAT/PMT when the muxer needs to resend headers.
            "-mpegts_flags", "+resend_headers",

            "-metadata", "service_provider=Pluto",
            "-metadata", "service_name=Pluto TV",

            "-f", "mpegts",
            "pipe:1",
        ]


        log(f"{channel_id}: starting FFmpeg normalizer")

        ffmpeg = subprocess.Popen(
            ffmpeg_cmd,
            stdin=vlc.stdout,

            # Dispatcharr consumes FFmpeg's MPEG-TS directly.
            stdout=sys.stdout.buffer,

            stderr=sys.stderr,
            bufsize=0,
        )

        vlc.stdout.close()

        return ffmpeg.wait()


    except KeyboardInterrupt:
        return 130

    except Exception as exc:
        log(f"{channel_id}: ERROR: {exc}")
        return 1

    finally:
        if ffmpeg is not None and ffmpeg.poll() is None:
            ffmpeg.terminate()

            try:
                ffmpeg.wait(timeout=5)
            except subprocess.TimeoutExpired:
                ffmpeg.kill()
                ffmpeg.wait()

        if vlc is not None and vlc.poll() is None:
            vlc.terminate()

            try:
                vlc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                vlc.kill()
                vlc.wait()

        if synthetic_path is not None:
            try:
                os.unlink(synthetic_path)
            except FileNotFoundError:
                pass


if __name__ == "__main__":
    sys.exit(main())
