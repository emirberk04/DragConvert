# Third-party software

DragConvert's own source code is MIT licensed (see [LICENSE](LICENSE)). This repository contains **no** third-party
source code or binaries. `scripts/build-ffmpeg.sh` downloads the projects below from their official release
locations, verifies their SHA-256 checksums against [`scripts/ffmpeg-sources.sha256`](scripts/ffmpeg-sources.sha256)
and builds them locally. If you build DragConvert.app and redistribute it, the following licences apply to the
bundled `Contents/Helpers` files.

| Component | Version | Licence | Source |
|---|---|---|---|
| FFmpeg (libavcodec, libavformat, libavfilter, libavutil, libswscale, libswresample, `ffmpeg`, `ffprobe`) | 9.0.2 | LGPL-2.1-or-later | https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz |
| LAME (MP3 encoder) | 3.100 | LGPL-2.0-or-later | https://sourceforge.net/projects/lame/ |
| libwebp | 1.6.0 | BSD-3-Clause | https://storage.googleapis.com/downloads.webmproject.org/releases/webp/ |
| libvpx (VP8/VP9) | 1.17.0 | BSD-3-Clause | https://github.com/webmproject/libvpx |
| Opus | 1.5.2 | BSD-3-Clause | https://github.com/xiph/opus |
| pkgconf (build tool only, not bundled) | 3.0.10 | ISC | https://distfiles.ariadne.space/pkgconf/ |

## How the LGPL obligations are met

- FFmpeg is built **without** `--enable-gpl` and `--enable-nonfree`; no GPL or non-free component is included.
- The FFmpeg libraries are shared libraries (`libav*.dylib`) next to the `ffmpeg` and `ffprobe` executables, so
  they can be replaced with a user-built version.
- The sources are unmodified upstream releases; the exact configure line is in `scripts/build-ffmpeg.sh`.
- LAME is linked into `libavcodec`, which is itself replaceable.

## System frameworks

DragConvert uses Apple frameworks that ship with macOS (AppKit, SwiftUI, ImageIO, Core Graphics, Core Image, PDFKit,
AVFoundation, VideoToolbox, AudioToolbox, Vision, ServiceManagement, UserNotifications). H.264, HEVC and AAC
encoding is done by Apple's VideoToolbox and AudioToolbox, not by FFmpeg.

## Trademarks

Microsoft Word, Excel and PowerPoint are trademarks of Microsoft Corporation. DragConvert only automates copies of
these apps that the user has installed, through their public AppleScript interfaces; it contains no Microsoft
code. macOS, Finder and AirDrop are trademarks of Apple Inc.
