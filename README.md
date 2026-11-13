<p align="left">
  <img src="https://i.imgur.com/agYgrmo.jpeg" alt="Popcorn Time" title="Popcorn Time" width="260">
</p>

# PopcornTimeTV — modernized fork

[![Version](https://img.shields.io/badge/version-5.2.0-blue.svg?style=flat)](https://github.com/Radiomyme/PopcornTimeTV/releases)
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
plays films larger than the free space. **5.2.0** picks releases the connection can carry, says
what loading is doing, plays the right episode from season packs, downloads at the swarm's speed
and makes the Apple TV remote's Back reliable.

## New in 5.2.0

The same notes are shown once in the app after the update (`WhatsNewRelease.current` in
`PopcornTime/UI/Shared SwiftUI/WhatsNew.swift`; keep the two in step).

**Choosing and loading (Apple TV, iPhone / iPad, Mac)**
- **A release the connection can carry**: each release's bitrate is estimated (file size ÷
  runtime; a Time4Popcorn episode by its own file; collections and packs left unknown) and
  weighed against the speed downloads actually reach (90th percentile of well-connected
  streams). The Balanced automatic choice and the pickers' recommendation avoid releases above
  85 % of it; picker rows show "≈ N Mb/s" and "May stutter: your downloads reach about N Mb/s".
- **Loading says what it is doing** from the first second: looking for peers, getting the
  torrent's details (with the peers connected), buffering with the time left. A source that
  doesn't answer gets "This source isn't responding" with *Choose another source* / *Keep
  waiting*, and is left out of that title's pickers and automatic picks; *Choose another
  source* also sits beside a slow buffering. On Apple TV a "Looking for sources…" card shows
  while an episode's sources load (Menu cancels it).
- **A lighter release when playback can't keep up**: when the download stays below the
  release's bitrate, the player offers a lighter, well-seeded release that fits, resuming at the
  same position (a banner on iPhone / iPad and Mac, a toast on Apple TV). Waiting after a seek
  and bounded-storage pacing don't count.
- **Season packs play the episode you chose**: in a multi-file torrent, a stream or a download
  takes the episode's own file: the file the source names (Time4Popcorn's file name), the
  magnet's `so=`, else the video file named after the episode (S01E03, S01EP03, 1x03, Cap.103,
  "S1 - 03", "Season 1 E03"…, a range such as S01E01-E03; E01 never taken for E10), else, in a
  folder or torrent named after the season (or a batch that names none, "(01-28) [Batch]", a
  "Complete" miniseries), the file numbered on its own ("Episode 03", "03 - Title", "Show -
  03", "Part 3", "3of6", "Серия 03", "103"). A `so=` file numbered absolutely is played when it
  is the episode's place in the season ("S03 - 50" for S03E13 in a pack from 38); without it, a
  later season's batch numbered absolutely ("S2 (14-38)") is not guessed, nor are the files of a
  "Complete" pack in folders not read as seasons ("Series 2", "Book 3 - Fire"), extras
  ("Extras/… Part 1", a making-of) and recaps ("- 06.5"): those fail as below. Samples are
  left out when they are much smaller than the episodes, also when the source names one (a
  show called *Trailer Park Boys* is not a trailer). A pack without the episode now fails with
  "This torrent does not contain the requested episode. Please choose another source." instead
  of playing its largest file, another episode, and offers *Choose another source* when another
  source is known (on Apple TV that pack is also left out of the title's automatic picks). Two episodes downloaded from one pack each keep
  their own folder. Single-file torrents and movies play as before.
- A quieter console (GCDWebServer and libvlc errors only).

**Torrent engine (every platform)**
- **Downloads at the swarm's speed**: streams and offline downloads no longer hold libtorrent in
  its time-critical mode ahead of time (deadlines on the next missing pieces allowed each peer
  one request at a time). The pieces ahead of the read position are fetched in file order at
  high priority, a deadline is set only on a piece a reader waits for once it is late, peers no
  longer take whole pieces each, and requests held by peers far slower than the rest are
  cancelled when they would make a needed piece late. After a forward seek or a resume, the
  pieces ahead of the reader come before the part skipped behind it; the progress a stream or a
  download reports counts the file's own pieces, so it no longer jumps back and forth then, and
  a torrent counts as finished only with its whole file.
- **More of the swarm**: more peers and connections (Apple TV 100 per torrent / 200 in all,
  iPhone / iPad 80 / 160, Mac 100 / 400; the app's limit of open files is raised so these apply),
  faster connection attempts and timeouts (kept moderate for home routers), every
  tracker announced to at once, a list of reliable public trackers added to public torrents,
  a random listen port per install instead of 6881, UPnP / NAT-PMP port mapping on Apple TV and
  Mac. A download nobody plays fetches the rarest pieces first.
- In the offline benchmark (PopcornTorrent's `Tools/NetworkBench`: seeders on 127.0.0.1 behind
  added latency and per-peer caps), a 12 MB/s swarm is ready to play in 6 s instead of 13 s and
  downloads at 11.9 MB/s instead of 9.0; a 36 MB/s swarm at 35.4 MB/s instead of 11.5. Real
  swarms and routers are not measured yet.

**Apple TV**
- **The remote's Back goes back**: Menu pressed right after opening a title no longer
  crashes the app (UIKit's back gesture during the push); Back on the loading screen or on a
  load error goes back a screen instead of leaving the app; Back on the playback loading screen
  stops the stream even while the subtitles are fetched or the screen is just appearing (it
  now appears without a transition, during which tvOS ignored the remote), and no player opens
  afterwards; Back on "Looking for sources…", even before it shows, drops the request (no
  chooser for a page you left).
- **The Top 100 comes back in place**: coming back from a page no longer lays the grid out four
  posters wide before six, nor reloads every poster; the poster you opened keeps the focus, at
  the same place. The grids reload only when their content changed. A grid's title and Sort /
  Genre scroll away with the posters, and the tab bar follows the scroll.
- Play/Pause on a poster opens the title and plays it, also on a Continue Watching card (on a
  page: the focused episode, a related title, or what Play plays); holding Select on a poster
  offers Play, Watchlist and Watched. Search shows its
  keyboard at once, Up from its results goes back to the keyboard and the tab bar (it used to
  loop back to the first result), and VoiceOver reads every poster's title.

**Tests** (see [Tests](#tests))
- ⌘U runs the app's unit tests on the Mac in seconds, offline; PopcornTorrent's own tests no
  longer stream public torrents; `tools/run-tests.sh` runs everything in parallel; the Apple TV
  navigation has UI tests.

## New in 5.1.0

Shown in the app as the 5.1 notes (`WhatsNewRelease.v5_1_0`).

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

## Tests

**⌘U**: pick the **PopcornTimeTests** scheme (or PopcornTimeMac), destination *My Mac*. The
macOS unit-test target runs in about 8 seconds, offline, in English whatever the Mac's
language: 37 tests, 3,320 checks of the extra sources (apibay, Knaben, Cinemeta, TVMaze, the
Top 100), the season-pack file choice, the bandwidth estimate and the lighter-release offer,
the loading phases, bounded storage, the remux eviction and `FarTargetWatch` rules, the
GCDWebServer log filter. The
recorded API answers are in `PopcornTimeTests/Fixtures` (slimmed to the fields the parsers
read); the tests never call an API. The playback files under test are compiled into the test
bundle: a new file they come to depend on must be added to the PopcornTimeTests target too.

The torrent engine has its own tests: open PopcornTorrent's package and ⌘U. They run offline
too (a generated season pack seeded on 127.0.0.1); the old tests that streamed public
torrents are skipped unless `PT_INTERNET_TESTS=1` is set.

From the terminal, one command runs everything:

```bash
tools/run-tests.sh          # quick: the app's and PopcornTorrent's unit tests, in parallel (~10 s, < 1 min after a change)
tools/run-tests.sh full     # quick + the long benches, the independent ones in parallel
tools/run-tests.sh clean    # forget the cached builds
```

PopcornTorrent's suites need a clone of it: the workspace's local package when you point it at
one, else `POPCORNTORRENT_DIR=<clone> tools/run-tests.sh`. Without either (a plain clone of this
repository) they are skipped, and the summary says so.

| Suite | Mode | Time |
|---|---|---|
| PopcornTimeTests (macOS) | quick | ~8 s (+ ~20 s when a source changed, ~70 s from scratch) |
| PopcornTorrentLogicTests, PopcornTorrent-Tests (offline, sandboxed) | quick | ~8 s |
| PopcornTorrent SessionHarness: 11 modes and the network settings of the 3 profiles, in parallel (sandboxed) | full | ~3 min |
| P10 / B6: a real AVPlayer on a 20 s clip (local benches, not in the repository: skipped without them) | full | ~3 min |
| Remux e2e engine, then the F3 bench (local benches, not in the repository; `PT_FORMAT_BENCH`) | full | ~17 min + ~90 min |
| Bounded-storage disk-image runs (`PT_BOUNDED_RUNS=1`) | full | ~5 min |

Builds, stamps and logs go to `~/Library/Caches/PopcornTimeTV-tests` (`PT_TEST_CACHE`): a test
bundle is rebuilt only when the content of its sources changed (a commit alone does not), a
bench binary only when its sources did. The
torrent tests and harnesses run under `sandbox-exec` with `tools/localhost-only.sb`: nothing
can reach a tracker, the DHT or a peer outside 127.0.0.1.

**Apple TV UI tests** (slow, kept out of `run-tests.sh`): the **PopcornTimetvOSUITests** scheme
drives the tvOS app on an Apple TV simulator with the remote (`XCUIRemote`): Back to the Top
100, Trending and Shows grids (same poster, same place, no movement), Menu while a page slides
in, on a slow loading screen and on a load error, a page's summary and shelves, a show's
episodes, the quality chooser, the poster menu, Settings, Search (Up from its results back to
the tab bar), Downloads, the Watchlist and What's New, Menu pressed twice or three times in
quick succession, Menu with the focus in the tab bar, and a grid's title and Sort / Genre
scrolling away with the posters (Up from the first row reaches them, then the tab bar). 24
tests, about 8 minutes. They read the public catalog APIs, never press Play, and
set the app up with DEBUG launch arguments, so they are built with the DEBUG condition (the app
for x86_64, the test runner for arm64):

```bash
xcodebuild -workspace PopcornTime.xcworkspace -scheme PopcornTimetvOSUITests \
  -destination "generic/platform=tvOS Simulator" -derivedDataPath build/ui \
  ONLY_ACTIVE_ARCH=NO SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG build-for-testing
xcodebuild test-without-building -xctestrun build/ui/Build/Products/PopcornTimetvOSUITests_*.xctestrun \
  -destination "platform=tvOS Simulator,name=<your Apple TV simulator>,arch=arm64"
```

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
