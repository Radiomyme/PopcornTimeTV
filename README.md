<p align="left">
  <img src="https://imgur.com/a/DKPGO3i" alt="Popcorn Time" title="Popcorn Time">
</p>

# PopcornTimeTV — modernized fork

[![Version](https://img.shields.io/badge/version-5.0.0-blue.svg?style=flat)](https://github.com/Radiomyme/PopcornTimeTV/releases)
[![Platform](http://img.shields.io/badge/platform-tvOS%2026%20%7C%20iOS%2026%20%7C%20macOS-lightgrey.svg?style=flat)](https://github.com/Radiomyme/PopcornTimeTV)
[![Swift](https://img.shields.io/badge/swift-5-orange.svg?style=flat)](https://swift.org)
[![License](https://img.shields.io/badge/license-GPL_v3-373737.svg?style=flat)](LICENSE.md)

An Apple TV, iPhone and iPad application to stream movies and TV shows over BitTorrent.
This fork brings the project up to date for **Xcode 26**, **tvOS 26** and **iOS 26**, rebuilds the
data layer around pluggable content providers, adds a native SwiftUI app for iPhone / iPad /
Mac (Designed for iPad), and — new in **5.0.0** — ships a zero-dependency, pure-Swift
**MKV → fMP4/HLS remux engine** that unlocks true **Dolby Atmos** (and HDR) through Apple's
native `AVPlayer`.

## New in 5.0.0 — the remux engine (true Dolby Atmos)

MKV releases used to fall back to VLC, whose bundled build can't bitstream Dolby and tone-maps
HDR to SDR. 5.0.0 adds a **pure-Swift, dependency-free Matroska demuxer + fragmented-MP4 (CMAF)
muxer** (`MKVToHLSRemuxer.swift`) that repackages an MKV **while it's still downloading** and
serves it to `AVPlayer` as a complete VOD HLS presentation over a localhost server:

- **True Dolby Atmos** — the E-AC-3 (DD+) audio, JOC objects and all, is passed to Apple's
  decoder untouched. The audio is exposed as its own HLS rendition tagged `CHANNELS="16/JOC"`
  and the player session is put in `.moviePlayback`, so an Apple TV lights the receiver's
  **Dolby Atmos** badge and renders true object audio.
- **HDR / Dolby Vision** preserved (HEVC `hvc1` + `hvcC` copied verbatim — no tone-mapping).
- **Native subtitles** — OpenSubtitles tracks converted SRT → WebVTT on demand and offered in
  `AVPlayer`'s own picker (with CRLF/encoding handling for real-world files).
- **Full VOD timeline from t=0** — dynamic playlist with the real total duration, scrubbing and
  seeking, no "live" badge; segments are long-polled until remuxed.
- **Bounded disk use** — already-played segments are pruned behind the playhead, and torrent /
  remux caches are reclaimed at launch and before each stream on **all** platforms.

> Note: macOS decodes Dolby to PCM and can't bitstream Atmos, so the Atmos badge is an **Apple
> TV** capability; on Mac the remux still gives you the untouched HDR video and the full-quality
> audio stream. AirPlay from a Mac does **not** carry Atmos.

## What's new in this fork

**Platform & build**
- Swift 5, tvOS 17+ (built and run on tvOS 26), iOS deployment target 26
- Builds cleanly on Xcode 26 (pods pinned/patched, third-party warnings silenced)
- New SwiftUI app for iPhone / iPad / Mac (Designed for iPad) sharing the `PopcornKit` core

**Content & sources**
- Pluggable `MediaProvider` layer (no more hardcoded, dead `api-fetch` host)
- Movies via **YTS** (mirror-fallback chain) + **Torrentio** aggregation (a dozen indexers
  merged per title for far more releases)
- TV shows via **EZTV** (mirror chain) + **TVMaze** metadata, with the full episode guide
  merged with per-episode torrents
- Image proxy (weserv.nl) so posters load even when the source CDN is ISP-blocked

**Series**
- Shows tab sorts by Trending / Popular / Top Rated / New / **A–Z**, plus genre filtering
- Show detail lists episodes ordered by **season then episode**, duplicate releases collapsed
  into quality choices

**Playback**
- Subtitles revived via the OpenSubtitles REST API, best-per-language, with a default
  subtitle-language preference applied automatically
- **Audio-language** track picker in the player + a preferred-audio-language setting that
  auto-selects a matching track
- Quality system rewrite (2160p → 1080p → 720p → 480p, HDR/Dolby Vision/Atmos preferred)
- Three-way playback routing: **remux → AVPlayer** for DD+/E-AC-3 MKV (true Atmos, see above),
  **AVPlayer** for mp4/m4v/mov, **VLC** as the universal fallback

## Supported formats

| Kind | Supported |
|------|-----------|
| **Containers** | `.mkv` (remuxed to fMP4/HLS), `.mp4`, `.m4v`, `.mov` (native), anything else via VLC fallback |
| **Video** | HEVC / H.265 (`hvc1`, incl. 10-bit), H.264 / AVC; **HDR10** and **Dolby Vision** preserved through the remux path (no tone-mapping) |
| **Audio** | **Dolby Digital Plus (E-AC-3) with Dolby Atmos (JOC)** — true object audio on Apple TV; Dolby Digital (AC-3); AAC; others decoded via VLC |
| **Resolution** | up to **2160p (4K)**; auto-picks 2160p → 1080p → 720p → 480p by preference |
| **Subtitles** | OpenSubtitles (SRT → WebVTT), native `AVPlayer` picker, per-language preference; VLC subtitles on the fallback path |

> Atmos and Dolby Vision passthrough require an **Apple TV 4K** connected to a compatible
> display / receiver. On iPhone / iPad / Mac the same files play with full-quality decoded audio
> and HDR video where the device supports it.

## Build

Requires Xcode 26 and [CocoaPods](https://cocoapods.org). See [NOTICE.md](NOTICE.md) for the pods used.

```bash
git clone https://github.com/Radiomyme/PopcornTimeTV.git
cd PopcornTimeTV
pod install            # fetching MobileVLCKit / TVVLCKit takes a while
open PopcornTime.xcworkspace
```

Then pick a scheme:
- **PopcornTimetvOS** → run on an Apple TV simulator or device
- **PopcornTimeiOS** → run on iPhone / iPad, or "My Mac (Designed for iPad)"

> Tip: keep the checkout **outside** an iCloud-synced folder (e.g. `~/Developer`). iCloud
> creates `<file> 2.ext` conflict copies inside `Pods/` and can rewrite tracked project files,
> which breaks clean builds.

## License

If you distribute a copy or make a fork of the project, you have to credit this project as source.

This program is free software: you can redistribute it and/or modify it under the terms of the GNU
General Public License as published by the Free Software Foundation, either version 3 of the License,
or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
Public License for more details.

You should have received a copy of the GNU General Public License along with this program. If not,
see http://www.gnu.org/licenses/.

Note: some dependencies are external libraries, which might be covered by a different license
compatible with the GPLv3. They are mentioned in [NOTICE.md](NOTICE.md).

**This project and the distribution of this project is not illegal, nor does it violate _any_ DMCA
laws. The use of this project, however, may be illegal in your area. Check your local laws and
regulations regarding the use of torrents to watch potentially copyrighted content. The maintainers
of this project do not condone the use of this project for anything illegal, in any state, region,
country, or planet. _Please use at your own risk_.**

***

Released under the [GPL v3 license](LICENSE.md).
