# iptv-stuff

A collection of tools, scripts, notes, and assorted hacks for working with IPTV, FAST channels, HLS streams, TVHeadend, Dispatcharr, and related software.

This repository exists primarily as a home for small utilities that are useful enough to keep, document, and share, but don't necessarily justify individual repositories.

## Contents

### Stream Processing
<!-- add links to stuff -->
- [Generic HLS Wrapper](generic-wrapper.md)  
  A lightweight HLS compatibility wrapper using VLC and FFmpeg. It selects the highest-bandwidth HLS variant, handles both muxed and separate audio renditions, and produces a normalized MPEG-TS stream suitable for IPTV applications such as Dispatcharr and TVHeadend.

### TVHeadend Utilities

- [TVHeadend Picon Updater](picon-update.md)  
  Downloads missing picon artwork for TVHeadend OTA channels by matching TVHeadend channel numbers against the SiliconDust/HDHomeRun guide.

<!-- end add links to stuff -->

## Requirements

Requirements vary by utility. See the documentation for each individual tool.

Common software used by scripts in this repository may include:

- Python 3
- FFmpeg
- VLC
- TVHeadend
- Dispatcharr

## Philosophy

Most of the tools here are intended to solve practical interoperability problems rather than provide a complete IPTV platform.

In particular, FAST and IPTV providers frequently produce streams that are technically valid but expose differences in HLS packaging, timestamps, discontinuities, audio renditions, or MPEG-TS behavior that downstream software does not always handle gracefully.

Where possible, these tools try to:

- preserve the original video without transcoding
- minimize CPU usage
- normalize problematic parts of a stream only when necessary
- produce conventional MPEG-TS output for downstream applications
- fail cleanly rather than leave abandoned processes behind

## Disclaimer

These tools do not provide television channels, playlists, subscription services, or copyrighted content.

They operate on stream URLs supplied by the user.

You are responsible for ensuring that your use of any stream or service complies with its terms of service and applicable law.

## License

See the repository license for details.
