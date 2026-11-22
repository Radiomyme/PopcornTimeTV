<p align="left">
  <img src="https://i.imgur.com/agYgrmo.jpeg" alt="Popcorn Time" title="Popcorn Time" width="260">
</p>

# PopcornTimeTV — modernized fork

[![Version](https://img.shields.io/badge/version-5.3.0-blue.svg?style=flat)](https://github.com/Radiomyme/PopcornTimeTV/releases)
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
and makes the Apple TV remote's Back reliable. **5.3.0** opens on a Home screen, opens pages at
once, resumes a film that is still downloading in the native player, chains a show's episodes in the same release and adds the Apple TV Top Shelf.

## After 5.3.0 (not released yet)

On `master`, not in a release: the version stays 5.3.0 and What's New in the app is unchanged.
Contributions by [RougeCiel](https://github.com/RougeCiel), reviewed and completed before the
merge. On the Apple TV it was seen on simulators with recorded answers, then against TMDB itself
with a real key on 2026-11-21 (Settings, the Services row, the filtered pages and the grids'
Service filter, in French and after a move to the United States); what that run found is
corrected below. The iPhone, iPad and Mac side was seen on simulators and on the Mac with the
recorded answers and a made-up key only (the client underneath is the one the Apple TV run used
against TMDB). Not yet on a real Apple TV, iPhone, iPad or Mac.

**Browse by streaming service (Apple TV, iPhone / iPad, Mac)**
- **What it needs**: your own free TMDB key (themoviedb.org › Settings › API), with the country
  and the services to offer (Netflix, Amazon Prime Video, Disney Plus and Apple TV until you
  choose). Without a key the app looks and behaves as in 5.3.0, apart from that Settings
  section.
- **Where the key goes**: one field takes the v3 API key or the v4 read access token, whichever
  you paste. What is pasted is cleaned: spaces and line breaks, quotes, invisible marks, a
  leading « Bearer », a whole `Authorization: Bearer …` or curl header line, `api_key=…` or an
  address that carries it, the « API Key » label copied with it. TMDB checks the key before it
  is kept; a key TMDB refuses is not stored, one saved while TMDB does not answer is kept and
  tried at the next request. Once saved it is never shown again, only its state (Set, Refused,
  Not Set); it stays in the app's preferences on that device (no iCloud, no Keychain).
  - **Apple TV**: **Settings › Streaming Services**, typed or pasted from the iPhone; the key
    sheet shows a QR code that opens TMDB's API page on a phone (the page, never the key) and,
    once a key is stored, **Check Again**.
  - **iPhone / iPad**: **Settings › Streaming Services**, under the Home sections: the key screen
    (Paste, Save, Check Again, Remove Key, a link to TMDB's page in Safari), the country list
    and the services list.
  - **Mac**: the **Streaming** tab of Settings (⌘,): the key sheet (⌘V or Paste, Return saves,
    Escape closes), the Country menu and the Services sheet.
- **The services offered** are TMDB's for your country, the most watched first: the
  subscription and free ones, not the stores (Apple TV Store, Amazon Video, Rakuten TV, YouTube,
  Canal VOD…), whose lists would be titles they rent or sell. A service's page lists the titles
  watched there with a subscription, for free or with ads. Amazon Prime Video is the
  country's own (TMDB numbers it differently in the United States, the United Kingdom, Germany,
  Austria and Japan), even before Settings has listed a new country's services, and choosing
  another country turns the services chosen into that country's, leaving out the ones it does
  not have.
- **The Services row** on Home, under Continue Watching: picking a service shows a page filtered
  on it — its popular, recent and top rated movies and shows in your country, placeholders while
  they come, « No results » when it lists nothing, an error with Try Again when TMDB does not
  answer, or saying so when TMDB refuses the key (Settings then shows the key as refused);
  « All », or Menu at the top of the page on the Apple TV, brings the usual page
  back. The choice lasts the session; hiding the row in Settings › Home shows the usual page.
  The row and the filtered page are the same on iPhone, iPad and Mac (a tap, a click, Return or
  Space on a card; the Mac's keyboard cursor walks the cards).
- **The Service filter** of the Movies and Shows grids, after Sort and Genre (Apple TV only for
  now: the iPhone, iPad and Mac grids do not have it yet): the grid lists the service's titles,
  with the sorts and genres its lists can follow.
- **What it is not**: the services' own apps or streams. Popcorn Time plays these titles from
  its own sources, as any other title. What each service offers comes from JustWatch, through
  TMDB; this product uses the TMDB API but is not endorsed or certified by TMDB.

**Navigation and build**
- **Menu at a tab's first screen goes to Home** (Apple TV); Menu on Home leaves the app, as
  before.
- **The tvOS build with Xcode 26.2**: PopcornKit's module verifier is off (it rejected the
  CocoaPods search paths) and a local name that hid a method is renamed.

## New in 5.3.0

The same notes are shown once in the app after the update (`WhatsNewRelease.current` in
`PopcornTime/UI/Shared SwiftUI/WhatsNew.swift`; keep the two in step). Timings below were
measured on simulators with a seeder on 127.0.0.1, unless said otherwise: they are upper bounds
of single runs on a shared machine. One session ran on a real Apple TV 4K with real swarms
(see [On a real Apple TV 4K](#on-a-real-apple-tv-4k-2026-11-16) below); what changed after it
ran on simulators and on the test rig only.

**Home and pages (Apple TV, iPhone / iPad, Mac)**
- **A Home screen** the app opens on: the featured releases up top (logo, formats, Play / More
  Info / Watchlist), then Continue Watching, new episodes of your shows, trending movies and
  shows, new in 4K, the Top 100 movies and shows, your Watchlist and your
  genres; "See All" at the end of a shelf. The Top 100 movies and shows are The Pirate Bay's HD
  movies and episodes seeded the most right now (its 48-hour lists are no longer used: for movies,
  mostly old re-encodes), ranked by the seeders of all their releases, including those The Pirate Bay lists
  without an IMDb id when their name matches a known title and year; theater copies and
  screeners (CAM, TS, TC, « HQ Pre », DVDScr…) are left out, in the Top 100 grid too. It paints at once from the last visit's lists, then refreshes; an offline launch says
  how old the lists are, an error page offers Try Again. **Settings › Home** picks the content
  languages and the shelves shown, and whether the new episodes of your shows are asked of
  Cinemeta in one request (public ids, no account) or show by show of TVMaze.
- **Pages that open at once**: a title's page shows what its poster knew at once, then fills
  in; the sources arrive one by one (tvOS simulator: on screen 137 ms after the press instead of
  1,791 ms, medians of five). Play pressed before the sources is kept and runs when they are in,
  with the rules of an episode's sources (3 s deadline, 12 s at most); Menu / Cancel drops it. A
  focused (Apple TV) or hovered (Mac) poster asks its page ahead.
- **One rating everywhere**, and on the cards the two best formats (Dolby Vision, then HDR, 4K,
  Atmos) whatever the row; a source's working title ("Untitled … thriller") is not printed;
  English summaries are marked "(in English)" when the app is in another language.

**Resume and playback**
- **A film that is still downloading resumes natively**: the remux conversion jumps to the
  saved position (by the file's keyframe index), the torrent downloads that part first, and
  « Resuming at 1:40:00… » (in a dark capsule, readable on a bright picture) shows until the
  picture is there; after a second it adds how much of the media needed there is downloaded and
  the download rate (« Resuming at 1:40:00 — 45% · 9.6 MB/s »; the share never goes back and
  stays at 99 % until the media is written; seen on the Apple TV simulator, in French; iPhone /
  iPad and Mac compiled only): 5.3 s from the answer to the first frame (Apple TV simulator),
  4.7 s (iPhone simulator), 5.5 s (Mac). On a real Apple TV, a 7.7 GB Dolby Vision 8.1 + E-AC-3
  Atmos MKV resumed natively, its first frame 5.7 s after the answer (5.3.0's first device run);
  in the session of 2026-11-16 a decided « Resume » took 158.9 s (see the known limits). What
  the jump skipped is a *hole*: listed in the playlist, written when playback comes back to it.
- **Apple TV: rewinds and far jumps stay native too**, also on a real Apple TV 4K (session of
  2026-11-16: the rewind in pause played at the chosen point 8.7 s after the click, three far
  jumps landed in 6.7 to 19.8 s, never through VLC): into a hole, the conversion jumps there and
  the film starts again at the chosen point by itself, ≈ 10 s on the simulator. The target is the one the remote's gesture gives AVKit's navigation delegate (`UserNavigationTarget`
  in `PopcornKit/Managers/Playback/UserNavigation.swift`), whatever the player's clock still
  reads; if tvOS doesn't tell the app, a request for a hole behind the playhead is taken as a
  seek there (`HoleRequestRule`); a failure of the old item meanwhile (-12889) is recovered at
  the target, and the player is no longer paused during the wait, so further presses are still
  seeks and the last one wins; if AVPlayer gives up on its held seek and puts its clock back
  where the move came from (with no failure), the wait stays at the target. This fixes the
  freeze seen on a real Apple TV in 5.3.0's first device run (pause, rewind ~10 minutes, click:
  a silent spinner and a dead transport bar): in the session of 2026-11-16 the same gesture
  (pause, about 15 minutes back, click) played at the chosen point. A press made while the
  previous one's seek is still held keeps the newest target (`navigation chained on the pending
  one`; before, the second of two quick +10 s presses was dropped as "went elsewhere", seen on
  the device; the fix is covered by unit tests, the rig only showed no regression). On iPhone and Mac rewinds and far jumps were checked on the
  fix branch only, not on the merged tree, and a move made while paused stays paused at the
  target (Play resumes there), as AVKit does. With **bounded storage**, a
  rewind past what is kept is blocked with « This part hasn't been downloaded (limited
  storage). »: nothing is downloaded again and nothing goes to VLC.
- **A late jump wait is made known to the torrent engine** (full storage mode only): the
  conversion reads the file from disk, so PopcornTorrent, which rescues only the readers of its
  own HTTP server, never treated the piece it waited for as late, and slow peers could keep its
  blocks for minutes. When a jump's wait has read nothing for max(8 s, twice the time the
  missing bytes need at the current rate), the app asks the engine's own server on 127.0.0.1 for
  small ranges of the missing pieces (two requests at most; the next one as soon as one is on
  disk; the piece the conversion is stopped on even past the share's end, inside the keyframe's
  Cluster it reads whole), so that the engine takes those pieces as waited for, until the jump's
  first two segments are written (`[Resume] jump wait late`). Proven on the loopback rig with
  synthetic slow peers: 150–263 s without it, 20–28 s with it (8 runs, before the last
  adjustments), 19.4 to 21.3 s with the final code (3 runs), 12.8 s and no request on a healthy
  swarm; a held piece past the share's end is covered by unit tests only; not yet run on a
  device. Known cost: a rewind made
  during an already-late wait is 1–4 s slower (the engine keeps a cancelled request's waiter
  for a few seconds; only an engine change can end that).
- VLC remains the last resort only (a file without a keyframe index, a codec Apple can't
  decode); the resume question says so when it happens. A crash of VLCKit after « Start from
  the beginning » on Apple TV is fixed.

**Episode chaining (Apple TV, iPhone / iPad, Mac)**
- **The Next Episode card** comes 60 s before the end of an episode by default (Settings ›
  Next Episode Card: 30, 45, 60 or 90 s, at most a third of a short episode); the next episode
  still starts at the end, or on *Play Now*. The card shows the episode, the release
  line (« 1080p HEVC · same pack », « · same group », « · same quality ») and a countdown. Apple
  TV: *Play Now* (focused), *Back to the Video*, *Choose Version*; iPhone / iPad and Mac: *Play
  Now*, *Cancel* and *Choose Version* in the "…" menu (Mac: Return plays, Escape closes the card,
  not the player). On Apple TV, *Play Now* / *Continue* are ignored during the card's first
  second on screen: on the device the next episode started the instant the card appeared, most
  likely from a press still made to skip ahead (AVKit's own didAccept is not held back; the
  `outcome accepted (…, card up N s)` line will tell next time). Menu, *Back to the Video* and
  *Choose Version* are never held back; iPhone / iPad and Mac have no such guard. At the end of the countdown the next episode starts in the same release: the
  same season pack when it holds it, else the same group at the same definition, else the same
  quality class, native releases first; the quality picker is not asked again. The finished
  episode's stream is stopped and its data deleted before the next one starts. When the length
  is unknown, an "Episode finished" card with 10 s comes at the end instead.
- **« Still watching? »** after three episodes chained with no action.
- **Resume replays the release you were watching**, with no « Resume at … ? » question (a native
  jump); if it has no peer after 20 s, « Choose another source » is offered; choosing it, or a
  failure of the stream, forgets that release (on Mac the offer alone does). The Home's "Next episode" cards replay the same pack without asking.
  The release keeps its name and details on Resume: it is looked up in the title's list by its
  exact link, then by its info-hash, else the remembered release is used (on the device the
  short link of the remembered release matched nothing, so the stream ran with a nameless
  release and saved it back without its name).
- **Settings › Autoplay Next Episode** (« Enchaîner les épisodes »), on by default on the three
  apps: off, the card and the end card wait for a press.
- **Settings › Next Episode Card** (« Carte Épisode suivant »): 30, 45, 60 (default) or 90 s
  before the end, on the three apps.
- The plan (which release, which file) is made at the start of the episode, before the card;
  the `[UpNext]` lines tell it (see [Logs](#logs)).

**Grids and artwork**
- **Grids that really sort**: each sort its own list, each catalog its own genres, the first
  page painted at launch from the last visit; a page that fails offers Try Again under the
  posters instead of ending the list.
- **Lighter artwork** (`ArtworkPipeline`): posters fetched at the size they are drawn and
  kept on disk: Shows · Recently Added grid on Apple TV 8.4 MB → 0.32 MB
  (−96 %), Movies 832 KB → 235 KB (−72 %), the Mac's 21 posters 1.54 MB → 0.45 MB; 0 bytes at the
  next launch. Old movies' posters no longer stay grey (metahub, then YTS's medium poster, when
  the proxy says nothing).

**Apple TV**
- **Richer grids**: six posters per row, the sort and genre in one header line, 4K / New / New
  Episode / watched / progress marks, under every poster its year, rating and formats, and under
  the focused one its title.
- **The Top Shelf**: with the app in the top row, the Apple TV home screen shows the latest
  releases full screen with their details and Play / More Info (see
  [The Apple TV Top Shelf](#the-apple-tv-top-shelf)).
- Home: a clear white focus ring on the cards, the main button in neutral glass (white when
  focused, no longer red), a top panel whose title no longer jumps, no empty screen at launch,
  collage backdrops left out; pages without the empty grey chip and without the tab bar sliding
  over them; genres in French in French.
- A Continue Watching card keeps the focus when Movies or Shows appears or reloads: Down pressed
  before the tab has finished appearing no longer lands on the card and then jumps to the first
  poster (a defect since 4.2.0).

**iPhone / iPad**
- The Home screen in a tab, the Next Episode card above the playback bar, Settings › Home and
  Autoplay Next Episode; the iPad's landscape carousel no longer shows the previous page under
  the sidebar.
- The app is also in Italian, Spanish, Arabic and Brazilian Portuguese (translations not
  reviewed by a speaker; What's New is in English in these languages).

**Mac**
- Home first in the sidebar (⌘1), the Go and Playback menus, ⌘R; the rank of a Top in "See All"
  is a badge in the corner instead of covering the poster's printed title; no ghost text under
  the window's bar; a black first paint instead of grey; window restoration off, with a safety
  net that opens a window when the app has none.

**Tests** (see [Tests](#tests))
- Unit tests for the Home feed, the library, the artwork pipeline, the native resume and jumps
  (`RemuxResumeEngineTests`, `RemuxJumpIdentityTests`, `RemuxSequentialGoldenTests`,
  `ResumeStartTests`, `VLCResumeWatchTests`), the jump wait's share on screen and its requests
  to the engine (`JumpWaitProgressTests`, `RemuxWaitNudgeTests`), the navigation rules
  (`UserNavigationTests`), episode chaining (`UpNextPlannerTests`, `UpNextSessionTests`,
  `UpNextCountdownTests`, `UpNextResumeReleaseTests`, `RememberedReleaseTests`) and
  What's New (`WhatsNewTests`). Apple TV UI tests for Home, the grids and the Next Episode card,
  and a Siri Remote script replayed on the player over a loopback torrent
  (`tools/remote-rig/fx-run.sh`).

#### On a real Apple TV 4K (2026-11-16)

One session of 5.3.0 on the user's Apple TV 4K: a Debug build, real swarms, one launch (its
console has 849 lines; `[Start]`, `[Measure]`, `[Resume]` and `[UpNext]` lines quoted here).
- **The Home** painted from disk in 58 ms (`[Measure] home paint from disk: yes in 58.0 ms (15
  shelves)`; a Debug build on an Apple TV 4K, not the Release build on an Apple TV HD the limit
  below asks for). The Top Shelf's *More Info* and *Play* opened the page and started the stream.
- **Starts**, Play to first frame: 14.0 s to 95.1 s (a 2160p Dolby Vision film with 256 KiB
  pieces 14.0 s, of which 7.7 s engine buffer and 5.8 s metadata; one with 4 MiB pieces 40.6 s;
  episodes of a 4K season pack with 8 MiB pieces 95.1 s and 39.6 s), most of it the engine's
  start buffer on the large-piece torrents; the conversion then took 0.2 to 1.3 s. **A chained episode** (the next one of the same
  pack, from the card) started in 39.6 s.
- **Jumps**: three far jumps landed in 6.7, 13.8 and 19.8 s; **the rewind in pause** (about 15
  minutes back) played at the chosen point 8.7 s after the click; « Resume » from a show's page
  started without the question.
- **Everything native**: every start, jump and the chained episode went remux → AVPlayer, with
  no VLC line in the console. The two films declared Dolby Vision 8.1 and E-AC-3 16/JOC (Atmos)
  to the player. The season pack (the chained episode, the slow « Resume » and the 6.7 s and
  13.8 s jumps) was HDR10 with AC-3 5.1, so episode chaining with Dolby Vision or Atmos was not
  seen on the device.
- **What it found** (changed since, on simulators and the test rig only): the decided « Resume »
  at 40 % of a 12.5 GB episode with 8 MiB pieces took 158.9 s to its first frame, 110 s of it
  under a bare « Resuming at 22:35… »; on that resume the release lost its name; the Next Episode
  card was accepted the instant it appeared (most likely a press still made to skip ahead; the
  console of 5.3.0 does not tell which path accepted); the user asked
  for the card earlier than 30 s, and for The Pirate Bay's Top 100 instead of the 48-hour movie
  Top.
- **Not covered by the session**: the touch-surface swipe rewind, the resume question on a film,
  a countdown running to its end, What's New on a second launch (no `[WhatsNew]` line then),
  the HDR / Dolby Vision and Atmos badges of the TV and receiver, any iPhone, iPad or Mac
  device. **Everything changed after it** — the share and rate on screen during a wait, the
  card at 60 s and its setting, the press guard, the release kept on « Resume », the wait made
  known to the engine, the Top 100 movies and shows — **ran on simulators and the test rig only**.

**Known limits**
- **Devices**: besides the Apple TV 4K session above, nothing ran on a real device: no iPhone or
  iPad, no Mac other than this one, no Apple TV HD, no tvOS 17 to 25, no macOS 14 or 15. Not
  seen on a device: the Siri Remote on the Next Episode card, a countdown run to its end, a
  touch-surface swipe (the simulator's remote only clicks). Release builds of the three apps
  compile, carry no `-PTDebug…` hook and were launched on the tvOS simulator only.
- **Resume**: a file without a keyframe index (Matroska without Cues) can't resume fast: VLC
  reads it up to the point, under « Resuming at … », and offers after 30 s to keep waiting or
  start from the beginning. On iPhone and Mac that VLC state and its offer were never seen on
  screen. Re-aiming a real torrent adds 2.6 to 6.9 s (diagnosis). On torrents with very large
  pieces (8 MiB) the engine's start buffer alone took 36 to 90 s on the device (it waits for
  20 pieces at the head and 1 or 2 at the end, whatever the film's bitrate; 44.6 s before the
  slow « Resume » below): unchanged, the engine is frozen. The slow decided « Resume » of the device session (158.9 s): its cause, the
  engine not treating the conversion's blocking piece as late while slow peers hold its blocks,
  was shown on the rig and is answered by the app (see « A late jump wait is made known to the
  torrent engine »); that answer has not run on a device yet. Its lateness counter restarts each
  time the conversion reads a little further, so a wait that crawls one piece every few seconds
  is never helped. A « Resume » whose seed is slower than the film no longer goes to VLC after 8 s
  when the keyframe index is read and only the first segment is still to come (a slow head): it
  waits, native (seen twice on the rig before the fix, `index not on disk … after 8 s`).
- **Rewinds (Apple TV)**: after a click, the old item may play about 2 s at the target before the
  new one replaces it, so a few seconds are replayed where a jump lands (on the device the new
  item went back 1.7 s; the replacement is kept on purpose: an old item can go on with its
  sound while its picture is frozen); Pause during the wait of a rewind or a far jump takes
  « Resuming at … » and its spinner away (the pause shows as a pause; Play brings the wait back:
  before, « … — 100 % » stayed over a spinner for minutes on the rig); after a blocked
  rewind (bounded storage) AVKit restarts playback by itself at the start of what is kept. The
  server-side net only sees holes *behind* the playhead (a paused forward move that tvOS doesn't
  report is not caught). A press while the resume's item is put in place, before its start seek
  (the player has no clock yet), is not a move: AVKit's own seek is sent to the resume point
  (`[Resume] navigation to … while the resume's item is put in place — ignored`; before, it sent
  the film to 0:00 once on the rig). On iPhone the net is the only source of the target; on Mac it is not
  wired (the player's clock shows the target there). Remote presses made during the black
  « Resuming at … » cover of a decided start are ignored (the start goes to the remembered
  point).
- **Episode chaining**: the Next Episode card can stay up over a slow-download recovery near the
  end; a rewind after the end does not cancel the 10 s end card; on Mac a scrub into the last
  0.75 s inside a hole can start the next episode during the jump wait; the AVKit transport bar
  can cross the card while playback stalls; the remembered release is forgotten at 20 s on Mac
  but only on « Choose another source » or a failure on Apple TV and iPhone. Apple TV, while
  AVKit's Next Episode card is up: Play/Pause neither pauses the film nor stops the countdown,
  left / right go to the card's buttons (not the transport bar); *Play Now* / *Continue* are
  ignored during the card's first second on screen (`[UpNext] Play Now ignored: card up 0.4 s`),
  but a Select pressed while AVKit is still bringing the card in (about 1.5 s on the simulator)
  may go to the player: once it paused the film instead (the countdown then stayed frozen). The
  cards of before 5.3 that the VLC player still shows (no session) stay at 30 s, without the
  guard. A chained episode restarts its stream: 39.6 s on the device for a 4K pack with 8 MiB
  pieces. A change of the card's setting applies from the next episode. *Back to the Video* (or Menu on
  the card) dismisses it for that episode: it does not come back, and at the end the player
  closes as before 5.3 instead of starting the next one; with the card at 60 to 90 s that
  dismiss falls in the episode's last scene more often (a decision left open). The card at 60 s and the
  guard were tried only with 3-minute test episodes from a local seeder.
- **Home, pages, artwork**: a card can announce a format (Dolby Vision) that the page's
  releases don't list; the Apple TV grids (Movies, Shows, Search) keep the older focus style;
  the first paint from disk takes ≈ 125 ms on the main thread on the simulator, 58 ms on the
  Apple TV 4K in a Debug build (to measure on an Apple TV HD in Release: `[Measure] home paint
  from disk: … ms` is printed at every launch, in every build). The Top 100 movies and shows: a release
  listed without an IMDb id counts only when its title and year match a title some list already
  knows (no search is made for it: a title only such releases name stays out), and a name that
  shortens the title (« Mission Impossible 2025 ») or carries two years does not count; an
  update shows no ranking shelf until its first refresh (the 48-hour lists' cache is
  dropped). On a fresh install the Apple TV Home asks nothing before the Terms of Service are
  accepted (the iPhone and Mac apps have no such terms);
  working titles and English summaries come from Cinemeta / YTS / TVMaze. TVMaze posters and
  stills go through the `images.weserv.nl` proxy, which sees the IP address and the shows
  viewed.
- **Top Shelf**: no shared container with the app (no App Group), so no resume card, no library,
  none of the app's settings; it asks Cinemeta, YTS and apibay's 4K ranking (`.topUHD`) itself,
  even before the Terms of Service are accepted.
- **Apple TV UI tests**: holding Select on a Continue Watching card once in a while opens no
  menu (2 runs in 97 of the test alone; cause unknown, the remote's simulation is not ruled
  out). A simulator with shows in progress breaks the Shows grid layout test, which takes them
  for the first row.
- Mac: no window at launch after a killed run whose state macOS restores (seen only in tests;
  restoration is now off and a window is opened, the real case is not reproduced). Grids and
  sources as in 5.2.0: a Pirate Bay or Knaben outage reads as "nothing found"; « No torrents
  found » comes after every source (12 s at most).

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
  within about 45 seconds. A far jump stays native too when the file has a keyframe index
  (Matroska Cues), as most releases do: the conversion moves to that position, the torrent
  downloads that part first, and « Resuming at 1:40:00… », with the share of the media there
  already downloaded and the download rate, shows until the picture is there. A
  film that is still downloading resumes where you left off the same way. VLC only takes over
  when native playback is impossible: a codec Apple can't decode, a resume, a far jump or a
  rewind into a part no longer on disk in a file without a keyframe index, or a full disk (with
  bounded storage, a rewind past what is kept is blocked instead). It
  continues at the current or chosen position, under the same « Resuming at … » until playback
  really runs there (after 30 seconds it offers to keep waiting or to start from the
  beginning).
- **Bounded disk use** — played segments are kept behind the playhead as far as the free disk
  space allows (at least 3 minutes), so rewinds stay native; only on a tight disk are the oldest
  ones pruned. Torrent / remux caches are reclaimed at launch and before each stream on **all**
  platforms.

**The hidden switch `PTNativeJumpsDisabled`** (5.3.0; no UI, compiled in every build, not a
DEBUG hook): a boolean user default. Absent or `NO`, the default, the conversion jumps natively
(resume, far seeks, rewinds into holes). `YES` turns native jumps off: the conversion only runs
in file order, as in 5.2.0, and resuming a film that is still downloading goes through VLC (the
resume question then says so; VLC jumps by the keyframe index, under « Resuming at … »). The
`[Resume]` lines name it: `native jumps are off (PTNativeJumpsDisabled)`. To try it, add
`-PTNativeJumpsDisabled YES` to the scheme's launch arguments.

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
- On Apple TV, iPhone and iPad, playback resumes where you left off on every engine; a film
  that is still downloading asks « Resume at … » or « Start from the beginning » — both play
  natively (HDR, Dolby Vision, Atmos kept), and the question says so when resuming that file
  has to go through VLC

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
language: 939 tests, 25,262 checks of the extra sources (apibay, Knaben, Cinemeta, TVMaze, the
Top 100), the catalogs (each source's sorts and genres, the mirror races, the first pages kept
on disk), the Home feed (`PopcornTimeTests/Home`: its parsers, shelves, cache and loader on
the answers recorded on 2026-11-14, its transport on hosts played by a `URLProtocol`, and the
library behind its local shelves), the user's
library (`PopcornTimeTests/Library`: the watch state, Continue Watching and the release it remembers, the next episode, new
episodes), the links the app opens, the grids' paging (and when the Mac grid asks for its
next page), the live search and the recent searches, the season-pack file choice, episode chaining (the next episode, the release in continuity, the card's countdown and
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
episodes, the quality chooser, the poster menu, Settings, Search (Up from its results back to
the tab bar), Downloads, the Watchlist and What's New, Menu pressed twice or three times in
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
and a made-up key). 84 tests. They read the public catalog APIs, never
press Play, and set the app up with DEBUG launch arguments, so they are built with the DEBUG
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
