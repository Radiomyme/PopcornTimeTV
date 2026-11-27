# Technical reference

The details behind the [README](../README.md): what plays natively, the switches, the Apple TV
Top Shelf, the console's logs and the tests. What changed in each version is in
[CHANGELOG.md](../CHANGELOG.md).

- [Supported formats](#supported-formats)
- [The hidden switch `PTNativeJumpsDisabled`](#the-hidden-switch-ptnativejumpsdisabled)
- [Building](#building)
- [The Apple TV Top Shelf](#the-apple-tv-top-shelf)
- [Logs](#logs)
- [Tests](#tests)

## Supported formats

| Kind | Native (`AVPlayer`: HDR, Dolby Vision, Atmos) | Through VLC |
|------|-----------------------------------------------|-------------|
| **Containers** | Matroska `.mkv` / `.mk3d` and WebM (remuxed to fMP4/HLS); `.mp4`, `.m4v`, `.mov` (direct) | AVI, MPEG-TS / M2TS, WMV / ASF, FLV, MPEG-PS / VOB, Ogg, 3GP, RealMedia… |
| **Video** | HEVC / H.265 Main & Main 10; H.264 / AVC 8-bit 4:2:0; HDR10, HDR10+, HLG and Dolby Vision 5 / 8.1 / 8.4 kept as encoded; Dolby Vision 7 as its HDR10 base layer; AV1 where the chip decodes it in hardware (A17 Pro / M3 and later) | H.264 Hi10P / 4:2:2 / 4:4:4, HEVC 4:2:2 / 4:4:4 / 12-bit, VP8 / VP9, AV1 without hardware decoding, MPEG-1 / 2, MPEG-4 Part 2 (DivX / Xvid), VC-1, VVC, Theora |
| **Audio** | **Dolby Digital Plus (E-AC-3) with Dolby Atmos (JOC)** — true object audio on Apple TV; Dolby Digital (AC-3); AAC LC / HE-AAC; MP3; MP2; FLAC; Opus; ALAC; PCM (converted losslessly to FLAC) | TrueHD / MLP, DTS (all variants), Vorbis, AAC Main / SSR / LTP, TTA, WavPack |
| **Subtitles** | Embedded SRT, SSA/ASS and WebVTT tracks (forced / SDH flags kept); OpenSubtitles (SRT, SSA/ASS, MicroDVD, SubViewer, WebVTT), synced automatically to the film on the MKV route (« Automatic Subtitle Sync »); per-language preference | Bitmap PGS / VobSub tracks, plus OpenSubtitles |
| **Resolution** | up to **2160p (4K)**; auto-picks 2160p → 1080p → 720p → 480p by preference | same |

> A file that pairs an unsupported track with a supported one stays native: for example a
> TrueHD Atmos + AC-3 release plays in HDR / Dolby Vision with the AC-3 track. Apple's decoders
> don't handle TrueHD or DTS, so files carrying only those go to VLC.

> Atmos and Dolby Vision passthrough require an **Apple TV 4K** connected to a compatible
> display / receiver. On iPhone / iPad / Mac the same files play with full-quality decoded audio
> and HDR video where the device supports it.

> Note: macOS decodes Dolby to PCM and can't bitstream Atmos, so the Atmos badge is an **Apple
> TV** capability; on Mac the remux still gives you the untouched HDR video and the full-quality
> audio stream. AirPlay from a Mac does **not** carry Atmos.

How the native path works — the MKV → fMP4 / HLS remux engine — is told in
[CHANGELOG.md › 5.0.0](../CHANGELOG.md#500--the-remux-engine-true-dolby-atmos).

## The hidden switch `PTNativeJumpsDisabled`

Since 5.3.0; no UI, compiled in every build, not a DEBUG hook: a boolean user default. Absent
or `NO`, the default, the conversion jumps natively (resume, far seeks, rewinds into holes). `YES` turns native jumps off: the conversion only runs
in file order, as in 5.2.0, and resuming a film that is still downloading goes through VLC (the
resume question then says so; VLC jumps by the keyframe index, under « Resuming at … »). The
`[Resume]` lines name it: `native jumps are off (PTNativeJumpsDisabled)`. To try it, add
`-PTNativeJumpsDisabled YES` to the scheme's launch arguments.

## Building

Requires Xcode 26 or later and [CocoaPods](https://cocoapods.org); PopcornTorrent (the torrent
engine of all three apps) and GCDWebServer are Swift packages that Xcode resolves. See
[NOTICE.md](../NOTICE.md) for the dependencies, and the README for the steps.

> Tip: keep the checkout **outside** an iCloud-synced folder (e.g. `~/Developer`). iCloud
> creates `<file> 2.ext` conflict copies inside `Pods/` and can rewrite tracked project files,
> which breaks clean builds.

## The Apple TV Top Shelf

With the app's icon in the top row of the Apple TV home screen, the Top Shelf is a full-screen
carousel of what is new: the Home's hero, then the newest 4K releases, additions and episodes,
each with its details, its format badges (4K, Dolby Vision / HDR, Atmos), **Play** (the title's
page, then playback: `popcorntime://play/…`) and **More Info** (the page). When no title has a
real backdrop it falls back to rows of posters; with nothing to show, to the static image.

- **Its own lists.** The extension (`TopShelf/`) runs the Home engine itself on a light plan
  (`TopShelfLoader`): the app and the extension share no container (no App Group yet), so it keeps
  its own small cache in its Caches folder and asks its five lists itself. It answers from that
  cache at once, refreshes what is stale, and asks the system to reload if the titles changed; a
  first load waits 5 s at most. For the same reason it does not know the library (no resume card,
  no new episodes of your shows), the content languages and hidden shelves chosen in the app, nor
  whether the Terms of Service were accepted: with the app in the top row, the extension asks its
  hosts (Cinemeta, YTS and apibay's 4K ranking) on its own whenever the system wants the shelf and
  a list is stale, even before the app was ever opened — as 5.2.0's asked YTS and EZTV.
- **When it is reloaded.** In the app, `TopShelfReloader` notes a Home refresh that brought new
  lists, and tells the system once, when the app leaves the foreground (at once if the refresh ends
  while it is in the background). A library change is not followed while the extension cannot read
  the library (`TopShelfReloader.followsLibrary`): it would only wake the extension for nothing.
- **Its log.** The extension prints `[TopShelf] answered … in N ms` and `[TopShelf] refreshed …`
  in its own process: `log stream --predicate 'process == "TopShelf"'`. The app prints
  `[TopShelf] the shelf may have changed: the system is told`.

## Logs

Every console line of the app starts with a tag. The ones that tell a playback's story:

| Tag | What it says |
|---|---|
| `[Start]` | **The start-up timing**: one line per phase from Play to the first frame, with the phase's milliseconds and the time since Play (`t+`), then a total. Grep it to measure a start |
| `[Measure]` | **The torrent side of a start**, next to `[Start]`: the torrent's pieces, what PopcornTorrent waits for before « ready », then the bytes, rate and peers at the first peer, the first piece, the moment the head and the moment the tail it waits for are all on disk (`head on disk`, `tail on disk`: the later one ended the start buffer; in bounded storage the head line can come only at ready, marked `seen at ready`, since the engine does not publish its window: it then says the head was there by ready at the latest), ready, the remux's first segments, a resume's steering (`resume steering: … decided start` or `question up`, `N ms after ready`), the start's jump (the first one before the first frame; a later far seek or rewind is not logged), that jump's first segment and the first frame; Apple TV: `[Measure] home paint from disk: yes in 12.3 ms (14 shelves)` at launch (in every build) |
| `[chooseQuality]` | The releases found for the title, the automatic pick or the chooser |
| `[Sources]`, `[Torrentio]`, `[T4P]`, `[Extra]`, `[TPB]`, `[Knaben]` | An episode's extra sources (asked together behind one 3 s deadline), each source's answer |
| `[Subtitles]` | The OpenSubtitles search (it runs alongside the stream) and its answer |
| `[Play]`, `[Streamer]`, `[Loading]` | The stream: added, buffering by 10 %, ready, failed, cancelled (`[Loading] Back: stream cancelled, data kept`, or `no stream yet to cancel`) |
| `[Remux]` | The MKV → HLS engine: tracks, segment target, each anomaly, why it stopped |
| `[SubSync]` | The automatic sync of the OpenSubtitles files (MKV route): the reference of the session (`embedded track N (name)` or `audio centre / mid`), then one line per estimate — `fr: reference embedded track 2 (English), offset +0.84 s, ratio 1, confidence 0.66/7.4/2.7, overlap 227 s / 35 cues, applied (moves up to 0.84 s)` or `rejected (why)` — and `sub_fr.vtt: the retimed file is served from now on`; DEBUG: `-PTDebugExternalSubtitle "<file>@<language>"` serves a local file as that language's OpenSubtitles file, `-PTDebugSubtitleSyncQuick YES` the 30 s test clip schedule |
| `[Player]` | The players: the route (remux, direct, VLC), recoveries, hand-offs to VLC, subtitles; `closed at X s — stream cancelled, data deleted=…` (`(the next episode starts)` when the card chains; a hand-off to VLC does not cancel the stream: `handed off to VLC`); during a jump's wait (5.3.0) `jump wait: still waiting for the media at … after N s` and `jump wait: the old item before its replacement — …` (its state, time, rate, picture size and the errors since the jump), `jump wait paused by the user — « Reprise à … » hidden until play is pressed`; `audio track not resolved yet (item.tracks N)`, then one more look 1 s later |
| `[Player] navigation` | Apple TV, native player (5.3.0): a remote gesture AVKit reported — `navigation A → B s (paused, before AVKit's seek the player reads A s, …)`; `navigation to B s pending for 1.0 s: the player reads X s` (X = A: the clock still shows the old time; the target is used anyway); `navigation chained on the pending one: from X s, …` when a press comes while the previous seek is still held; `navigation to B s no longer pending: …` (naming the target dropped). With them: `[Remux] hole segment N requested (…)` then `[Player] AVPlayer asks for …, which a jump …` when tvOS did not report the gesture, and `[Player] AVKit resumes playback after the navigation to … s (from … s; item: …, rate …, item …, the player reads … s)` |
| `[Resume]` | A resume or a far jump in a film that is still downloading: native or VLC and why, the segment and the source offset the conversion jumps to, the first segment written, the first frame, each with its timing (`jump decided (resume / farSeek / rewind)`, `steering: readPosition=… (decided start / question up, +N s)`, `jump: a new item plays at …`, `rewind to … blocked at …` with bounded storage); during a jump's wait (5.3.0) `jump wait +N s: reader …, first missing … (piece … of the file), on disk X of Y bytes of the target (Z %), window W %, R MB/s, P peers` at +2, +5, +10 s then every 10 s, `jump wait late: …` when the wait is late in full storage mode and the engine's own server (127.0.0.1) is asked for the missing pieces (two at most), then `jump wait: the engine is asked for N more piece(s) …` and `jump wait: N request(s) to the engine cancelled — …` (`— the conversion stops` when the player closes, hands off to VLC or chains the next episode); `navigation to … while the resume's item is put in place — ignored, AVKit is sent to the resume point …`; `[Resume] VLC:` for a resume through VLC |
| `[UpNext]` | Episode chaining (5.3.0): the plan (`plan S01E02 rule=samePack / sameGroup / sameClass …` and why), `armed S01E01 → S01E02: prefetch at … s, card at … s (duration … s)`, `sources asked ahead: N ms — …` (the next episode's sources during playback, not a start), the card (`card shown: countdown, 60 s — …`, then `native card on screen (AVKit proposal)` or `card on screen (overlay)`), a press too early (`Play Now ignored: card up 0.4 s`), the answer with its source and the card's time on screen (`outcome accepted (Play Now, card up 12.4 s)`, or `AVKit didAccept`, `overlay`, `debug`, `card button`), `file ended`, `start S01E02 (deadline / accepted)`, the previous stream stopped and its data deleted, `resume … rule=sameRelease` for Resume, a remembered release forgotten |
| `[Bounded]`, `[Deficit]`, `[Cache]` | Bounded storage, a download slower than the film, the caches purged |
| `[Detail]` | A title's page: opened, first paint, metadata, first source, all sources (milliseconds since the page opened), a page asked ahead from a focused or hovered card, a Play pressed before the sources |
| `[TopShelf]` | The Apple TV Top Shelf: the extension's answer and refresh (milliseconds, titles shown; in the `TopShelf` process), the app telling the system to reload it |
| `[Home]` | The Home feed (5.3.0): a host that failed (`[Home] <host><path> FAILED status=… code=…`); with DEBUG launch arguments, also the fixtures it was fed from |
| `[DeepLink]` | A `popcorntime://` link (Top Shelf, Home, another app): opened, kept until a screen goes, dropped, refused before the Terms of Service, not a link into the app |
| `[WhatsNew]` | What's New at launch (5.3.0), once per launch, in every build: `present`, `marked seen silently` or `skip`, the version last seen, the notes' and the app's versions (`, fresh install`, `, launched from a link`) |

The `[Start]` lines of one playback (an episode, MKV, native player):

```
[Start] sources: 1240 ms — 14 torrent(s) (T4P 3 · Torrentio 9 · TPB/Knaben 2)
[Start] subtitles: 830 ms (t+830 ms) — 23 language(s)
[Start] metadata: 3200 ms (t+3200 ms) — 12 peer(s)
[Start] buffer: 8100 ms (t+11300 ms) — Show.S02E05.1080p.mkv
[Start] remux prepare: 420 ms (t+11720 ms) — 2 segment(s)
[Start] first frame: 900 ms (t+12620 ms) — AVPlayer (remux)
[Start] total: 12620 ms to the first frame — Show (subtitles 830 ms · metadata 3200 ms · buffer 8100 ms · remux prepare 420 ms · first frame 900 ms)
```

- `sources`: an episode's extra sources, from the press to the chooser (`0 ms … kept from N s ago`
  when the page had asked them ahead). It stands alone: the chooser sits between it and the rest.
  `, not in time: T4P` names a source the list came without (it is past the 3 s deadline, or not
  waited for after it did not answer the last time); `, failed: Torrentio` one that answered
  with an error and is asked again at the next press. A release played without asking (an
  automatic quality) and « No torrents found » wait for the sources still expected, 12 s at most.
- `subtitles`: the OpenSubtitles search, started with the stream; it never holds it.
- `metadata`: from the stream being added to the torrent's file list being in (peers found).
- `buffer`: from there to PopcornTorrent's « ready to play ».
- `remux prepare` (MKV on the native player only): header read, first two segments written.
- `first frame`: from there to the player really playing (`AVPlayer (remux)`, `AVPlayer (direct)`
  or `VLC`).

The `[Measure]` lines of the same start (the resume of a 1.6 GB test film at 70 %, on the local
test seeder):

```
[Measure] first peer: t+1362 ms (engine +1216 ms) — file 0 B · on disk 0 B · head 0 B · 0 B/s · 1 peer(s), 1 seed(s)
[Measure] first piece: t+1581 ms (engine +1435 ms) — file 1048576 B (1.0 MiB) · on disk 1048576 B (1.0 MiB) · head 0 B · 0 B/s · 1 peer(s), 1 seed(s)
[Measure] torrent: piece 1048576 B (1.0 MiB), 1568 piece(s), 1643505184 B; file #0 of 1, 1643505184 B at offset 0 (pieces 0…1567)
[Measure] readiness (engine rule, recomputed by the app): head 20 piece(s) = 20971520 B of the file + tail 2 piece(s) = 1435168 B; tail pinned from 1635778560 (7726624 B), head pin 0 B; full
[Measure] ready: t+8514 ms (engine +8368 ms) — file 28698144 B (27.4 MiB) · on disk 28700672 B (27.4 MiB) · head 20971520 B (20.0 MiB) · 3126919 B/s (3.0 MiB/s) · 1 peer(s), 1 seed(s)
[Measure] resume steering: … — read offset 1142296945, segment 114
[Measure] remux ready: … — remux read 21594269 B of the file for 2 segment(s)
[Measure] jump decided: … — resume, segment 114
[Measure] jump written: … — segment 114, read from 1142296945 to 1152980534
[Measure] first frame: t+18056 ms (engine +17910 ms) — file 66446880 B (63.4 MiB) · … — AVPlayer (remux)
```

`file` is what PopcornTorrent counts as downloaded (the file's verified pieces), `on disk` the
file's allocated bytes, `head` the start of the file on disk without a gap, then libtorrent's
download rate and the peers. The first peer and the first piece are sampled with the loading
screen's status (every 0.5 to 1 s). The readiness line is recomputed by the app from
PopcornTorrent's rule (it does not publish it).

## Tests

**⌘U**: pick the **PopcornTimeTests** scheme (or PopcornTimeMac), destination *My Mac*. The
macOS unit-test target runs in about 15 seconds, offline, in English whatever the Mac's
language: 1,040 tests, 26,449 checks of the extra sources (apibay, Knaben, Cinemeta, TVMaze, the
Top 100), the catalogs (each source's sorts and genres, the mirror races, the first pages kept
on disk), the Home feed (`PopcornTimeTests/Home`: its parsers, shelves, cache and loader on
the answers recorded on 2026-11-14, its transport on hosts played by a `URLProtocol`, and the
library behind its local shelves), the user's
library (`PopcornTimeTests/Library`: the watch state, Continue Watching and the release it remembers, the next episode, new
episodes), the links the app opens, the grids' paging (and when the Mac grid asks for its
next page), the live search and the recent searches, the profiles (`ProfileManagerTests`: the
migration, separation, switching and deletion on real defaults) and their taste and « For You »
(`ProfileTasteTests`), the release languages (`ReleaseLanguageTests`), the season-pack file choice, episode chaining (the next episode, the release in continuity, the card's countdown and
its setting, the press guard, the release kept on Resume), the
bandwidth estimate and the lighter-release offer, the loading phases, bounded storage, the
remux eviction and `FarTargetWatch` rules, a jump wait's share on screen and its requests to
the torrent engine, the
GCDWebServer log filter, the play path (the subtitles search alongside the stream, an
episode's sources behind one deadline, the `[Start]` lines, the cache purge, where the Mac
resumes) and the remux engine on synthetic Matroska streams made in memory
(`PopcornTimeTests/Remux`: the keyframe grid, a video with a single keyframe, a cluster
timestamp no movie has, the fMP4 segment layout). The
recorded API answers are in `PopcornTimeTests/Fixtures` (slimmed to the fields the parsers
read); the tests never call an API. The playback files under test are compiled into the test
bundle: a new file they come to depend on must be added to the PopcornTimeTests target too.

The torrent engine has its own tests: open PopcornTorrent's package and ⌘U. They run offline
too (a generated season pack seeded on 127.0.0.1); the old tests that streamed public
torrents are skipped unless `PT_INTERNET_TESTS=1` is set.

From the terminal, one command runs everything:

```bash
tools/run-tests.sh          # quick: the app's and PopcornTorrent's unit tests, in parallel (~15 s, < 1 min after a change)
tools/run-tests.sh full     # quick + the long benches, the independent ones in parallel
tools/run-tests.sh clean    # forget the cached builds
```

PopcornTorrent's suites need a clone of it: the workspace's local package when you point it at
one, else `POPCORNTORRENT_DIR=<clone> tools/run-tests.sh`. Without either (a plain clone of this
repository) they are skipped, and the summary says so.

| Suite | Mode | Time |
|---|---|---|
| PopcornTimeTests (macOS) | quick | ~15 s (+ ~20 s when a source changed, ~70 s from scratch) |
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
episodes, the quality chooser, the poster menu, Settings, Search (its rows of movies and shows, a catalogue that failed, Up from its results
back to the tab bar), Downloads, the Watchlist and What's New, Menu pressed twice or three times in
quick succession, Menu with the focus in the tab bar, a grid's title and Sort / Genre
scrolling away with the posters (Up from the first row reaches them, then the tab bar), the
links the app opens (`popcorntime://…` from every tab, a tab never shown yet included, a show
link with a season, a link that comes while a Settings choice is open, the 5.2.0 Top Shelf
link, broken links, a link behind the Terms of Service of a fresh install, the Home starting
once the terms are accepted) and the Continue
Watching row (an episode in progress has its card on the Shows tab, holding Select removes a
card), the Home tab (`HomeUITests`, fed from recorded answers) and the poster grids
(`GridUITests`), the next episode's card over the player and its press guard (`UpNextUITests`, on a
DEBUG fixture), and Siri Remote presses replayed on the player over a loopback test torrent
(`RemoteScriptUITests`, through `tools/remote-rig/fx-run.sh`; skipped unless `PT_REMOTE_SCRIPT`
is set), and the streaming services with and without a TMDB key, the key sheet's QR code and
Check Again included, accepted and refused (`StreamingServicesUITests`, on recorded TMDB answers
and a made-up key), and the profiles: « Who's Watching? », switching, the editor, « For You »
and Your Preferences (`ProfilesUITests`), and the Downloads page (`DownloadsUITests`). 98 tests.
They read the public catalog APIs, never press Play, and set the app up with DEBUG launch arguments, so they are built with the DEBUG
condition (the app for x86_64, the test runner for arm64). The second command names its own
DerivedData and result bundle: without them the results go to a `PopcornTime-…` folder of
Xcode's DerivedData:

```bash
xcodebuild -workspace PopcornTime.xcworkspace -scheme PopcornTimetvOSUITests \
  -destination "generic/platform=tvOS Simulator" -derivedDataPath build/ui \
  ONLY_ACTIVE_ARCH=NO SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG build-for-testing
xcodebuild test-without-building -xctestrun build/ui/Build/Products/PopcornTimetvOSUITests_*.xctestrun \
  -destination "platform=tvOS Simulator,name=<your Apple TV simulator>,arch=arm64" \
  -derivedDataPath build/ui -resultBundlePath "build/ui/results-$(date +%Y%m%d-%H%M%S).xcresult"
```

**The remote test tool** (`tools/remote-rig`, 5.3.0): `fx-run.sh` replays a script of Siri Remote
presses (pause, left ×30 then a click, ±10 s, a held skip, screenshots, waits on a log line) on
the DEBUG x86_64 app in a tvOS 26.5 simulator, through `RemoteScriptUITests` (built with the
command above), while a private trackerless test torrent is seeded on 127.0.0.1 under
`sandbox-exec` with `tools/localhost-only.sb`; it keeps the app's console (through the stdout
shim built from `ptstdout.c`), the seeder's pieces and the presses, timestamped. The script
language is described at the top of `RemoteScriptUITests.swift`, the variables at the top of
`fx-run.sh`. The seeder, the test film and their tools are local benches, not in the
repository. The simulator's remote only clicks: a touch-surface swipe can't be replayed.
