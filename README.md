<p align="left">
  <img src="https://i.imgur.com/agYgrmo.jpeg" alt="Popcorn Time" title="Popcorn Time" width="260">
</p>

# PopcornTimeTV — modernized fork

[![Version](https://img.shields.io/badge/version-5.1.0-blue.svg?style=flat)](https://github.com/Radiomyme/PopcornTimeTV/releases)
[![Platform](http://img.shields.io/badge/platform-tvOS%2026%20%7C%20iOS%2026%20%7C%20macOS-lightgrey.svg?style=flat)](https://github.com/Radiomyme/PopcornTimeTV)
[![Swift](https://img.shields.io/badge/swift-5-orange.svg?style=flat)](https://swift.org)
[![License](https://img.shields.io/badge/license-GPL_v3-373737.svg?style=flat)](LICENSE.md)

An Apple TV, iPhone and iPad application to stream movies and TV shows over BitTorrent.
This fork brings the project up to date for **Xcode 26**, **tvOS 26** and **iOS 26**, rebuilds the
data layer around pluggable content providers, adds a native SwiftUI app for iPhone / iPad /
Mac (Designed for iPad), and — new in **5.0.0** — ships a zero-dependency, pure-Swift
**MKV → fMP4/HLS remux engine** that unlocks true **Dolby Atmos** (and HDR) through Apple's
native `AVPlayer`. **5.1.0** redesigns the Apple TV pages in Liquid Glass, makes the remux
engine play far more files natively, adds The Pirate Bay and Knaben sources with a Top 100, and
plays films larger than the free space.

## New in 5.1.0

The same notes are shown once in the app after the update (`WhatsNewRelease.current` in
`PopcornTime/UI/Shared SwiftUI/WhatsNew.swift`; keep the two in step).

**Apple TV**
- **Liquid Glass movie and show pages** (SwiftUI): full-bleed artwork, Play that names
  the episode it starts ("Play S2 · E5") with a progress bar, Trailer, Watchlist, Watched and
  Download buttons, season pills, an episode shelf with a summary panel, "Viewers Also Watched",
  cast & crew, information and accessibility cards. Real Liquid Glass on tvOS 26 and later,
  materials on tvOS 17–25. The page opens as soon as the movie or show info is known; related
  titles and cast fill in as they arrive.
- **Cast and similar titles are back**, without a Trakt account: Trakt now refuses the app's
  API key (HTTP 403) and the TMDB key is dead, so `OpenMetadata` (PopcornKit) uses keyless
  sources instead: cast with photos from YTS (movies) and TVMaze (shows), directors and
  writers from Cinemeta, "You Might Also Like" from YTS suggestions and Cinemeta's same-genre
  titles, logos and landscape backdrops from metahub.
- **Simpler Settings**: Auto Select Quality ("Always Ask" by default), audio and subtitle
  languages, theme songs on/off, Clear Cache, Trakt sign-out and the version with its release
  notes. Gone: the update check, Trakt sign-in, the VLC-only subtitle style rows and the
  "clear cache on exit" switch (now always on).
- **French**: the Apple TV app is now fully translated into French.
- **What's New**: the release notes appear once after an update (never on a fresh install),
  and again from Settings › Version.

**Playback (Apple TV, iPhone / iPad, Mac)** — the remux engine described below now covers:
- **Dolby Vision** profiles 5, 8.1 and 8.4 signalled natively, profile 7 as its HDR10 base
  layer; HDR10, HDR10+ and HLG as encoded.
- **Every compatible audio track** as its own selectable rendition (E-AC-3 / AC-3, AAC, MP3,
  MP2, FLAC, Opus, ALAC; PCM converted to FLAC). TrueHD, DTS and Vorbis go to VLC unless the
  file also has a compatible track.
- **The file's own text subtitles** (SRT, SSA/ASS, WebVTT) in `AVPlayer`'s picker; a slow
  OpenSubtitles download delays the start by about 15 seconds at most.
- **Exact seeks** from the file's keyframe index, **download-aware playback** (waits for the
  data instead of falling back) and far jumps that stay native when the data will arrive in
  time; played segments are kept behind the playhead as far as the disk allows.
- **A clearer quality picker** on every platform: quality, seeds and size per source, the
  recommended one starred.

**Small disks (Apple TV, Mac)**
- **Films larger than the free space now play**: when a film doesn't fit (a 13 GB 4K film on an
  Apple TV with 3 GB free, say), it streams in bounded storage: only a window around the
  playhead stays on disk, and what has been watched is released as playback moves on, so the
  device never fills up. The loading screen says about how far back a rewind can reach; a
  rewind or a reverse scan past what is still stored stops at the earliest point still on disk,
  with a message, and jumps ahead work as before. Only when even that can't fit does the app say
  how much space to free (on Apple TV, with an offer to try a lower quality). Films that fit
  play exactly as before. The iPhone / iPad app has the same code but hasn't run it yet.

**Torrent engine (every platform)**
- **One torrent engine everywhere**: Apple TV and iPhone / iPad now use the PopcornTorrent Swift
  package the Mac already used (libtorrent 1.2.19 built from source; it streams the release's
  main video file, or the file a Torrentio link names) instead of the CocoaPods PopcornTorrent
  1.3.15 binary (libtorrent 1.2.1).

**Catalog & sources (every platform)**
- **Top 100**: a new sort for Movies and Shows with The Pirate Bay's most seeded titles of the
  moment (its precompiled top 100s: Movies + HD + UHD, TV + HD TV + UHD TV), each release mapped
  to its IMDb title through Cinemeta (TPB's id only when Cinemeta confirms title and year, else
  an exact title + year search; box sets and unreadable names left out), ranked by the seeders
  of all its torrents. Cached 15 minutes on disk; an older list is shown at once if The Pirate
  Bay is slow or blocked.
- **More torrents per title** from **The Pirate Bay** (apibay) and the **Knaben** meta-index
  (1337x, TorrentGalaxy, Nyaa, YTS, RARBG archives…: most of what link launchers such as xtorx
  list), labelled with their source in the picker. Precision first: a release is kept only when
  its name is the film's title (or a known alias) followed by its year, alone (no pack, box set,
  bonus disc, 3D or RiffTrax version, not filed under another film of that name), or exactly the
  episode asked (show name, alternate titles, year / country when another show has the name).
  Both sources are optional and fail fast: a blocked host costs a few seconds once, then is
  skipped.
- **Search finds more titles**: Cinemeta's catalog (every IMDb title) is added after the
  existing results, exact title matches first; a title only Cinemeta knows still opens, with
  Torrentio, The Pirate Bay and Knaben torrents (a series TVMaze doesn't know uses Cinemeta's
  episode list).

**Shows (every platform)**
- **Mislabelled torrents left out**: EZTV files releases of other shows under a show's IMDb id
  (every "Breaking Bad" entry is in fact "Breaking Brad", which added seasons 6–9 and wrong
  files to seasons 1–5). Releases whose name doesn't match the show's title or one of its
  alternate titles (TVMaze akas: "Money Heist" for "La Casa de Papel") are dropped.

**iPhone / iPad**
- Detail pages with cast, star rating and related titles (Apple TV parity).

**Mac**
- **Native Mac app** (macOS 14+) with the same remux engine: Dolby Atmos rendered spatially on
  the Mac and AirPods.
- **Liquid Glass movie and show pages** with the Apple TV layout (full-size artwork, logo,
  season pills and an episode shelf, cast, similar titles, information cards), hover effects,
  and a Watchlist section in the sidebar. The Mac app is now localized like the Apple TV one.

## The remux engine (true Dolby Atmos) — new in 5.0.0, extended in 5.1.0

MKV releases used to fall back to VLC, whose bundled build can't bitstream Dolby and tone-maps
HDR to SDR. 5.0.0 adds a **pure-Swift, dependency-free Matroska demuxer + fragmented-MP4 (CMAF)
muxer** (`MKVToHLSRemuxer.swift`) that repackages an MKV **while it's still downloading** and
serves it to `AVPlayer` as a complete VOD HLS presentation over a localhost server:

- **True Dolby Atmos** — the E-AC-3 (DD+) audio, JOC objects and all, is passed to Apple's
  decoder untouched. The audio is exposed as its own HLS rendition tagged `CHANNELS="16/JOC"`
  and the player session is put in `.moviePlayback`, so an Apple TV lights the receiver's
  **Dolby Atmos** badge and renders true object audio.
- **HDR / Dolby Vision preserved** — the video bitstream is copied verbatim (no tone-mapping):
  HDR10, HDR10+ and HLG as encoded; Dolby Vision profiles 5, 8.1 and 8.4 signalled natively
  (`dvh1` + `dvvC`); profile 7 (UHD Blu-ray) plays its HDR10 base layer. `hev1`-style HEVC
  streams are rebuilt as `hvc1`.
- **Every audio track, natively** — each compatible track becomes its own selectable HLS
  rendition (language, channel layout, default flag): E-AC-3 / AC-3, AAC (LC, HE), MP3, MP2,
  FLAC, Opus and ALAC are passed through; PCM is converted losslessly to FLAC on the fly.
- **Native subtitles** — the file's own text subtitles (SRT, SSA/ASS, WebVTT, compressed or
  not) become WebVTT tracks in `AVPlayer`'s picker, with their *forced* and *SDH* flags;
  OpenSubtitles files (SRT, SSA/ASS, MicroDVD, SubViewer, WebVTT, in any common encoding) are
  added on demand. A subtitle download that fails never interrupts native playback, and a
  slow one delays the start by about 15 seconds at most: the movie then starts without it.
  Where the system offers machine-translated subtitles (OS 27), they are used only as a last
  resort.
- **Full VOD timeline from t=0** — the whole movie is listed from the first second with its real
  total duration: scrubbing and seeking, no "live" badge; segments are long-polled until
  remuxed. Segment boundaries come from the file's keyframe index (Matroska Cues) when it has
  one, so a seek lands where you aim even on long-GOP encodes. Files that don't declare a
  duration play from a growing playlist until the remux completes.
- **Download-aware playback** — when playback catches up with the download, the player waits
  for the data and resumes natively at the same position; a damaged or incomplete region of the
  torrent is waited for, never played as garbage. A jump just past the downloaded part also
  stays native: the player measures the download's pace and waits when the data will arrive
  within about 45 seconds. VLC only takes over when native playback is impossible or would keep
  you waiting: a codec Apple can't decode, a rewind past the segments still on disk, a full
  disk, or a jump so far ahead that the player can't prepare it within about 45 seconds — a
  part not downloaded yet (the torrent downloads in order; VLC fetches that part directly), or
  one so far into the downloaded part that the remux can't reach it in time. It continues at the
  current or chosen position.
- **Bounded disk use** — played segments are kept behind the playhead as far as the free disk
  space allows (at least 3 minutes), so rewinds stay native; only on a tight disk are the oldest
  ones pruned. Torrent / remux caches are reclaimed at launch and before each stream on **all**
  platforms.

> Note: macOS decodes Dolby to PCM and can't bitstream Atmos, so the Atmos badge is an **Apple
> TV** capability; on Mac the remux still gives you the untouched HDR video and the full-quality
> audio stream. AirPlay from a Mac does **not** carry Atmos.

## What's new in this fork

**Platform & build**
- Swift 5, tvOS 17+ (built and run on tvOS 26), iOS deployment target 26
- Builds cleanly on Xcode 26 (pods pinned/patched, third-party warnings silenced)
- New SwiftUI app for iPhone / iPad / Mac (Designed for iPad) sharing the `PopcornKit` core
- Native macOS app (macOS 14+) with the same remux engine, so Atmos is rendered spatially on
  the Mac instead of being downmixed
- One torrent engine on every platform: the PopcornTorrent Swift package (libtorrent 1.2.19) on
  Apple TV, iPhone / iPad and Mac

**Content & sources**
- Pluggable `MediaProvider` layer (no more hardcoded, dead `api-fetch` host)
- Movies via **YTS** (mirror-fallback chain) + **Torrentio** aggregation (a dozen indexers
  merged per title for far more releases)
- TV shows via **EZTV** (mirror chain) + **TVMaze** metadata, with the full episode guide
  merged with per-episode torrents
- **The Pirate Bay** + **Knaben** as extra torrent sources, The Pirate Bay's **Top 100**, and
  **Cinemeta** in search (see "New in 5.1.0")
- Image proxy (weserv.nl) so posters load even when the source CDN is ISP-blocked

**Series**
- Shows tab sorts by Trending / **Top 100** / Popular / Top Rated / New / **A–Z**, plus genre
  filtering
- Show detail lists episodes ordered by **season then episode**, duplicate releases collapsed
  into quality choices

**Playback**
- Subtitles revived via the OpenSubtitles REST API, best-per-language, with a default
  subtitle-language preference applied automatically
- **Audio-language** track picker in the player + a preferred-audio-language setting that
  auto-selects a matching track
- Quality system rewrite (2160p → 1080p → 720p → 480p, HDR/Dolby Vision/Atmos preferred)
- Three-way playback routing on the real file name: **remux → AVPlayer** for every Matroska /
  WebM file (the remuxer checks the codecs within seconds and hands anything Apple can't decode
  to VLC), **AVPlayer** for mp4/m4v/mov, **VLC** for AVI, MPEG-TS/M2TS, WMV, FLV, MPEG-PS/VOB,
  Ogg… and as the universal fallback
- On Apple TV, iPhone and iPad, playback resumes where you left off on every engine; a far
  resume on a still-downloading file asks whether to resume through VLC or restart natively

## Supported formats

| Kind | Native (`AVPlayer`: HDR, Dolby Vision, Atmos) | Through VLC |
|------|-----------------------------------------------|-------------|
| **Containers** | Matroska `.mkv` / `.mk3d` and WebM (remuxed to fMP4/HLS); `.mp4`, `.m4v`, `.mov` (direct) | AVI, MPEG-TS / M2TS, WMV / ASF, FLV, MPEG-PS / VOB, Ogg, 3GP, RealMedia… |
| **Video** | HEVC / H.265 Main & Main 10; H.264 / AVC 8-bit 4:2:0; HDR10, HDR10+, HLG and Dolby Vision 5 / 8.1 / 8.4 kept as encoded; Dolby Vision 7 as its HDR10 base layer; AV1 where the chip decodes it in hardware (A17 Pro / M3 and later) | H.264 Hi10P / 4:2:2 / 4:4:4, HEVC 4:2:2 / 4:4:4 / 12-bit, VP8 / VP9, AV1 without hardware decoding, MPEG-1 / 2, MPEG-4 Part 2 (DivX / Xvid), VC-1, VVC, Theora |
| **Audio** | **Dolby Digital Plus (E-AC-3) with Dolby Atmos (JOC)** — true object audio on Apple TV; Dolby Digital (AC-3); AAC LC / HE-AAC; MP3; MP2; FLAC; Opus; ALAC; PCM (converted losslessly to FLAC) | TrueHD / MLP, DTS (all variants), Vorbis, AAC Main / SSR / LTP, TTA, WavPack |
| **Subtitles** | Embedded SRT, SSA/ASS and WebVTT tracks (forced / SDH flags kept); OpenSubtitles (SRT, SSA/ASS, MicroDVD, SubViewer, WebVTT); per-language preference | Bitmap PGS / VobSub tracks, plus OpenSubtitles |
| **Resolution** | up to **2160p (4K)**; auto-picks 2160p → 1080p → 720p → 480p by preference | same |

> A file that pairs an unsupported track with a supported one stays native: for example a
> TrueHD Atmos + AC-3 release plays in HDR / Dolby Vision with the AC-3 track. Apple's decoders
> don't handle TrueHD or DTS, so files carrying only those go to VLC.

> Atmos and Dolby Vision passthrough require an **Apple TV 4K** connected to a compatible
> display / receiver. On iPhone / iPad / Mac the same files play with full-quality decoded audio
> and HDR video where the device supports it.

## Build

Requires Xcode 26 and [CocoaPods](https://cocoapods.org); PopcornTorrent (the torrent engine of
all three apps) and GCDWebServer are Swift packages that Xcode resolves. See
[NOTICE.md](NOTICE.md) for the dependencies.

```bash
git clone https://github.com/Radiomyme/PopcornTimeTV.git
cd PopcornTimeTV
pod install            # fetching MobileVLCKit / TVVLCKit takes a while
open PopcornTime.xcworkspace
```

Then pick a scheme:
- **PopcornTimetvOS** → run on an Apple TV simulator or device
- **PopcornTimeiOS** → run on iPhone / iPad, or "My Mac (Designed for iPad)"
- **PopcornTimeMac** → the native macOS app

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
