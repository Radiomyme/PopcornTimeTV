

import SwiftUI
import AVKit
import Combine
import PopcornKit
import PopcornTorrent

/// Native macOS player: torrent stream → (remux | direct) → AVKit
/// `AVPlayerView`, VLC only as an automatic fallback. Because this is a REAL
/// Mac app (not iOS-on-Mac), macOS spatializes the E-AC-3/JOC audio itself —
/// Dolby Atmos renders on built-in speakers and AirPods, which the
/// "Designed for iPad" build never could.
///
/// One sheet, possibly several streams: « Choose another source » (a source
/// that does not answer) shows the title's other releases in the sheet
/// itself, and « Lighter version » (a download slower than the video)
/// replaces the stream by a lighter release at the same position — each
/// time a new `MacPlayerSession` (a new controller and stream) takes over.
struct MacPlayerView: View {
    let playback: MacPendingPlayback
    @Environment(\.dismiss) private var dismiss
    /// The stream playing now: `playback`, then the release the user switched to.
    @State private var current: MacPendingPlayback?
    /// « Choose another source »: the releases offered (the dead one left out).
    @State private var choosing: [Torrent]?
    /// The sources that did not answer in this sheet (`MagnetLink.sourceKey`):
    /// never offered again here.
    @State private var unanswered: Set<String> = []
    /// Episode chaining (5.3.0): the next episode's card over the player,
    /// and its start in this same sheet.
    @StateObject private var upNext = MacUpNext()

    var body: some View {
        let active = current ?? playback
        Group {
            if let flow = upNext.fallback {
                // The next episode the way a click on its row plays it
                // (the new route gave up): sources, then the picker.
                nextEpisodeFlow(flow)
            } else if let torrents = choosing {
                MacQualityPickerSheet(title: active.title, torrents: torrents) { torrent in
                    choosing = nil
                    guard let torrent else { return dismiss() }
                    print("[Player] another source chosen: \(torrent.quality ?? "?")")
                    current = MacPendingPlayback(torrent: torrent, media: active.media, title: active.title,
                                                 sources: active.knownSources)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #if DEBUG
                .onAppear { MacDebugHooks.snapshotPlayerWindow(named: "choose-source", after: 1) }
                #endif
            } else {
                MacPlayerSession(playback: active,
                                 alternatives: alternatives(to: active),
                                 onChooseAnotherSource: { failed in
                                     print("[Player] choose another source (instead of \(failed.quality ?? "?"))")
                                     unanswered.insert(MagnetLink.sourceKey(of: failed.url))
                                     choosing = alternatives(to: active)
                                 },
                                 onSwitch: { torrent, fraction in
                                     current = MacPendingPlayback(torrent: torrent, media: active.media, title: active.title,
                                                                  sources: active.knownSources, startFraction: fraction)
                                 },
                                 escapeIsTaken: upNext.card != nil || upNext.choosing != nil,
                                 onStarted: { controller in
                                     upNext.begin(active, controller: controller, host: upNextHost())
                                 })
                    // A new stream for each release: a new controller.
                    .id(active.id)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Above AVKit's floating controls, clear of them.
            if let card = upNext.card, upNext.choosing == nil, upNext.fallback == nil, choosing == nil {
                UpNextCardView(card: card,
                               playNow: { upNext.session?.accept() },
                               cancel: { upNext.session?.cancel() },
                               chooseVersion: { upNext.session?.chooseVersion() })
                    .padding(.trailing, 24)
                    .padding(.bottom, 96)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay { upNextChooser }
        .animation(.easeInOut(duration: 0.25), value: upNext.card?.kind)
        // The sheet closes: nothing starts.
        .onDisappear { upNext.playerClosed() }
        #if DEBUG
        .onChange(of: upNext.card?.kind) { _, kind in
            guard let kind, let card = upNext.card else { return }
            MacDebugHooks.snapshotPlayerWindow(named: "upnext-\(kind.rawValue)-\(card.episodeID)", after: 1.5)
        }
        .onChange(of: upNext.choosing?.episode.id) { _, id in
            if let id { MacDebugHooks.snapshotPlayerWindow(named: "upnext-chooser-\(id)", after: 1) }
        }
        #endif
    }

    /// What the next episode's session asks of the sheet (`UpNextSession.Host`).
    private func upNextHost() -> UpNextSession.Host {
        UpNextSession.Host(
            startNext: { plan in
                guard let torrent = plan.torrent, let controller = upNext.controller else { return false }
                // The finished episode's stream goes first, its data deleted
                // (bounded storage; error -7 on the same pack), then the next
                // one starts in this sheet — a new session, a new stream.
                upNext.choosing = nil
                choosing = nil
                let next = MacUpNext.playback(of: plan.episode, torrent: torrent, sources: plan.sources,
                                              subtitles: plan.subtitles)
                controller.stopForNextEpisode {
                    unanswered = []
                    current = next
                }
                return true
            },
            fallBack: { episode in
                upNext.choosing = nil
                let lookUp = {
                    upNext.lookUp(episode) { next in
                        unanswered = []
                        current = next
                    }
                }
                if let controller = upNext.controller { controller.stopForNextEpisode(then: lookUp) } else { lookUp() }
            },
            chooseVersion: { plan in upNext.choosing = plan },
            closePlayer: { dismiss() })
    }

    /// « Choose Version »: the next episode's releases over the video, which
    /// plays on behind.
    @ViewBuilder private var upNextChooser: some View {
        if let plan = upNext.choosing {
            ZStack {
                Color.black.opacity(0.55)
                MacQualityPickerSheet(title: MacUpNext.title(of: plan.episode), torrents: MacUpNext.chooserList(plan)) { torrent in
                    upNext.choosing = nil
                    if let torrent {
                        upNext.session?.chose(torrent)
                    } else {
                        upNext.session?.choiceCancelled()
                    }
                }
                .frame(width: 560, height: 480)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .environment(\.colorScheme, .dark)
            }
        }
    }

    /// Today's flow for the next episode, the player stopped: its sources
    /// being looked up, the picker (« Always Ask »), or none found.
    @ViewBuilder private func nextEpisodeFlow(_ flow: MacUpNext.Fallback) -> some View {
        switch flow {
        case .picking(let episode, let torrents):
            MacQualityPickerSheet(title: MacUpNext.title(of: episode), torrents: torrents) { torrent in
                guard let torrent else { return dismiss() }
                upNext.fallback = nil
                unanswered = []
                current = MacUpNext.playback(of: episode, torrent: torrent, sources: torrents, subtitles: nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #if DEBUG
            .onAppear { MacDebugHooks.snapshotPlayerWindow(named: "upnext-fallback-picker", after: 1) }
            #endif
        case .looking(let episode), .nothing(let episode):
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 12) {
                    if case .looking = flow {
                        ProgressView()
                            .controlSize(.large)
                            .frame(width: 40, height: 40)
                        Text(MacUpNext.title(of: episode))
                            .font(.headline)
                    } else {
                        Text("No torrents found")
                            .font(.headline)
                        Text("Torrents could not be found for the specified media.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("OK") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Button {
                    dismiss()
                } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                    .padding(12)
            }
            .background(Color.black)
        }
    }

    /// The other releases of the title, best first: not the one playing,
    /// nor one that did not answer in this sheet. Runtimes attached
    /// (`knownSources`): the picker shows bitrates and warnings, and its
    /// recommendation weighs them.
    private func alternatives(to playback: MacPendingPlayback) -> [Torrent] {
        let playing = MagnetLink.sourceKey(of: playback.torrent.url)
        return playback.knownSources.filter {
            let key = MagnetLink.sourceKey(of: $0.url)
            return key != playing && !unanswered.contains(key)
        }.sorted(by: >)
    }
}

// MARK: - Episode chaining (5.3.0)

/// The sheet's side of episode chaining: the `UpNextSession` of the episode
/// playing, its card, « Choose Version » over the video, and today's flow
/// (the episode's sources, then the automatic quality or the picker) when
/// the new route gives up. The sheet chains in place: the finished
/// episode's stream stops with its data deleted
/// (`MacPlayerController.stopForNextEpisode`), then a new `MacPlayerSession`
/// plays the next episode through the usual start (remux, AVPlayer direct,
/// VLC last, decided on the real file name).
@MainActor
final class MacUpNext: ObservableObject {
    /// The card to show (nil: none).
    @Published private(set) var card: UpNextCardState?
    /// « Choose Version »: the plan whose releases the picker shows over the
    /// video playing.
    @Published var choosing: UpNextPlan?
    /// Today's flow for the next episode, the player stopped (`Host.fallBack`).
    @Published var fallback: Fallback?

    enum Fallback {
        case looking(Episode)
        case picking(Episode, [Torrent])
        case nothing(Episode)
    }

    private(set) var session: UpNextSession?
    /// The stream playing now (the sheet's current `MacPlayerSession`).
    private(set) weak var controller: MacPlayerController?
    private var cardSubscription: AnyCancellable?

    /// A stream of the sheet started: an episode gets its session (nil — the
    /// player as before 5.3 — for a movie, the last episode, a show without
    /// its guide).
    func begin(_ playback: MacPendingPlayback, controller: MacPlayerController, host: UpNextSession.Host) {
        self.controller = controller
        cardSubscription = nil
        card = nil
        choosing = nil
        guard let episode = playback.media as? Episode else {
            session?.playerClosed()
            session = nil
            return
        }
        let started = UpNextSession.begin(episode: episode, playing: playback.torrent, streamer: controller.streamer, host: host)
        session = started
        controller.upNext = started
        cardSubscription = started?.$card.sink { [weak self] card in
            MainActor.assumeIsolated { self?.card = card }
        }
    }

    /// The sheet closed: nothing starts.
    func playerClosed() {
        session?.playerClosed()
        session = nil
        cardSubscription = nil
        card = nil
        choosing = nil
    }

    /// `Host.fallBack`: the episode's sources (`EpisodeSourceResolver`, as
    /// its row on the page), then the automatic quality — or the picker, or
    /// « No torrents found ».
    func lookUp(_ episode: Episode, start: @escaping (MacPendingPlayback) -> Void) {
        fallback = .looking(episode)
        guard let show = episode.show else {
            fallback = episode.torrents.isEmpty ? .nothing(episode) : .picking(episode, episode.torrents.sorted(by: >))
            return
        }
        let picksAlone = MacAutoQuality.picksAlone
        EpisodeSourceResolver.shared.resolve(showId: show.id, showTitle: show.title, season: episode.season,
                                             episode: episode.episode,
                                             isEnough: { $0.count > 0 && (!picksAlone || $0.awaited.isEmpty) },
                                             completion: { [weak self] sources in
            MainActor.assumeIsolated {
                guard let self, case .looking(let waiting)? = self.fallback, waiting.id == episode.id else { return }
                let torrents = sources.merged(withBase: episode.torrents, runtime: Torrent.mediaRuntime(of: episode))
                    .sorted(by: >)
                print("[UpNext] Mac fallback \(episode.id): \(torrents.count) release(s), "
                      + (picksAlone ? "automatic quality" : "« Always Ask »: the picker"))
                if torrents.isEmpty {
                    self.fallback = .nothing(episode)
                } else if let pick = MacAutoQuality.pick(from: torrents) {
                    self.fallback = nil
                    start(MacUpNext.playback(of: episode, torrent: pick, sources: torrents, subtitles: nil))
                } else {
                    self.fallback = .picking(episode, torrents)
                }
            }
        })
    }

    /// "Show — S01E02", as the page names an episode's player.
    static func title(of episode: Episode) -> String {
        let number = "S\(String(format: "%02d", episode.season))E\(String(format: "%02d", episode.episode))"
        guard let show = episode.show?.title, !show.isEmpty else { return number }
        return "\(show) — \(number)"
    }

    /// The next episode's stream: its subtitles when the search already
    /// answered, its releases (the « Choose another source » and lighter
    /// release lists).
    static func playback(of episode: Episode, torrent: Torrent, sources: [Torrent], subtitles: [Subtitle]?) -> MacPendingPlayback {
        var media = episode
        if let subtitles, !subtitles.isEmpty { media.subtitles = subtitles }
        return MacPendingPlayback(torrent: torrent, media: media, title: title(of: episode),
                                  sources: sources.withMediaRuntime(of: episode, show: episode.show))
    }

    /// « Choose Version »'s list: the planned release first, then the others.
    static func chooserList(_ plan: UpNextPlan) -> [Torrent] {
        var list = plan.sources.sorted(by: >)
        if let planned = plan.torrent {
            list.removeAll { MagnetLink.sourceKey(of: $0.url) == MagnetLink.sourceKey(of: planned.url) }
            list.insert(planned, at: 0)
        }
        return list
    }
}

/// « Resume » on a page, and a Home card that plays (decisions D2, D4): the
/// release remembered for the title (`UpNextResume`) is played again
/// without asking — its saved position passed as a DECIDED start, so the
/// player resumes there natively (a jump of the conversion) without the
/// « Resume at … ? » question —, with 20 s of patience (D5) before another
/// source is offered. nil: the usual flow.
enum MacUpNextResume {
    /// - Parameter candidates: the episode's releases when known (nil: not
    ///   yet — `resolveAndPlay` asks again with them): an episode not
    ///   started then plays the release in clear continuity with the show's
    ///   last one (D4), and a pack only VLC plays waits for them (native first).
    static func playback(for media: Media, title: String, sources: [Torrent], candidates: [Torrent]? = nil) -> MacPendingPlayback? {
        guard let choice = UpNextResume.choice(mediaID: media.id, candidates: candidates) else { return nil }
        // 0 for a title not started or finished: from the beginning.
        let position = MacPlaybackProgress.resumePoint(for: media)
        // « Resume » (a saved position), or an episode not started whose
        // season pack the show was played from holds it, or a release in
        // clear continuity (D4). A finished title played again goes
        // through the usual choice.
        guard position > 0 || choice.rule != .sameRelease else { return nil }
        print(choice.logLine(mediaID: media.id))
        guard choice.replaysRemembered else {
            print("[UpNext] resume \(media.id): in continuity with the show's last release, from the beginning")
            return MacPendingPlayback(torrent: choice.torrent, media: media, title: title, sources: sources)
        }
        let start: Float = choice.rule == .sameRelease ? position : 0
        print("[UpNext] resume \(media.id): \(choice.rule == .samePack ? "same pack" : "same release") at "
              + "\(Int(start * 100)) % (decided, no question)")
        return MacPendingPlayback(torrent: choice.torrent, media: media, title: title, sources: sources,
                                  startFraction: start, patience: UpNextResume.patience)
    }
}

#if DEBUG
/// The episode-chaining bench on the Mac (`UpNextDebugHooks`):
/// `-PTDebugPlayEpisode S01E01 -PTDebugPlayTorrent <.torrent>` plays that
/// episode of the made-up show « PT Test Show » in the player sheet; with
/// `-PTDebugPressResume YES` the sheet opens on what « Resume » on its page
/// would play (`MacUpNextResume`: the release remembered, at its saved
/// position), the .torrent given only when nothing is remembered.
enum MacUpNextDebug {
    @MainActor
    static var playback: MacPendingPlayback? {
        guard let (episode, torrent) = UpNextDebugHooks.episodeToPlay else { return nil }
        let title = MacUpNext.title(of: episode)
        let sources = episode.torrents
        if UserDefaults.standard.bool(forKey: "PTDebugPressResume") {
            if let resume = MacUpNextResume.playback(for: episode, title: title, sources: sources) { return resume }
            print("[UpNextDebug] « Resume » on \(episode.id): no release remembered — the usual flow")
        }
        print("[UpNextDebug] playing \(episode.id) from \(torrent.url)")
        return MacPendingPlayback(torrent: torrent, media: episode, title: title, sources: sources)
    }
}
#endif

/// One stream in the player sheet.
private struct MacPlayerSession: View {
    let playback: MacPendingPlayback
    /// The title's other releases (« Choose another source » shows only
    /// when there is one).
    let alternatives: [Torrent]
    let onChooseAnotherSource: (Torrent) -> Void
    /// Plays a lighter release from a position (0…1) instead of this stream.
    let onSwitch: (Torrent, Float) -> Void
    /// The next episode's card (or its chooser) is up: Escape is its
    /// « Cancel », not the player's close.
    var escapeIsTaken = false
    /// The stream started (episode chaining: `MacUpNext.begin`).
    var onStarted: (MacPlayerController) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    /// `.key` while the sheet's window has the keyboard (the Playback
    /// menu's bare keys: `MacPlaybackCommandCenter`).
    @Environment(\.controlActiveState) private var controlActiveState

    @StateObject private var controller = MacPlayerController()

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let vlcURL = controller.vlcURL {
                // Resumes where the native player stopped.
                MacVLCPlayerView(url: vlcURL, subtitles: controller.subtitles, media: playback.media,
                                 startPosition: controller.vlcStartPosition,
                                 resumePoint: controller.resumePoint, nativeHighWater: controller.highWater,
                                 boundedStorage: BoundedStorageSession.session(for: controller.streamer),
                                 streamer: controller.streamer,
                                 deficitMonitor: controller.deficitMonitor,
                                 upNext: controller.upNext)
                    .ignoresSafeArea()
            } else if let player = controller.player {
                MacAVPlayerRepresentable(player: player, onPictureInPictureChanged: { active in
                    controller.pictureInPictureChanged(active)
                })
                    // Never laid out at zero size (sheet appearing, VLC swap):
                    // AVKit's content view would get width / height == 0
                    // constraints it can't satisfy.
                    .frame(minWidth: 320, minHeight: 180)
                    .ignoresSafeArea()
                // Direct MP4: OpenSubtitles drawn over the video (the remux
                // path exposes them as native HLS tracks instead).
                if let cues = controller.cueController {
                    SubtitleOverlayText(controller: cues)
                        .allowsHitTesting(false)
                }
                // The conversion moves to a position (a native resume of a
                // film still downloading, a far seek, a rewind into what a
                // jump skipped): « Resuming at 1:40:00… » — over black for
                // the resume, whose item loads at 0:00 before its seek (its
                // first frame must not show).
                if let resuming = controller.resumingText {
                    ZStack {
                        if controller.isResumeCovered { Color.black }
                        VStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.large)
                            Text(resuming)
                                .font(.headline)
                        }
                        .padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }
                // Download starvation: the native player waits for the data
                // (and resumes by itself) instead of switching to VLC. Also
                // shown, without the download line, while an item stuck on
                // complete data is rebuilt, and while a start part-way (the
                // saved position) waits for the torrent to fetch that part:
                // the player is paused meanwhile, not failed.
                else if controller.isWaitingForData || controller.isStartingPartWay {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Buffering…")
                            .font(.headline)
                        if controller.isWaitingForData && !controller.isRebuildingStuckItem {
                            Text("The download is slower than playback")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }
            } else {
                loadingView
            }

            if controller.showStats && controller.vlcURL == nil {
                Text(controller.statsText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .padding(16)
            }

            // The download can't keep up with this release: a lighter one
            // at the same position, or carry on (native and VLC alike).
            if let monitor = controller.deficitMonitor {
                BandwidthDeficitBanner(monitor: monitor)
            }

            // Subtitle menu (direct path) + close; Escape closes too.
            HStack(spacing: 10) {
                Spacer()
                if controller.vlcURL == nil, let cues = controller.cueController {
                    SubtitleMenuButton(controller: cues)
                }
                Button {
                    dismiss()
                } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    // Escape closes the next episode's card first, then the player.
                    .keyboardShortcut(escapeIsTaken ? nil : KeyboardShortcut(.escape, modifiers: []))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .trailing)

            // Hidden toggle bound to "n" — same shortcut as iOS/tvOS.
            Button("") { controller.showStats.toggle() }
                .keyboardShortcut("n", modifiers: [])
                .opacity(0)
        }
        // Bounded storage: a rewind stopped at the earliest point still on disk.
        .boundedStorageToast(controller.boundedToast)
        .background(Color.black)
        .onAppear {
            // The decoded posters and backdrops are not needed while a film
            // plays: their memory goes (the disk cache keeps them).
            ArtworkPipeline.shared.purgeMemory()
            controller.onSwitch = onSwitch
            controller.start(playback)
            onStarted(controller)
        }
        .onDisappear {
            MacPlaybackCommandCenter.shared.setKeyboard(false, session: controller)
            controller.stop()
        }
        .onChange(of: controlActiveState, initial: true) { _, state in
            MacPlaybackCommandCenter.shared.setKeyboard(state == .key, session: controller)
        }
        #if DEBUG
        .onChange(of: controller.deficitOfferID) { _, id in
            if id != nil { MacDebugHooks.snapshotPlayerWindow(named: "deficit-offer", after: 1) }
        }
        .onChange(of: controller.loadingPhase.isNotResponding) { _, stalled in
            guard stalled else { return }
            MacDebugHooks.snapshotPlayerWindow(named: "loading-stall", after: 1)
            BandwidthDebugHooks.loadingStalled(choose: alternatives.isEmpty ? nil : { onChooseAnotherSource(playback.torrent) },
                                               keepWaiting: { controller.keepWaiting() })
        }
        #endif
    }

    /// Until the stream is ready: what the torrent is doing (from the first
    /// second: looking for peers, getting the torrent's details, buffering),
    /// and when the source does not answer, another source or more time.
    private var loadingView: some View {
        VStack(spacing: 14) {
            if let question = controller.resumeQuestion {
                resumeQuestionView(question)
            } else if controller.loadingPhase.isBuffering {
                ProgressView(value: controller.buffering, total: 1.0)
                    .frame(width: 320)
            } else if controller.showsLoadingSpinner && !controller.loadingPhase.isNotResponding {
                // Fixed size, in a container that never scales: AppKit's
                // indicator has fixed lengths (no min <= max warnings).
                ProgressView()
                    .controlSize(.large)
                    .frame(width: 40, height: 40)
            }
            if controller.resumeQuestion == nil {
                Text(controller.statusLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }
            // Bounded storage: the film is larger than the free space.
            if let note = controller.boundedNote {
                Label(note, systemImage: BoundedStorageUX.symbolName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if controller.resumeQuestion != nil {
                // The question's own buttons are the only ones.
            } else if controller.episodeNotInTorrent {
                // A season pack without the episode: the title's other releases.
                if !alternatives.isEmpty {
                    Button(LoadingPhase.chooseAnotherSourceTitle) { onChooseAnotherSource(playback.torrent) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .padding(.top, 4)
                }
            } else if controller.loadingPhase.isNotResponding {
                HStack(spacing: 12) {
                    if !alternatives.isEmpty {
                        Button(LoadingPhase.chooseAnotherSourceTitle) { onChooseAnotherSource(playback.torrent) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                    Button(LoadingPhase.keepWaitingTitle) { controller.keepWaiting() }
                        .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            } else if controller.loadingIsSlow && !alternatives.isEmpty {
                // Alive but minutes from playing: another source, beside
                // the progress.
                Button(LoadingPhase.chooseAnotherSourceTitle) { onChooseAnotherSource(playback.torrent) }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    /// A saved position on an MKV still downloading (`MacResumeQuestion`):
    /// resume there — natively when the conversion can jump there, else
    /// through VLC, as its message says —, or natively from the beginning.
    /// Return resumes; Escape closes the player, as everywhere in the sheet.
    private func resumeQuestionView(_ question: MacResumeQuestion) -> some View {
        VStack(spacing: 10) {
            Text(MacResumeQuestion.title)
                .font(.title3.weight(.semibold))
            Text(question.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            HStack(spacing: 12) {
                Button(question.resumeTitle) { controller.answerResumeQuestion(resume: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button(MacResumeQuestion.fromStartTitle) { controller.answerResumeQuestion(resume: false) }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 6)
        }
    }
}

/// The loading screen's question when the title has a saved position and
/// its file is an MKV still downloading: resume there — natively when the
/// remux can move its conversion to that position (HDR, Dolby Atmos kept),
/// through the VLC player when it can't — or play natively from the
/// beginning. The tvOS / iOS native player's question
/// (RemuxAVPlayerViewController), same texts.
struct MacResumeQuestion: Equatable {
    /// The saved 0…1 position.
    let fraction: Float
    /// The movie's length once the MKV header is read (0 before): the
    /// button then shows the clock time instead of the percentage.
    var durationSeconds: Double = 0
    /// What « Resume at … » means (`ResumePolicy.resumeEngine`).
    var engine: ResumePolicy.ResumeEngine = .native

    /// Says which: resuming stays native, or goes through VLC.
    var message: String { ResumePolicy.resumeQuestionMessage(for: engine) }

    var resumeTitle: String {
        String(format: NSLocalizedString("Remux.Resume.At", value: "Resume at %@",
                                         comment: "Native player: resume button; %@ = the position, e.g. 1:02:07"),
               ResumePolicy.resumeLabel(fraction: fraction, durationSeconds: durationSeconds))
    }

    static var title: String {
        NSLocalizedString("Remux.Resume.Title", value: "Resume playback?",
                          comment: "Native player: resume question while the file still downloads")
    }

    static var fromStartTitle: String {
        NSLocalizedString("Remux.Resume.FromStart", value: "Start from the beginning",
                          comment: "Native player: play from the start, natively")
    }
}

/// Owns the torrent stream, the remux session, the AVPlayer and the switch
/// to VLC.
@MainActor
final class MacPlayerController: ObservableObject {
    /// The profile that started the play: its position goes there, even
    /// once another is in use (`PlaybackRecorder.save`).
    let profileID = ProfileManager.shared.activeID
    @Published var player: AVPlayer?
    @Published var buffering: Double = 0
    @Published var statusLine = LoadingPhase.starting.line
    /// Where the stream's preparation is (`LoadingPhaseTracker`): the
    /// loading screen's line from the first second, and the « source not
    /// answering » state.
    @Published private(set) var loadingPhase: LoadingPhase = .starting
    /// The loading screen's spinner (not once the stream failed or stopped).
    @Published private(set) var showsLoadingSpinner = true
    /// Buffering, but minutes from playing (`LoadingPhaseTracker.isSlow`).
    @Published private(set) var loadingIsSlow = false
    /// The stream failed because the torrent lacks the episode (a season
    /// pack, PopcornTorrent -9): the loading screen offers another source.
    @Published private(set) var episodeNotInTorrent = false
    /// The download against the release's bitrate (`BandwidthDeficitBanner`).
    @Published private(set) var deficitMonitor: BandwidthDeficitMonitor?
    /// The offer shown now (DEBUG snapshots).
    @Published private(set) var deficitOfferID: UUID?
    /// Plays a lighter release from a position (0…1) instead of this
    /// stream (the sheet: `MacPlayerView`). Set before `start`.
    var onSwitch: ((Torrent, Float) -> Void)?
    @Published var showStats = true
    @Published var statsText = ""
    /// Set when the native path gives up (DTS / TrueHD-only audio, VP9,
    /// AVI/TS container, AVPlayer failure…) — the view swaps to the VLC
    /// fallback player at this URL, on the SAME torrent stream.
    @Published var vlcURL: URL?
    /// 0…1 position VLC resumes at (where AVPlayer stopped).
    @Published private(set) var vlcStartPosition: Float = 0
    /// External subtitles drawn over the direct (MP4) AVPlayer path.
    @Published private(set) var cueController: SubtitleCueController?
    /// OpenSubtitles list — remux HLS renditions, VLC playback slaves.
    @Published private(set) var subtitles: [Subtitle] = []
    /// Download starvation: the native player waits for the data (buffering
    /// overlay) and resumes by itself.
    @Published private(set) var isWaitingForData = false
    /// That overlay is up for an item stuck on complete data being rebuilt
    /// (no "download slower" line).
    @Published private(set) var isRebuildingStuckItem = false
    /// The start seek (`seekToStartFraction`) is still to land: the player
    /// waits paused, under the same overlay (no "download slower" line).
    @Published private(set) var isStartingPartWay = false
    /// « Resuming at 1:40:00… » while the conversion moves to a position (a
    /// native resume, a far seek, a rewind into what a jump skipped); nil:
    /// nothing of the kind is waited on.
    @Published private(set) var resumingText: String?
    /// That text shows over black: a native resume, until the picture at its
    /// position plays (the item loads at 0:00 before its seek).
    @Published private(set) var isResumeCovered = false
    /// Bounded storage: the loading screen's line (nil in full mode).
    @Published private(set) var boundedNote: String?
    /// Bounded storage's message over the video (a limited rewind).
    @Published private(set) var boundedToast: BoundedStorageToastMessage?
    /// When `boundedNote` was last computed (it reads the free space).
    private var boundedNoteAt: TimeInterval = -.infinity
    /// The pending check after a burst of time jumps (`scheduleBoundedRewindCheck`).
    private var boundedRewindCheck: DispatchWorkItem?
    /// Bounded storage ended playback for good (`endPlaybackForBoundedStorage`):
    /// the status screen keeps saying why, nothing restarts it.
    private var boundedPlaybackEnded = false

    /// The torrent's direct HTTP endpoint (direct AVPlayer path, VLC).
    private var directURL: URL?
    private var media: Media?
    private var remux: RemuxPlayback?
    private var failureObserver: AVPlayerItemFailureObserver?
    private var cueSubscription: AnyCancellable?
    private var statsTimer: Timer?
    /// The `[Start]` trace's first-frame mark (`attachPlayer`).
    private var firstFrameWatch: FirstFrameWatch?
    private var stopped = false
    /// The controllers that started a stream (weak): one still playing in
    /// another window keeps the purge before a new stream away (`start`).
    private static let liveControllers = NSHashTable<MacPlayerController>.weakObjects()
    private var loggedAtmosVerdict = false
    private var engineLine = "…"
    /// What AVPlayer plays (master playlist / torrent HTTP endpoint): the
    /// starvation recovery rebuilds its item on it.
    private var playbackURL: URL?
    private var isDirectPlayback = false
    /// Keeps the native player through download starvation (slow swarm):
    /// rebuilds the item once the data is there instead of falling back.
    private lazy var starvation: PlaybackStarvationRecovery = makeStarvationRecovery()
    /// Last position / duration read from a ready item (1 Hz) — while a
    /// starvation recovery runs, the position it recovers.
    private var lastKnownTime: Double?
    private var lastKnownDuration: Double?
    /// Last position playback actually reached (sampled 1 Hz): the `played`
    /// position reported to the remux — never a held seek target.
    private var playedPosition = PlayedPositionTracker()
    /// The user's seek target AVPlayer still holds (past the download / the
    /// remux), noted at every tick and time jump of a healthy item: what a
    /// failure during the hold recovers — or hands VLC — instead of the reset
    /// `currentTime()` (both routes).
    private var heldSeek = HeldSeekWatch()
    /// Remux path: the pace of the remux frontier toward that held target
    /// while the user wants playback — a target it can't reach soon goes to
    /// VLC at once (`checkFarSeekTarget`).
    private var farTarget = FarTargetWatch()
    /// Remux path, remux finished: an item frozen while the user wants it
    /// playing (sampled 1 Hz) → natural end / rebuild / VLC.
    private var stuckWatch = StuckPlaybackWatch()
    /// Bounded storage, direct path: AVPlayer waiting with the data on disk
    /// (sampled 1 Hz) → the item is rebuilt (`checkDirectStall`).
    private var directStall = BoundedDirectStallWatch()
    /// Remux path: the item AVPlayer started on live EVENT playlists, replaced
    /// once when the remux has finished (`rebuildLiveBornItemIfEnded`).
    private var liveBornWatch = LiveBornItemWatch()
    /// Remux path: an OpenSubtitles list that came after the item read the
    /// master playlist — the item is rebuilt once for it
    /// (`rebuildForLateSubtitlesIfDue`).
    private var lateSubtitles = LateSubtitlesWatch()
    /// Picture in Picture is on: the stuck-playback safety net stays out of
    /// it.
    private var isPictureInPictureActive = false
    /// The user's play / pause intent: what a starvation recovery and any
    /// rebuild of the item end in.
    private var playIntent = PlaybackIntentWatch()
    /// The player's rate changes (`playerRateDidChange`) and its current
    /// item's time jumps (`reportPlaybackPositions` at once).
    private var playerObservers: [NSObjectProtocol] = []
    /// alextud's PopcornTorrent has no singleton — each stream owns an instance.
    let streamer = PTTorrentStreamer()
    /// Follows the stream's preparation (phase line, stall rules).
    private var loadingTracker = LoadingPhaseTracker()
    /// The stream is ready (or failed): the loading phase no longer moves.
    private var loadingDone = false
    /// 0…1 position the native player starts at (0: from the beginning):
    /// the title's saved position, or where a switch to a lighter release
    /// left the other one — decided once the stream is ready
    /// (`ResumePolicy.start`).
    private var startFraction: Float = 0
    /// Where the user already chose to start (a switch to a lighter
    /// release): wins over the saved position, never asked about.
    private var decidedStart: Float?
    /// The start seek waits for the item to be ready.
    private var startSeekObservation: NSKeyValueObservation?
    /// A start seek is to come: its item is not ready yet.
    private var awaitingStartSeek = false
    /// The start seek is in flight, towards this time (player timeline, s).
    private var startSeekTarget: Double?
    /// A saved position on an MKV still downloading: the loading screen
    /// asks (`answerResumeQuestion`). nil: nothing to ask, or answered.
    @Published private(set) var resumeQuestion: MacResumeQuestion?
    /// The hidden switch (`RemuxPlayback.nativeJumpsEnabled`), read when the
    /// stream is ready.
    private var nativeJumps = true
    /// A saved position on an MKV still downloading whose engine is not
    /// known yet (`ResumePolicy.resumeEngine`): asked about — or, `asks`
    /// false, a decided start: resumed without a question — once it is
    /// (`resolvePendingResume`).
    private var pendingResume: (fraction: Float, asks: Bool)?
    /// When the player started waiting for that engine.
    private var resumeWaitStartedAt: TimeInterval?
    /// A native resume was accepted and the picture at its position does not
    /// play yet (`resume(at:engine:how:)` … `finishNativeResume`).
    private var isResumingNatively = false
    /// The position of the jump whose « Resuming at … » is up (a far seek, a
    /// rewind into a hole — not the start's native resume).
    private var jumpLabelTarget: Double?
    /// The `[Resume]` log's clocks (uptime): the remux started, it said the
    /// resume is native (the torrent is turned there from then), the
    /// question came up, the answer.
    private var resumeStartedAt: TimeInterval?
    private var resumeNativeSince: TimeInterval?
    private var resumeQuestionShownAt: TimeInterval?
    private var resumeAnsweredAt: TimeInterval?
    /// The remux playlist that got ready while that question was up.
    private var pendingPlaylistURL: URL?
    private var deficitSubscription: AnyCancellable?
    #if DEBUG
    /// BoundedStorageDebugHooks' seek / pause observers.
    private var debugObservers: [NSObjectProtocol] = []
    #endif
    /// The saved progress this session protects (read when it starts; 0 for
    /// none or a finished title) and the furthest position (0…1) reached
    /// natively (1 Hz): `MacPlaybackProgress.save`'s rules. Both go to the
    /// VLC fallback, which saves the rest of the session.
    private(set) var resumePoint: Float = 0
    private(set) var highWater: Float = 0
    /// Episode chaining: the session of the episode playing (`MacUpNext`),
    /// told the position every second and the file's end; nil for a movie.
    weak var upNext: UpNextSession?
    /// The file's end was told to `upNext` (once).
    private var toldUpNextTheEnd = false
    /// A release remembered for the title (D5, `MacPendingPlayback.patience`):
    /// how long without a peer before another source is offered, and the
    /// title whose release is forgotten when it does not answer or fails.
    private var patience: (seconds: TimeInterval, mediaID: String, sourceKey: String)?
    /// A peer was connected at least once (the patience no longer counts).
    private var sawPeer = false
    /// « Keep waiting » was chosen: the usual rules only.
    private var patienceWaived = false
    private var forgotRelease = false

    func start(_ playback: MacPendingPlayback) {
        #if DEBUG
        // BoundedStorageDebugHooks' scripted seeks and pauses.
        debugObservers = [
            NotificationCenter.default.addObserver(forName: .ptDebugSeek, object: nil, queue: .main) { [weak self] note in
                let seconds = note.userInfo?["seconds"] as? Double
                MainActor.assumeIsolated {
                    guard let self, let seconds, self.vlcURL == nil, let player = self.player else { return }
                    let now = player.currentTime().seconds
                    print("[BoundedDebug] AVPlayer seek \(Int(now)) → \(Int(seconds)) s")
                    // Limited like a user's seek (bounded storage).
                    if let reference = self.playedPosition.lastPlayedTime ?? (now.isFinite ? now : nil),
                       let landing = BoundedStorageUX.limitedRewindTarget(seconds, from: reference, session: self.boundedStorage) {
                        self.limitRewind(target: seconds, from: reference, landing: landing)
                        return
                    }
                    player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
            },
            NotificationCenter.default.addObserver(forName: .ptDebugPlayback, object: nil, queue: .main) { [weak self] note in
                let playing = note.userInfo?["playing"] as? Bool
                MainActor.assumeIsolated {
                    guard let self, let playing, self.vlcURL == nil, let player = self.player else { return }
                    if playing { player.play() } else { player.pause() }
                }
            },
        ]
        #endif
        let magnet = playback.torrent.url
        // Reclaim prior torrent partials + orphaned remux output (shared
        // cross-platform helper — same disk-bounding as iOS/tvOS). Not while
        // another window plays: its torrent folder and HLS copy are not
        // orphans (verify-storage F6 — its remux lost its segments, and
        // libtorrent could reopen its file by path as a new, unsized one).
        // The next play with no other window, or the next launch, purges.
        #if DEBUG
        // Nor in a run that streams into its own `-PTDebugDownloadDir`: the
        // temporary folder is shared with the installed app.
        let purges = !BoundedStorageDebugHooks.leavesTemporaryFolderAlone
        #else
        let purges = true
        #endif
        if purges, !Self.liveControllers.allObjects.contains(where: { $0 !== self && !$0.stopped }) {
            purgeOrphanTorrentDownloads()
        }
        Self.liveControllers.add(self)

        media = playback.media
        resumePoint = MacPlaybackProgress.resumePoint(for: playback.media)
        subtitles = playback.media.subtitles
        // The `[Start]` trace of this playback, and the OpenSubtitles search
        // alongside the stream (the detail page started it at the click and
        // no longer waits for it: `SubtitleSearch`).
        let trace = PlaybackStartTrace(title: playback.title)
        streamer.startTrace = trace
        trace.begin(.subtitles)
        SubtitleSearch.shared.search(for: playback.media) { [weak self] found in
            trace.reach(.subtitles, detail: "\(found.count) language(s)")
            // In before the stream is ready: every route starts with it.
            guard let self = self, self.subtitles.isEmpty, self.player == nil, self.vlcURL == nil else { return }
            self.subtitles = found
        }
        decidedStart = playback.startFraction > ResumePolicy.minimumDecidedStart ? playback.startFraction : nil
        #if DEBUG
        // `-PTDebugDecidedStart` (BoundedStorageDebugHooks): as after a switch.
        if decidedStart == nil { decidedStart = BoundedStorageDebugHooks.decidedStart }
        #endif
        startFraction = 0
        loadingTracker = LoadingPhaseTracker()
        patience = playback.patience.map { ($0, playback.media.id, MagnetLink.sourceKey(of: playback.torrent.url)) }
        // The release, the title's other releases and how to switch: the
        // deficit watch (native and VLC) reads them from the stream.
        let context = PlaybackStreamContext.attach(to: streamer, media: playback.media, sourceURL: magnet,
                                                   torrent: playback.torrent,
                                                   sources: playback.sources.isEmpty ? nil : playback.sources,
                                                   decidedStart: decidedStart)
        context.onSwitch = onSwitch
        let monitor = context.deficit
        monitor.attach(self) { [weak self] in
            MainActor.assumeIsolated { self?.deficitPlaybackState() }
        }
        deficitSubscription = monitor.$offer.receive(on: DispatchQueue.main).sink { [weak self] offer in
            MainActor.assumeIsolated { self?.deficitOfferID = offer?.id }
        }
        deficitMonitor = monitor
        let isAtmos = playback.torrent.tags.contains(.atmos)
        let hintsHDR = !playback.torrent.tags.isDisjoint(with: [.hdr10, .hdr10Plus, .dolbyVision])
        // A film larger than the free space streams in bounded storage
        // (every route below drives the torrent's window).
        BoundedStorageSession.prepare(streamer, durationSeconds: BoundedStorageSession.durationHint(for: playback.media))

        streamer.startStreaming(fromMultiTorrentFileOrMagnetLink: magnet, progress: { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.player == nil, self.vlcURL == nil, !self.boundedPlaybackEnded,
                      !self.stopped, !self.loadingDone else { return }
                // From the first second (PopcornTorrent reports before the
                // metadata too): peers, the torrent's details, buffering.
                self.applyLoadingPhase(self.loadingTracker.update(streamer: self.streamer, fromCallback: true))
                self.refreshBoundedNote()
            }
        }, readyToPlay: { [weak self] videoFileURL, videoFilePath in
            DispatchQueue.main.async {
                guard let self = self, !self.stopped else { return }
                self.loadingDone = true
                self.buffering = 1
                self.loadingPhase = .buffering(progress: 1, eta: nil)
                let fileName = videoFilePath.lastPathComponent
                self.streamer.noteStartBuffered(fileName: fileName)
                // alextud's GCDWebServer reports its URL as 0.0.0.0 — rewrite
                // to 127.0.0.1 (routable local endpoint) and name the file
                // (served on every path) so AVFoundation / VLC see the
                // container extension.
                self.directURL = PlaybackRouting.playableLocalURL(videoFileURL, fileName: fileName)
                // Route on the REAL payload name (magnet display names often
                // carry no extension). Unknown → remux, which fails fast.
                let route = PlaybackRouting.route(forFileName: fileName)
                // Where playback starts: the title's saved position (as on
                // tvOS: none for a finished title), or where a switch to a
                // lighter release left the other one.
                self.nativeJumps = RemuxPlayback.nativeJumpsEnabled
                let start = ResumePolicy.start(savedProgress: self.resumePoint, decidedStart: self.decidedStart,
                                               route: route, isPayloadOnDisk: self.streamer.isWholeFileOnDisk,
                                               nativeJumps: self.nativeJumps)
                print("[Player] \(fileName) → \(route), start: \(start)")
                switch start {
                case .fromBeginning:
                    break
                case .nativeSeek(let position):
                    // The item seeks there once it is ready (`attachPlayer`);
                    // VLC continues there too if the native path gives up
                    // before playing.
                    self.startFraction = position
                    self.vlcStartPosition = position
                case .vlc(let position):
                    // VLC's container, or — native jumps switched off — a
                    // decided start on an MKV still downloading: VLC at
                    // once, at that position (its byte ranges fetch it
                    // first).
                    self.vlcStartPosition = position
                    self.fallBackToVLC(route == .vlc ? PlaybackRouting.vlcReason(forFileName: fileName)
                                                     : ResumePolicy.vlcResumeReason(RemuxPlayback.nativeJumpsOffReason))
                    return
                case .askResume(let position), .nativeResume(let position):
                    // A saved position on an MKV still downloading: the user
                    // chooses (`answerResumeQuestion`) — or already decided
                    // (a lighter release: no question) — once the remux,
                    // which prepares meanwhile and turns the torrent to that
                    // position, says whether it can resume there natively
                    // (`resolvePendingResume`). A remux that fails meanwhile
                    // hands VLC that position.
                    self.vlcStartPosition = position
                    let asks = start == .askResume(position)
                    self.pendingResume = (position, asks)
                    print("[Resume] " + (asks ? "saved \(Int(position * 100)) % — question pending"
                                              : "decided start at \(Int(position * 100)) % — no question")
                          + ", native jumps \(self.nativeJumps ? "on" : "off (\(RemuxPlayback.nativeJumpsDisabledKey))")")
                }
                switch route {
                case .remux:
                    self.startRemux(localFile: videoFilePath, isAtmos: isAtmos, releaseHintsHDR: hintsHDR)
                case .avPlayer:
                    self.startDirect()
                case .vlc:
                    self.fallBackToVLC(PlaybackRouting.vlcReason(forFileName: fileName))
                }
            }
        }, failure: { [weak self] (error: Error) in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Not enough space even for bounded storage (-5: how much to
                // free), another file error (-6), or the error's own text.
                let failure = StreamFailure(error, streamer: self.streamer)
                let message = failure.message(underlying: error) ?? error.localizedDescription
                if case .episodeNotInTorrent = failure { self.episodeNotInTorrent = true }
                switch failure {
                case .episodeNotInTorrent, .other: self.forgetRememberedRelease("the stream failed (\(message))")
                case .notEnoughSpace, .notEnoughSpaceForBoundedStorage, .fileError: break   // this Mac's disk, not the release
                }
                self.loadingDone = true
                self.showsLoadingSpinner = false
                self.loadingPhase = .starting
                self.statusLine = String(format: "Failed: %@".localized, message)
            }
        }, selectFileToStream: streamer.measuringSelection(PTTorrentStreamer.fileSelection(for: magnet, media: playback.media,
                                                                                      torrent: playback.torrent, log: "[Player]")))

        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStats()
                self?.refreshResumingText()
            }
        }
    }

    // MARK: - Loading

    /// The phase on the loading screen: its line (the swarm added while
    /// buffering) and the buffering bar.
    private func applyLoadingPhase(_ tracked: LoadingPhase) {
        guard !loadingDone, !boundedPlaybackEnded else { return }
        var phase = tracked
        // A release remembered for the title (« Resume », decision D5): no
        // peer `patience` seconds after the start — not the usual 45 s —
        // and it is « not responding »: another source is offered, and the
        // release is forgotten (the next « Resume » goes through the sources).
        if let patience, !patienceWaived, !phase.isNotResponding {
            if streamer.torrentStatus.peers > 0 { sawPeer = true }
            if !sawPeer, phase.isWaiting, loadingTracker.elapsed >= patience.seconds {
                phase = .notResponding(.noPeers)
                forgetRememberedRelease("no peer in \(Int(patience.seconds)) s")
            }
        }
        loadingPhase = phase
        let slow = loadingTracker.isSlow
        if slow != loadingIsSlow { loadingIsSlow = slow }
        if case .buffering(let progress, _) = phase { buffering = Double(progress) }
        var line = phase == tracked ? loadingTracker.line : phase.line
        if phase.isBuffering {
            let status = streamer.torrentStatus
            line += " · " + String(format: NSLocalizedString("PlayerLoading.Swarm", value: "Seeds: %1$d · %2$d KB/s",
                                                             comment: "Loading screen while buffering: connected seeds and download speed in kilobytes per second"),
                                   Int(status.seeds), Int(status.downloadSpeed / 1024))
        }
        statusLine = line
    }

    /// « Keep waiting » (the source does not answer): the message goes,
    /// every stall rule counts again from now.
    func keepWaiting() {
        guard !loadingDone else { return }
        print("[Player] keep waiting")
        patienceWaived = true
        loadingTracker.keepWaiting()
        applyLoadingPhase(loadingTracker.phase)
    }

    /// The release remembered for the title did not answer or failed: the
    /// next « Resume » goes through the sources (`Library.forgetRelease`).
    private func forgetRememberedRelease(_ why: String) {
        guard let patience, !forgotRelease else { return }
        forgotRelease = true
        // That release, wherever the title remembers it (an episode not
        // started replays its show's pack: the pack is the show's).
        let forgotten = Library.shared.forgetRelease(patience.mediaID, sourceKey: patience.sourceKey)
        print("[UpNext] resume \(patience.mediaID): \(why) — remembered release "
              + (forgotten ? "forgotten" : "already gone") + "; « Choose another source » offered")
    }

    /// The deficit watch's view of the native player (nil while VLC plays:
    /// its own controller reports then).
    private func deficitPlaybackState() -> BandwidthDeficitMonitor.PlaybackState? {
        guard !stopped, vlcURL == nil, let player = player else { return nil }
        let recovering = starvation.isRecovering
        let time = recovering ? starvation.resumeTime : player.currentTime().seconds
        var duration = player.currentItem?.duration.seconds ?? .nan
        if !duration.isFinite || duration <= 0 { duration = lastKnownDuration ?? .nan }
        if !duration.isFinite || duration <= 0, let length = remux?.session?.playlistDurationSeconds, length > 0 {
            duration = length
        }
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate && playIntent.wantsPlayback
        // A wait for a jump of the conversion (a resume, a far seek) is not a
        // download slower than the film: the torrent is turning to that part.
        let jumping = isResumingNatively || remux?.isJumpWaiting == true
        return BandwidthDeficitMonitor.PlaybackState(playhead: time, duration: duration.isFinite ? duration : nil,
                                                     hasStarted: playedPosition.lastPlayedTime != nil,
                                                     wantsPlayback: playIntent.wantsPlayback,
                                                     isStalled: !jumping && ((recovering && !starvation.isRebuildingStuckItem) || waiting))
    }

    // MARK: - Remux path (MKV / WebM)

    private func startRemux(localFile: URL, isAtmos: Bool, releaseHintsHDR: Bool) {
        statusLine = "Remuxing MKV → HLS…".localized
        engineLine = "MKV remux → AVPlayer (macOS natif)"
        let remux = RemuxPlayback(localFile: localFile,
                                  streamer: streamer,
                                  isAtmos: isAtmos)
        // DEFAULT audio / subtitle renditions follow the user's languages.
        remux.preferredAudioLanguages = PlaybackLanguagePreferences.preferredAudioLanguageCode.map { [$0] } ?? []
        // A learnt subtitle language only when the audio asked for is
        // another (the subtitle controller decides on the audio heard).
        remux.preferredSubtitleLanguages = PlaybackLanguagePreferences.preferredSubtitleLanguageCode(
            whileHearing: PlaybackLanguagePreferences.preferredAudioLanguageCode).map { [$0] } ?? []
        remux.releaseHintsHDR = releaseHintsHDR
        // A late jump's wait asks the engine's own server (127.0.0.1) for its bytes (`RemuxWaitNudge`).
        remux.engineServerURL = directURL
        // The search may have answered without its list being handed over
        // yet (its completion, in `start`, comes a queue turn after the
        // answer is recorded): taken from the search itself, or this
        // playback's master playlist would never list it.
        if subtitles.isEmpty, let found = media.flatMap({ SubtitleSearch.shared.answer(for: $0) }), !found.isEmpty {
            subtitles = found
        }
        remux.subtitles = subtitles
        // Native jumps (the hidden switch): a saved position is prepared now —
        // the remux says whether it can resume there natively
        // (`resumeReadiness`) and turns the torrent to it while the user is
        // asked. Its jumps are reported: one somebody waits on, one that failed.
        remux.allowsNativeJumps = nativeJumps
        if let pending = pendingResume, nativeJumps { remux.prepareResume(atFraction: pending.fraction, decided: !pending.asks) }
        remux.onResumeReadinessChanged = { [weak self] readiness in
            MainActor.assumeIsolated { self?.resumeReadinessChanged(readiness) }
        }
        remux.onJumpStateChanged = { [weak self] state in
            MainActor.assumeIsolated { self?.jumpStateChanged(state) }
        }
        remux.onJumpFailed = { [weak self] reason, playerSeconds in
            MainActor.assumeIsolated { self?.jumpFailed(reason, at: playerSeconds) }
        }
        resumeStartedAt = ProcessInfo.processInfo.systemUptime
        self.remux = remux
        remux.onReady = { [weak self] playlistURL in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // The resume is not decided yet (its engine unknown, or the
                // question still up): the answer attaches.
                guard self.resumeQuestion == nil, self.pendingResume == nil else {
                    self.pendingPlaylistURL = playlistURL
                    return
                }
                if self.isResumingNatively {
                    // « Resume at … » was answered before the remux was
                    // ready: the item is made once the media at the resume
                    // point is on disk.
                    self.pendingPlaylistURL = playlistURL
                    self.attachNativeResumeWhenReady()
                    return
                }
                self.attachPlayer(to: playlistURL, direct: false)
            }
        }
        remux.onFailure = { [weak self] message in
            // Codecs the remuxer can't repackage (DTS / TrueHD only, VP9…) —
            // reported within seconds of the header.
            DispatchQueue.main.async { self?.fallBackToVLC(message) }
        }
        remux.onHalted = { [weak self] reason in
            // The remux stopped producing after `onReady` (disk full…): the
            // missing segments will never exist — VLC at once, at the
            // current position (it reads the torrent file, no extra disk).
            DispatchQueue.main.async {
                print("[Player] remux halted after playback started (\(reason))")
                self?.fallBackToVLC(reason)
            }
        }
        remux.onUnavailableSegmentRequested = { [weak self] playerSeconds in
            // Playback needs a pruned segment (deleted for good): at once for
            // a rewind past the kept media or into a span a far seek skipped;
            // for a pruned span AVPlayer prefetched ahead of the playhead,
            // only once playback gets within about a segment of it (the remux
            // holds that request meanwhile, AVPlayer plays its buffer
            // natively). AVPlayer would retry the 404 for ~30 s, then fail.
            DispatchQueue.main.async { self?.unavailableSegmentRequested(at: playerSeconds) }
        }
        // A seek into pruned segments while a starvation recovery waits:
        // the dead item requests nothing, the recovery asks here.
        starvation.positionUnavailable = { [weak self, weak remux] seconds in
            guard let remux = remux, !remux.isAvailable(playerSeconds: seconds) else { return false }
            // Bounded storage: a rewind there is blocked, not handed to VLC —
            // the dead item moves to the earliest point still available.
            return !(self?.limitRecoveringRewind(to: seconds) ?? false)
        }
        // OpenSubtitles → native HLS subtitle tracks. Their search started
        // with the stream (`start`): only one that has not answered yet
        // (a very fast swarm, a slow OpenSubtitles) is waited for here.
        if subtitles.isEmpty, let media = media, SubtitleSearch.shared.answer(for: media) == nil {
            // AVPlayer reads the master playlist once: `onReady` is held so
            // the list can land in it, until it comes or `startHold` after
            // the search began, whichever is first — assigning `subtitles`
            // (even []) releases the hold. A list that comes later still is
            // in the masters served from then on: when the player has
            // already read one, its item is rebuilt once
            // (`rebuildForLateSubtitlesIfDue`).
            remux.externalSubtitlesPending = true
            SubtitleSearch.shared.search(for: media, waitingAtMost: SubtitleSearch.startHold) { [weak self, weak remux] found, isFinal in
                if !isFinal { print("[Player] OpenSubtitles has not answered: starting without its list") }
                guard let remux = remux else { return }
                if isFinal {
                    self?.lateSubtitles.listArrived(isEmpty: found.isEmpty, masterServed: remux.hasServedMaster)
                }
                remux.subtitles = found
                guard let self = self, !found.isEmpty else { return }
                self.subtitles = found
            }
        }
        remux.start()
        resolvePendingResume()
    }

    // MARK: - Direct path (MP4 / M4V / MOV)

    private func startDirect() {
        guard let url = directURL else { return }
        statusLine = "Opening the file…".localized
        engineLine = "MP4 direct → AVPlayer (macOS natif)"
        // Nothing is ever pruned on the torrent's own file — except in
        // bounded storage: a seek of the dead item further back than what is
        // still on disk moves it to the earliest point still available (never
        // VLC there). Full mode: never unavailable, as before.
        starvation.positionUnavailable = { [weak self] seconds in
            guard let self = self, let session = self.boundedStorage, session.isBounded,
                  let reference = self.playedPosition.lastPlayedTime, seconds < reference,
                  !session.canSeek(to: seconds, fromPlayerTime: reference) else { return false }
            return !self.limitRecoveringRewind(to: seconds)
        }
        let cues = SubtitleCueController(subtitles: subtitles)
        cueController = cues
        if cues.available.isEmpty {
            // Preferred subtitle language once OpenSubtitles answers
            // (`$available` fires before the change — hop a turn).
            cueSubscription = cues.$available
                .first(where: { !$0.isEmpty })
                .receive(on: DispatchQueue.main)
                .sink { [weak cues] _ in
                    guard let cues = cues, cues.selected == nil else { return }
                    cues.autoSelectPreferred()
                }
            cues.loadSubtitlesIfNeeded(for: media)
        } else {
            cues.autoSelectPreferred()
        }
        attachPlayer(to: url, direct: true)
        // Bounded storage: AVPlayer reads through PopcornTorrent's server
        // (which moves the window); its playhead tells the torrent what it
        // may delete behind it.
        BoundedStorageSession.session(for: streamer)?.attachHTTPPlayer(self, readAheadSeconds: Self.directReadAheadSeconds) { [weak self] in
            guard let self = self, self.isDirectPlayback, self.vlcURL == nil, let player = self.player,
                  player.currentItem?.status == .readyToPlay else { return nil }
            let time = player.currentTime().seconds
            guard time.isFinite else { return nil }
            return BoundedPlayerSample(time: time, isPlaying: player.timeControlStatus == .playing)
        }
    }

    /// Bounded storage, direct path: the forward buffer AVPlayer may keep
    /// (`preferredForwardBufferDuration`), and how far past the playhead it
    /// may have read (the buffer plus a margin).
    static let directForwardBufferSeconds: Double = 60
    static let directReadAheadSeconds: Double = 75

    // MARK: - Player

    private func attachPlayer(to url: URL, direct: Bool) {
        guard !stopped, vlcURL == nil, player == nil else { return }
        playbackURL = url
        isDirectPlayback = direct
        let item = makePlayerItem(url: url)
        if isResumingNatively, let target = remux?.resumeTargetSeconds, target > 0 {
            // A native resume: positioned BEFORE it is attached, as a
            // starvation recovery's item is — its first media request is the
            // resume segment (on disk: `attachNativeResumeWhenReady`), not
            // 0:00 and the segments after it, which the jump skipped. (No
            // completion handler: a seek with one raises on an item that is
            // not ready; the start seek, exact, follows once it is.) Never
            // past the saved position: a keyframe before it.
            item.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .positiveInfinity,
                      toleranceAfter: .zero, completionHandler: nil)
        }
        let player = AVPlayer(playerItem: item)
        player.appliesMediaSelectionCriteriaAutomatically = true
        PlaybackLanguagePreferences.applyPreferredMediaSelection(to: item)
        installFailureObserver(on: item)
        noteAttachedItem(item)
        print("[Player] AVPlayer on \(direct ? "the torrent's HTTP endpoint" : "the remux HLS")")
        cueController?.attach(to: player)
        // The `[Start]` trace's last phase: the player really playing.
        firstFrameWatch = FirstFrameWatch(player: player) { [weak self] in
            self?.streamer.noteStartFirstFrame(detail: direct ? "AVPlayer (direct)" : "AVPlayer (remux)")
            // The end of a native resume's wait.
            MainActor.assumeIsolated { self?.finishNativeResume() }
        }
        self.player = player
        observePlayer(player)
        registerPlaybackCommands()
        if startFraction > 0 {
            seekToStartFraction(item: item, player: player)
        } else {
            player.play()
        }
        // Auto-hide the stats after the proof-of-Atmos glance.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.showStats = false
        }
    }

    /// A start part-way (the saved position, a switch to a lighter
    /// release): once the item is ready with its duration, a seek there,
    /// then play. Direct path: byte ranges make the torrent fetch that part
    /// first. Remux path: with the file entirely on disk
    /// (`ResumePolicy.start`) the segment asked for is held by the remux
    /// server while the remux pumps ahead to it; a native resume of a file
    /// still downloading (`resume(at:engine:how:)`): held the same way until the
    /// conversion, moved there, has written it. Never blocks playback: after
    /// 45 s it plays from where it is — except a native resume the user
    /// accepted, which is waited for under « Resuming at … » (its data is
    /// being downloaded; a wait AVPlayer gives up on becomes a starvation
    /// recovery at that position, natively).
    private func seekToStartFraction(item: AVPlayerItem, player: AVPlayer) {
        let fraction = Double(startFraction)
        startFraction = 0
        awaitingStartSeek = true
        // (A native resume has its own overlay, over black.)
        isStartingPartWay = !isResumingNatively
        var done = false
        // `landed`: the seek completed — playback is at the start position.
        let finish: (String, Bool) -> Void = { [weak self, weak player] how, landed in
            guard !done else { return }
            done = true
            // Closed, or VLC took over meanwhile: nothing to start.
            guard let self = self, !self.stopped, self.vlcURL == nil, let player = player, self.player === player else { return }
            self.startSeekObservation?.invalidate()
            self.startSeekObservation = nil
            self.awaitingStartSeek = false
            self.startSeekTarget = nil
            self.isStartingPartWay = false
            // From here a hand-off to VLC goes where native playback got
            // (`fallBackToVLC`), no longer to the start position.
            if landed { self.vlcStartPosition = 0 }
            print("[Player] start part-way: \(how)")
            player.play()
        }
        startSeekObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            DispatchQueue.main.async {
                guard let self = self, !done, observed.status == .readyToPlay, self.startSeekTarget == nil else { return }
                let duration = observed.duration.seconds
                guard duration.isFinite, duration > 0 else { return finish("duration unknown, from the start", false) }
                // A native resume seeks where the remux sent its conversion
                // (the same share of the playlists' length).
                let seconds = (self.isResumingNatively ? self.remux?.resumeTargetSeconds : nil) ?? fraction * duration
                if self.isResumingNatively { print("[Resume] seek issued to \(String(format: "%.1f", seconds)) s") }
                self.awaitingStartSeek = false
                self.startSeekTarget = seconds
                player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                    // Not finished: another seek replaced it (the user's).
                    DispatchQueue.main.async { finish("at \(Int(seconds)) s (\(Int(fraction * 100)) %)", finished) }
                }
                // The remux hears of the target now, not at the next tick.
                self.reportPlaybackPositions()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            // A native resume the user accepted is not given up on.
            guard self?.isResumingNatively != true else { return }
            finish("not ready after 45 s, from where it is", false)
        }
    }

    // MARK: - Resume of a file still downloading, and jumps (remux path)

    /// What « Resume at … » means now (`ResumePolicy.resumeEngine`); nil:
    /// not known yet.
    private func currentResumeEngine() -> ResumePolicy.ResumeEngine? {
        let now = ProcessInfo.processInfo.systemUptime
        return ResumePolicy.resumeEngine(readiness: remux?.resumeReadiness ?? .pending,
                                         waited: now - (resumeWaitStartedAt ?? now), nativeJumps: nativeJumps,
                                         indexIsRead: remux?.isKeyframeIndexRead == true)
    }

    /// Seconds since `mark` (default: the remux's start), to a tenth: the
    /// `[Resume]` lines' clock.
    private func sinceResumeStart(_ mark: TimeInterval? = nil) -> String {
        let from = mark ?? resumeStartedAt ?? ProcessInfo.processInfo.systemUptime
        return String(format: "%.1f", ProcessInfo.processInfo.systemUptime - from)
    }

    /// A saved position as the user reads it: the clock time once the MKV
    /// header gave the film's length, the percentage before.
    private func resumePositionLabel(_ fraction: Float) -> String {
        ResumePolicy.resumeLabel(fraction: fraction, durationSeconds: remux?.session?.totalDurationSeconds ?? 0)
    }

    /// The saved position waits for its engine (at the remux's start, at
    /// each change of its readiness, 1 Hz): once known — native when the
    /// conversion can jump there, VLC when it can't, when native jumps are
    /// off or after `ResumePolicy.readinessWait` — the loading screen asks,
    /// its message saying which; a decided start resumes at once, on that
    /// engine. Until then the loading screen keeps its spinner.
    private func resolvePendingResume() {
        guard let pending = pendingResume, !stopped, vlcURL == nil else { return }
        if resumeWaitStartedAt == nil { resumeWaitStartedAt = ProcessInfo.processInfo.systemUptime }
        guard let engine = currentResumeEngine() else {
            // A decided start says where it is going while it waits.
            if !pending.asks { statusLine = ResumePolicy.resumingText(position: resumePositionLabel(pending.fraction)) }
            return
        }
        pendingResume = nil
        guard pending.asks else {
            resume(at: pending.fraction, engine: engine, how: "a decided start")
            return
        }
        resumeQuestion = MacResumeQuestion(fraction: pending.fraction,
                                           durationSeconds: remux?.session?.totalDurationSeconds ?? 0, engine: engine)
        resumeQuestionShownAt = ProcessInfo.processInfo.systemUptime
        print("[Player] resume question: \(Int(pending.fraction * 100)) %, payload still downloading")
        print("[Resume] question shown (\(ResumePolicy.logName(of: engine))) at +\(sinceResumeStart()) s")
        if case .vlc(let reason) = engine { print("[Resume] not native for the player: \(reason) — the question says VLC") }
        #if DEBUG
        MacDebugHooks.resumeQuestionShown { [weak self] resume in self?.answerResumeQuestion(resume: resume) }
        #endif
    }

    /// `RemuxPlayback.onResumeReadinessChanged`: the engine of a pending
    /// resume is known; a question already up follows what « Resume at … »
    /// now means (the remux can find, from the bytes arriving at the resume
    /// point, that the file's index does not say true there: native → VLC).
    private func resumeReadinessChanged(_ readiness: NativeResumeReadiness) {
        guard !stopped, vlcURL == nil else { return }
        if readiness == .native, resumeNativeSince == nil { resumeNativeSince = ProcessInfo.processInfo.systemUptime }
        resolvePendingResume()
        if let question = resumeQuestion, let engine = currentResumeEngine(), engine != question.engine {
            resumeQuestion?.engine = engine
            print("[Resume] question now says \(ResumePolicy.logName(of: engine)) at +\(sinceResumeStart()) s")
        }
    }

    /// The loading screen's resume question, answered. Resume: on the engine
    /// the question named, as the remux says now. From the beginning: the
    /// native player, as soon as the remux is ready — the torrent goes back
    /// to the head, and the saved position is no longer protected: the user
    /// started over (`ResumePolicy.progressToSave`).
    func answerResumeQuestion(resume: Bool) {
        guard let question = resumeQuestion, !stopped, vlcURL == nil else { return }
        resumeQuestion = nil
        // How long the question was up.
        let after = sinceResumeStart(resumeQuestionShownAt ?? resumeWaitStartedAt)
        if resume {
            // Not known any more (it can't be: asked once known): native —
            // the remux takes the answer when it is ready.
            self.resume(at: question.fraction, engine: currentResumeEngine() ?? .native, how: "after \(after) s")
            return
        }
        print("[Player] resume declined — native playback from the beginning")
        print("[Resume] answer: from the beginning (after \(after) s)")
        remux?.cancelResume()
        resumePoint = 0
        vlcStartPosition = 0
        if let url = pendingPlaylistURL {
            pendingPlaylistURL = nil
            attachPlayer(to: url, direct: false)
        }
    }

    /// « Resume at … » (or a decided start) on a file still downloading.
    /// Native: the remux moves its conversion to that position now
    /// (`commitResume`; the torrent has been turning there since the remux
    /// said it could) and the player seeks there — under black, a spinner and
    /// « Resuming at 1:40:00… » until the picture at that position plays (the
    /// item is made only once the media at that position is on disk,
    /// `attachNativeResumeWhenReady`, positioned there before it is
    /// attached). VLC: the same stream, at that position.
    private func resume(at fraction: Float, engine: ResumePolicy.ResumeEngine, how: String) {
        let label = resumePositionLabel(fraction)
        switch engine {
        case .native:
            print("[Resume] answer: resume at \(label) (\(how)) — native")
            isResumingNatively = true
            resumeAnsweredAt = ProcessInfo.processInfo.systemUptime
            startFraction = fraction
            vlcStartPosition = fraction
            remux?.commitResume()
            showResumingText(label, target: nil)
            let text = resumingText ?? ResumePolicy.resumingText(position: label)
            isResumeCovered = true
            // Until the player exists the loading screen says it.
            statusLine = text
            // The remux hears where the player is going before its item exists.
            reportPlaybackPositions()
            #if DEBUG
            MacDebugHooks.snapshotPlayerWindow(named: "resume-cover", after: 1)
            #endif
            attachNativeResumeWhenReady()
        case .vlc(let reason):
            print("[Resume] answer: resume at \(label) (\(how)) — through VLC (\(reason))")
            pendingPlaylistURL = nil
            vlcStartPosition = fraction
            fallBackToVLC(ResumePolicy.vlcResumeReason(reason))
        }
    }

    /// A poll of `attachNativeResumeWhenReady` is scheduled.
    private var isPollingResumeAttach = false

    /// A native resume makes its item once the media to start at the resume
    /// point is on disk (`RemuxPlayback.hasMediaToStart`: two segments, as
    /// at 0:00) — polled every 0.2 s under the cover. An item attached before
    /// would hold the request for a segment the conversion has yet to write,
    /// and AVPlayer gives up on a held request after about one target
    /// duration (`ResumePolicy.resumeAttach`: on tvOS for good; the same
    /// rule here). A resume the remux can no longer serve natively goes to
    /// VLC at the saved position.
    private func attachNativeResumeWhenReady() {
        guard isResumingNatively, player == nil, !stopped, vlcURL == nil, let remux = remux else { return }
        let target = remux.resumeTargetSeconds
        var refusal = remux.failureReason
        if refusal == nil, case .vlcOnly(let reason) = remux.resumeReadiness { refusal = reason }
        let step = ResumePolicy.resumeAttach(isPlaylistReady: pendingPlaylistURL != nil, hasTarget: target != nil,
                                             hasMedia: target.map { remux.hasMediaToStart(fromPlayerSeconds: $0) } ?? false,
                                             isAvailable: target.map { remux.isAvailable(playerSeconds: $0) } ?? true,
                                             refusal: refusal)
        switch step {
        case .attach:
            guard let url = pendingPlaylistURL else { return }
            pendingPlaylistURL = nil
            let waited = resumeAnsweredAt.map { String(format: "%.1f", ProcessInfo.processInfo.systemUptime - $0) } ?? "?"
            print("[Resume] media at the resume point on disk \(waited) s after the answer — the player's item is made")
            attachPlayer(to: url, direct: false)
        case .vlc(let reason):
            print("[Resume] the resume can't be native after all (\(reason)) → VLC at \(Int(vlcStartPosition * 100)) %")
            pendingPlaylistURL = nil
            fallBackToVLC(reason)
        case .wait:
            guard !isPollingResumeAttach else { return }
            isPollingResumeAttach = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.isPollingResumeAttach = false
                self?.attachNativeResumeWhenReady()
            }
        }
    }

    /// The picture at the resume position plays (the player's first
    /// `.playing`, which only comes after the start seek — or after the
    /// starvation recovery that took it over): the cover and the text go.
    private func finishNativeResume() {
        guard isResumingNatively else { return }
        isResumingNatively = false
        hideResuming()
        let now = ProcessInfo.processInfo.systemUptime
        let time = player?.currentTime().seconds ?? .nan
        let answered = resumeAnsweredAt.map { String(format: "%.1f", now - $0) } ?? "?"
        let steered = resumeNativeSince.map { String(format: "%.1f", now - $0) } ?? "?"
        print("[Resume] first frame at \(String(format: "%.1f", time)) s — \(answered) s after the answer, "
              + "\(steered) s after steering")
    }

    private func hideResuming() {
        resumingText = nil
        resumingPosition = nil
        resumingTarget = nil
        isResumeCovered = false
        jumpLabelTarget = nil
    }

    /// What « Resuming at … » shows: its position as written, and on the
    /// player's timeline (nil: the start's resume) — `refreshResumingText`.
    private var resumingPosition: String?
    private var resumingTarget: Double?

    /// « Resuming at <position>… », then — once the wait lasts — how far the
    /// media there is (« Resuming at 22:35 — 45% · 9.6 MB/s »,
    /// `RemuxPlayback.waitProgress`).
    private func showResumingText(_ position: String, target: Double?) {
        resumingPosition = position
        resumingTarget = target
        resumingText = ResumePolicy.resumingText(position: position,
                                                 progress: ResumePolicy.progress(remux?.waitProgress, forTarget: target))
    }

    /// 1 Hz: the progress of the wait under « Resuming at … » (also on the
    /// loading screen while the start's resume has no player yet).
    private func refreshResumingText() {
        guard let position = resumingPosition, let current = resumingText else { return }
        let text = ResumePolicy.resumingText(position: position,
                                             progress: ResumePolicy.progress(remux?.waitProgress, forTarget: resumingTarget))
        guard text != current else { return }
        if statusLine == current { statusLine = text }
        resumingText = text
    }

    /// `RemuxPlayback.onJumpStateChanged`: the conversion was moved to serve
    /// a position somebody waits on — « Resuming at … » until playback runs
    /// there (the torrent turns to that part, the first segments come:
    /// seconds), instead of a silent frozen picture.
    private func jumpStateChanged(_ state: RemuxPlayback.JumpState) {
        guard !stopped, vlcURL == nil else { return }
        switch state {
        case .waiting(let playerSeconds):
            switch ResumePolicy.jumpWaitResponse(isResumingNatively: isResumingNatively, hasItem: player != nil) {
            case .ignore:
                // The start's resume already says it, over its cover.
                return
            case .armGraceOnly:
                // A seek under the resume's cover: the cover stays (no
                // `jumpLabelTarget`), its text follows the new position.
                showResumingText(ResumePolicy.clockString(seconds: playerSeconds), target: playerSeconds)
            case .showAndArmGrace:
                jumpLabelTarget = playerSeconds
                showResumingText(ResumePolicy.clockString(seconds: playerSeconds), target: playerSeconds)
            }
            // The item is not left waiting on a segment the torrent has yet
            // to bring (`moveJumpWaitToNewItemIfNeeded`).
            jumpWaitCheck += 1
            let check = jumpWaitCheck
            DispatchQueue.main.asyncAfter(deadline: .now() + ResumePolicy.jumpGraceSeconds) { [weak self] in
                self?.moveJumpWaitToNewItemIfNeeded(check)
            }
        case .landed:
            checkResumingText()
        case .failed:
            guard jumpLabelTarget != nil else { return }
            hideResuming()
        }
    }

    /// The latest jump whose grace is running (only that one is checked).
    private var jumpWaitCheck = 0

    /// `ResumePolicy.jumpGraceSeconds` after the conversion was moved to a
    /// position somebody waits on (a far seek, a rewind into what a jump
    /// skipped): when the first segment there is still not written — the
    /// torrent has to turn to that part of the file — the wait moves from
    /// the item to the starvation recovery's (`waitForJump`): the player
    /// paused under « Resuming at … », a new item pre-positioned there once
    /// its media is on disk (`RemuxPlayback.hasMediaToStart`). The item that
    /// asked would give up on its held request after about one target
    /// duration (`ResumePolicy.jumpNeedsNewItem`: on tvOS it never plays
    /// again; the same rule here). A jump over data already on disk has
    /// written its segment by now: that item just plays on.
    private func moveJumpWaitToNewItemIfNeeded(_ check: Int) {
        guard check == jumpWaitCheck, !stopped, vlcURL == nil, !isDirectPlayback, let remux = remux,
              let player = player else { return }
        let wanted = player.currentTime().seconds
        guard wanted.isFinite, wanted >= 0 else { return }
        let healthy = isItemHealthy && !awaitingStartSeek && startSeekTarget == nil
        guard ResumePolicy.jumpNeedsNewItem(isJumpWaiting: remux.isJumpWaiting,
                                            hasFirstSegment: remux.hasMedia(fromPlayerSeconds: wanted, cushion: 0),
                                            isRecovering: starvation.isRecovering, isItemHealthy: healthy) else { return }
        let started = starvation.waitForJump(player: player, at: wanted, resumesPlayback: playIntent.wantsPlayback,
                                             rebuildsWhilePaused: true) { [weak remux] time, _ in
            guard let remux = remux else { return false }
            // Bounded storage: a deleted segment never comes back.
            if remux.isStorageBounded, !remux.isAvailable(playerSeconds: time) { return false }
            return remux.hasMediaToStart(fromPlayerSeconds: time)
        }
        guard started else { return }
        // The target is the recovery's from here on.
        _ = heldSeek.take()
        print("[Resume] jump to \(String(format: "%.1f", wanted)) s: its first segment is not written "
              + "\(String(format: "%.1f", ResumePolicy.jumpGraceSeconds)) s on — the wait moves to a new item, made once its media is on disk")
    }

    /// At a jump's end and at 1 Hz: a jump's text goes once the player is no
    /// longer waiting for media where it is — media to play is on disk there
    /// and it is not stalled (a paused player never « lands »; one that went
    /// elsewhere, to media that exists, does not wait either). And the cover
    /// never outlives a resume whose seek is over on a player that is no
    /// longer waiting.
    private func checkResumingText() {
        guard let remux = remux, let player = player else { return }
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate || starvation.isRecovering
        if isResumingNatively {
            if !awaitingStartSeek, startSeekTarget == nil, !waiting, player.currentItem?.status == .readyToPlay {
                finishNativeResume()
            }
            return
        }
        guard jumpLabelTarget != nil, !waiting else { return }
        let time = player.currentTime().seconds
        guard time.isFinite, remux.hasMedia(fromPlayerSeconds: time, cushion: 0) else { return }
        hideResuming()
    }

    /// `RemuxPlayback.onJumpFailed`: the conversion can't serve that position
    /// after all (the file's index does not say true there): VLC there, on
    /// the same stream (`onHalted` follows; the first of the two hands over).
    private func jumpFailed(_ reason: String, at playerSeconds: Double) {
        guard !stopped, vlcURL == nil else { return }
        print("[Player] the conversion could not jump to \(Int(playerSeconds)) s (\(reason)) — VLC there")
        fallBackToVLC(reason, resumeTime: playerSeconds)
    }

    /// The item for `url` — also how the starvation recovery rebuilds it.
    private func makePlayerItem(url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        // Let macOS spatialize the 5.1 + Atmos objects (built-in speakers /
        // AirPods) — this is the whole point of the native Mac app.
        item.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        if isDirectPlayback, BoundedStorageSession.session(for: streamer)?.isBounded == true {
            // Bounded storage: a known read-ahead over the torrent's file.
            item.preferredForwardBufferDuration = Self.directForwardBufferSeconds
        }
        return item
    }

    /// For the player's whole life: its rate changes (`playerRateDidChange`)
    /// and the time jumps of its current item (seeks, scrubs) — the positions
    /// are reported to the remux at once then, not at the next tick
    /// (`reportPlaybackPositions`). Removed when the player goes.
    private func observePlayer(_ player: AVPlayer) {
        let center = NotificationCenter.default
        playerObservers.append(center.addObserver(forName: AVPlayer.rateDidChangeNotification, object: player,
                                                  queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVPlayer.rateDidChangeReasonKey] as? AVPlayer.RateDidChangeReason
            MainActor.assumeIsolated { self?.playerRateDidChange(reason: reason) }
        })
        playerObservers.append(center.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: nil,
                                                  queue: .main) { [weak self] note in
            let jumped = note.object as AnyObject?
            MainActor.assumeIsolated {
                guard let self = self, let item = self.player?.currentItem, jumped === item else { return }
                self.reportPlaybackPositions()
                self.noteHeldSeek(isJump: true)
                self.scheduleBoundedRewindCheck()
            }
        })
        // Episode chaining: the file's end (the after-play card when its
        // length was never known, else the start the countdown decided).
        playerObservers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil,
                                                  queue: .main) { [weak self] note in
            let ended = note.object as AnyObject?
            MainActor.assumeIsolated {
                guard let self = self, let item = self.player?.currentItem, ended === item, !self.starvation.isRecovering else { return }
                self.tellUpNextTheEnd("the item played to its end")
            }
        })
    }

    /// Episode chaining, every second: where the native player is in the
    /// file and the file's length — a ready item's (MP4, a VOD playlist),
    /// else the remux's once the MKV header gave it, else nil (an EVENT
    /// playlist: the card then comes after the file, never on a guess);
    /// paused only by the user's own pause.
    private func tickUpNext() {
        guard let upNext, !stopped, vlcURL == nil, player != nil, let position = lastKnownTime else { return }
        var duration = lastKnownDuration
        if duration == nil, !isDirectPlayback, let total = remux?.session?.totalDurationSeconds, total > 0 { duration = total }
        upNext.tick(position: position, duration: duration, isPlaying: playIntent.wantsPlayback)
    }

    /// The native player reached the file's end: the session decides (once).
    private func tellUpNextTheEnd(_ how: String) {
        guard let upNext, !toldUpNextTheEnd, !stopped, vlcURL == nil else { return }
        toldUpNextTheEnd = true
        print("[UpNext] Mac native player: \(how)")
        upNext.itemEnded()
    }

    private func removePlayerObservers() {
        playerObservers.forEach { NotificationCenter.default.removeObserver($0) }
        playerObservers = []
    }

    /// The current item plays normally: no recovery or rebuild running (they
    /// pause and play the player themselves), not handed off or stopped, the
    /// item not failed nor its failure reported.
    private var isItemHealthy: Bool {
        guard let item = player?.currentItem else { return false }
        return !starvation.isRecovering && !stopped && vlcURL == nil && item.status != .failed
            && failureObserver?.hasReportedFailure != true
    }

    /// A rate change of the player: the user's play / pause intent
    /// (`PlaybackIntentWatch`). Only on a healthy item (`isItemHealthy`); the
    /// user's play / pause on a dead item while a recovery waits reaches the
    /// intent through the recovery (`onUserPlaybackChanged`). (No
    /// checkpoint: the Mac saves the progress when the player closes.)
    private func playerRateDidChange(reason: AVPlayer.RateDidChangeReason?) {
        guard let player = player else { return }
        _ = playIntent.noteRateChange(rate: player.rate, reason: reason, isHealthy: isItemHealthy, canCheckpoint: false)
        publishCommandState()
    }

    /// The 1 Hz tick (after the played position is sampled) and every time
    /// jump of a healthy item: the user's seek target AVPlayer holds, if any
    /// (`HeldSeekWatch`: `currentTime()` far from the last played position).
    private func noteHeldSeek(isJump: Bool) {
        guard isItemHealthy, let player = player else { return }
        heldSeek.note(wanted: player.currentTime().seconds, played: playedPosition.lastPlayedTime, isJump: isJump)
    }

    /// Remux path, 1 Hz (right after `noteHeldSeek`): the user's seek target
    /// AVPlayer holds past the remux frontier, on a healthy item while the
    /// user wants playback, goes to VLC AT the target at once when the
    /// frontier can't reach it within about AVPlayer's own hold
    /// (`FarTargetWatch`: the frontier's measured pace while the torrent
    /// grows — the in-order download's, or the remux pump's over data
    /// already on disk) — rather than after AVPlayer's ~42 s failure and a
    /// recovery's long wait. A target the frontier reaches sooner (near, or
    /// over data on disk that the pump reaches within that hold) stays native
    /// and the seek lands; a jump so far into the downloaded part that the
    /// pump can't goes to VLC like a far download.
    /// Anything else resets the measurement: no held target, a paused user
    /// (a paused scrub's target is the recovery's, once play is pressed — so
    /// is a scrub on the player view's timeline: AVKit's `setRate:0`, a user
    /// reason, lasts until its seek completes, which a held seek doesn't
    /// (measured); it ends on VLC from the recovery's watch, once AVPlayer
    /// fails the item), an item not healthy (recovery, hand-off), the direct
    /// path, a finished remux.
    ///
    /// Native jumps: the remux moves its conversion to a far target by
    /// itself, on the position reported to it — the frontier is then at the
    /// target and nothing is measured here. What is left for this watch is a
    /// target the conversion pumps toward (near, its data on disk) too
    /// slowly: the conversion is asked to jump there (`requestJump`), and
    /// only a remux that can't (no usable index, native jumps off) hands the
    /// target to VLC. While a jump is waited on, nothing is measured.
    private func checkFarSeekTarget() {
        guard !isDirectPlayback, let remux = remux, let session = remux.session, !remux.isJumpWaiting else {
            farTarget.reset()
            return
        }
        let target = isItemHealthy && playIntent.wantsPlayback ? heldSeek.target : nil
        let frontier = session.progress.mediaSeconds
        guard farTarget.shouldHandOff(target: target, frontierSeconds: frontier,
                                      downloadProgress: streamer.torrentStatus.totalProgress,
                                      remuxFinished: remux.isFinished, now: ProcessInfo.processInfo.systemUptime),
              let held = target else { return }
        let away = "~\(Int((farTarget.estimatedSecondsToTarget ?? 0).rounded())) s away at the download's pace"
        // The remux hears of the target first: a jump goes where the player
        // is reported to be.
        reportPlaybackPositions()
        if remux.requestJump(toPlayerSeconds: held, reason: .requested) {
            print("[Player] seek to \(Int(held)) s held past the remux frontier (\(Int(frontier)) s): \(away) — "
                  + "the conversion jumps there, native playback kept")
            farTarget.reset()
            jumpLabelTarget = held
            showResumingText(ResumePolicy.clockString(seconds: held), target: held)
            return
        }
        print("[Player] seek to \(Int(held)) s held past the remux frontier (\(Int(frontier)) s): \(away) — VLC there")
        fallBackToVLC(FarTargetWatch.reason, resumeTime: held)
    }

    /// ANY AVPlayer failure (remux or direct) → starvation recovery when the
    /// download is just slow, else VLC on the same stream. Hard failures are
    /// reported at once; the readiness timeout only catches silent hangs and
    /// is extended (up to 4 × 30 s) while the torrent is still downloading,
    /// so a slow swarm isn't mistaken for an incompatible file. An item
    /// rebuilt by the starvation recovery (`isReplacement`) gets no
    /// readiness timeout here: the recovery gives it 30 s, no extensions.
    private func installFailureObserver(on item: AVPlayerItem, isReplacement: Bool = false) {
        failureObserver?.invalidate()
        let observer = AVPlayerItemFailureObserver(item: item, readyTimeout: isReplacement ? nil : 30,
                                                   onReport: { [weak self] failure in
            self?.handlePlaybackFailure(failure)
        })
        if !isReplacement {
            observer.shouldExtendReadyTimeout = { [weak self] in
                guard let self = self else { return false }
                return !self.streamer.isWholeFileOnDisk
            }
        }
        failureObserver = observer
    }

    // MARK: - Download starvation (slow swarm) → stay native

    /// Starvation (FailedToPlayToEnd -12889 after AVPlayer waited ~37 s on a
    /// held segment / byte range) keeps the native player — HDR / Atmos —
    /// and resumes once the data is there (at the user's new target after a
    /// seek during the wait, or at the target of a seek AVPlayer still held
    /// when the item failed: `HeldSeekWatch`) — for a user who had paused,
    /// only once play is pressed (`PlaybackIntentWatch`); anything else →
    /// VLC, at that held target too. Remux path: a halted remux or an HTTP
    /// 404 (a segment that will never exist) → VLC at once, never a recovery.
    private func handlePlaybackFailure(_ failure: AVPlayerItemFailureObserver.Failure) {
        guard !stopped, vlcURL == nil else { return }
        // Taken either way; a recovery in progress has its own target.
        var held = heldSeek.take()
        if starvation.isRecovering { held = nil }
        if awaitingStartSeek {
            // The item failed before it could be positioned (its duration
            // is not even known): VLC resumes by position, at the start
            // position `vlcStartPosition` already holds — a rebuilt item
            // would play from 0:00.
            print("[Player] the item failed before its start seek — VLC at the start position")
            fallBackToVLC(failure.reason)
            return
        }
        if !isDirectPlayback {
            if let reason = remux?.failureReason {
                fallBackToVLC(reason, resumeTime: held)
                return
            }
            if failure.isMissingResource {
                print("[Player] HTTP 404 from the remux server — segment gone for good, not starvation")
                fallBackToVLC("Segment indisponible : \(failure.reason)", resumeTime: held)
                return
            }
        }
        let target = recoveryPosition(held: held)
        // The direct path's "already played" test needs where playback
        // stood: never a held target.
        let stood = target.isUserTarget ? recoveryPosition(held: nil).position : target.position
        if let player = player, let plan = starvationPlan(failurePosition: stood),
           starvation.handle(failure, player: player, position: target.position, resumesPlayback: playIntent.wantsPlayback,
                             positionIsUserTarget: target.isUserTarget,
                             stillDownloading: plan.stillDownloading, isDataReady: plan.isDataReady) {
            return
        }
        fallBackToVLC(failure.reason, resumeTime: held)
    }

    /// `RemuxPlayback.onUnavailableSegmentRequested`: VLC at once, at the
    /// earlier of the playhead and the requested pruned segment's start
    /// (`ResumePolicy.handOffTime`) — the playhead when it lies before that
    /// segment (« recommencer » in the kept segment 0 while AVPlayer
    /// prefetches the pruned segment 1; playback reaching a pruned span
    /// about a segment early), the segment's start for a scrub into the
    /// pruned range. Around a start seek, the first item — which loads at 0,
    /// not positioned — is a special case, as in the tvOS / iOS player:
    ///  - seek in flight: ignored (a prefetch from 0 of segments the remux,
    ///    told the target at once, may have evicted; the seek moves the
    ///    item away and AVPlayer drops those requests);
    ///  - seek not issued yet (item not ready): its start-up data is gone
    ///    and it would never become ready — VLC at once, at the start
    ///    position (`vlcStartPosition`).
    private func unavailableSegmentRequested(at playerSeconds: Double) {
        guard !stopped, vlcURL == nil, !isDirectPlayback, remux != nil else { return }
        if startSeekTarget != nil {
            print("[Player] pruned segment requested at \(Int(playerSeconds)) s while the start seek is in flight — "
                  + "a prefetch of the item loaded at 0, ignored")
            return
        }
        if awaitingStartSeek {
            print("[Player] pruned segment requested at \(Int(playerSeconds)) s before the start seek — VLC at the start position")
            fallBackToVLC(ResumePolicy.rewindPastBufferReason)
            return
        }
        // Bounded storage: a rewind past the kept media is blocked (the
        // earliest point still available instead, never VLC); playback
        // reaching a pruned span ahead goes on below (VLC at the playhead,
        // when its data is still there: `fallBackToVLC`).
        if limitBoundedRewind(toPrunedSegmentAt: playerSeconds) { return }
        let target = ResumePolicy.handOffTime(prunedSegmentStart: playerSeconds, playhead: player?.currentTime().seconds)
        print("[Player] pruned segment requested at \(Int(playerSeconds)) s — target \(Int(target)) s")
        fallBackToVLC(ResumePolicy.rewindPastBufferReason, resumeTime: target)
    }

    /// Whether the data at the playhead can still arrive, and the test for
    /// "enough of it to play again" (remux frontier / direct: a position
    /// already played before `failurePosition` — a user rewind during the
    /// wait — else more torrent bytes). nil (→ VLC) when the remux stopped
    /// for good (`failureReason`).
    private func starvationPlan(failurePosition: Double) -> (stillDownloading: Bool, isDataReady: (Double, TimeInterval) -> Bool)? {
        if isDirectPlayback {
            let streamer = self.streamer
            let atFailure = streamer.torrentStatus.totalProgress
            // The whole file on disk (bounded storage: `isFileComplete`), else more of it.
            return (!streamer.isWholeFileOnDisk, { time, waited in
                // Bounded storage: a position whose data is gone never gets
                // ready (the recovery waits for the one
                // `limitRecoveringRewind` moved it to).
                if let session = BoundedStorageSession.session(for: streamer), session.isBounded,
                   !session.canSeek(to: time, fromPlayerTime: failurePosition) { return false }
                if streamer.isWholeFileOnDisk { return true }
                return StarvationPolicy.directDataReady(resumeTime: time, failurePosition: failurePosition,
                                                        progress: streamer.torrentStatus.totalProgress,
                                                        progressAtFailure: atFailure, waited: waited)
            })
        }
        guard let remux = remux, remux.failureReason == nil else { return nil }
        // The conversion still has something to write: it has not reached the
        // film's end, or a jump left holes it fills when playback goes there.
        let finished = (remux.session?.progress.finished ?? false) && remux.holeIndexes.isEmpty
        return (!finished, { [weak remux] time, _ in
            guard let remux = remux else { return false }
            // Bounded storage: a deleted segment never comes back (the
            // recovery waits for the playhead `limitRecoveringRewind` moved
            // instead of rebuilding there).
            if remux.isStorageBounded, !remux.isAvailable(playerSeconds: time) { return false }
            // On disk from that position on — which the frontier alone does
            // not say once a jump left holes below it.
            return remux.hasMedia(fromPlayerSeconds: time)
        })
    }

    /// Where to recover after the item failed (player timeline, s): the
    /// start seek's target while that seek is in flight; the
    /// user's seek target AVPlayer still held (`held`, `isUserTarget`:
    /// `currentTime()` now reads where playback was before that seek); else
    /// where playback stood.
    private func recoveryPosition(held: Double?) -> (position: Double, isUserTarget: Bool) {
        // The start seek's target while it is in flight: `currentTime()`
        // reads 0:00 again once the item has failed.
        if let target = startSeekTarget { return (target, false) }
        if let target = held { return (target, true) }
        if let time = player?.currentTime().seconds, time.isFinite, time > 0 { return (time, false) }
        return (lastKnownTime ?? 0, false)
    }

    private func makeStarvationRecovery() -> PlaybackStarvationRecovery {
        let recovery = PlaybackStarvationRecovery()
        recovery.onWaitingChanged = { [weak self, unowned recovery] waiting in
            self?.isRebuildingStuckItem = waiting && recovery.isRebuildingStuckItem
            self?.isWaitingForData = waiting
            // The wait is a jump's (the conversion was moved to that position):
            // « Resuming at … », not « the download is slower than playback ».
            guard let self = self, waiting, !recovery.isRebuildingStuckItem, !self.isResumingNatively,
                  self.remux?.isJumpWaiting == true, let time = recovery.resumeTime else { return }
            self.jumpLabelTarget = time
            self.showResumingText(ResumePolicy.clockString(seconds: time), target: time)
        }
        // Remux: a user seek during the wait moves the remux lookahead there
        // at once — the dead item requests nothing (direct path: no remux).
        recovery.onRetarget = { [weak self] seconds in
            guard let self = self, self.vlcURL == nil else { return }
            self.remux?.updatePlaybackPositions(played: self.playedPosition.lastPlayedTime, wanted: seconds)
        }
        // The user's play / pause on the dead item during the wait: the play
        // intent follows (`playerRateDidChange` ignores a recovering player).
        recovery.onUserPlaybackChanged = { [weak self] playing in
            self?.playIntent.noteUserPlayback(playing: playing)
        }
        // Remux: a waiting recovery stops as soon as the remux halts…
        recovery.abandonReason = { [weak self] in
            guard let self = self, !self.isDirectPlayback else { return nil }
            return self.remux?.failureReason
        }
        // …or once the download keeps growing while the remux frontier
        // stays frozen (stall cap → VLC, whose byte ranges get the torrent
        // to fetch the playhead's pieces).
        recovery.stallProbe = { [weak self] in
            guard let self = self, !self.isDirectPlayback, let session = self.remux?.session else { return nil }
            return (session.progress.mediaSeconds, self.streamer.torrentStatus.totalProgress)
        }
        // Its far-target pace starts from the download's pace this player's
        // own watch keeps (fed at every tick).
        recovery.farTargetHistory = { [weak self] in self?.farTarget.downloadHistory ?? [] }
        // A user target the in-order conversion can't reach soon: the
        // conversion jumps there when it can (the wait stays native) — VLC
        // there only when it can't.
        recovery.farTargetJump = { [weak self] seconds in
            guard let self = self, !self.isDirectPlayback, self.vlcURL == nil, let remux = self.remux else { return false }
            return remux.requestJump(toPlayerSeconds: seconds, reason: .requested)
        }
        recovery.makeItem = { [weak self] in
            guard let self = self, !self.stopped, let url = self.playbackURL else { return nil }
            return self.makePlayerItem(url: url)
        }
        recovery.onItemReplaced = { [weak self] item, restoresSelection in
            guard let self = self else { return }
            // Its readiness budget is the recovery's: 30 s, no extensions.
            self.installFailureObserver(on: item, isReplacement: true)
            self.noteAttachedItem(item)
            if !restoresSelection { PlaybackLanguagePreferences.applyPreferredMediaSelection(to: item) }
            // Direct path: the overlay coordinates with the NEW item's tracks.
            self.cueController?.bindNativeSubtitles(of: item)
            self.trackSummaries = []
            self.loggedAtmosVerdict = false
        }
        recovery.onResumed = { [weak self] _ in
            guard let self = self, !self.stopped, self.vlcURL == nil else { return }
            self.player?.play()
        }
        recovery.onGiveUp = { [weak self] reason in
            self?.fallBackToVLC(reason)
        }
        return recovery
    }

    /// 0…1 position: while a starvation recovery runs, the position it
    /// recovers (the user's new target after a seek during the wait); else
    /// the player's; else — once a recovery gave up — the position it was
    /// recovering; else the last position read from a ready item
    /// (NaN-safe).
    private func knownPlaybackFraction() -> Float? {
        if starvation.isRecovering, let time = starvation.resumeTime { return fraction(ofPlayerTime: time) }
        if let fraction = AVPlayerItemFailureObserver.playbackFraction(of: player) { return fraction }
        guard let time = starvation.abandonedTime ?? lastKnownTime else { return nil }
        return fraction(ofPlayerTime: time)
    }

    /// 0…1 share of the movie at `time` (player timeline): the ready item's
    /// duration, the last one seen, else (remux) the header's length.
    private func fraction(ofPlayerTime time: Double) -> Float? {
        var duration = player?.currentItem?.duration.seconds ?? .nan
        if !duration.isFinite || duration <= 0 { duration = lastKnownDuration ?? .nan }
        if !duration.isFinite || duration <= 0, let length = remux?.session?.playlistDurationSeconds, length > 0 {
            duration = length
        }
        return ResumePolicy.fraction(time: time, duration: duration)
    }

    /// The native path can't play this payload: switch the view to VLC on
    /// the torrent's direct HTTP endpoint — same stream, not restarted —
    /// where playback got (`resumeTime`, player timeline, s: an explicit
    /// target), clamped to `ResumePolicy.handOffMaxFraction`: a failure in
    /// the end credits continues there instead of restarting the movie.
    private func fallBackToVLC(_ reason: String, resumeTime: Double? = nil) {
        guard !stopped, vlcURL == nil else { return }
        // Bounded storage: VLC reads the torrent's file — never where it
        // was deleted (it would get HTTP 410 and stop).
        var resumeTime = resumeTime
        switch boundedHandOff(resumeTime: resumeTime) {
        case .asked: break
        case .at(let time): resumeTime = time
        case .end:
            endPlaybackForBoundedStorage(reason)
            return
        }
        guard let url = directURL else {
            showsLoadingSpinner = false
            statusLine = String(format: "Cannot play: %@".localized, reason)
            return
        }
        // The native part of the session, up to now (VLC gets it as nativeHighWater).
        noteHighWater()
        let reached = resumeTime.flatMap { fraction(ofPlayerTime: $0) } ?? knownPlaybackFraction()
        if let fraction = reached, fraction > 0.001 {
            vlcStartPosition = ResumePolicy.handOffFraction(reached: fraction)
        }
        print("[Player] native playback unavailable (\(reason)) — handing over to VLC at \(Int(vlcStartPosition * 100)) %")
        // VLC plays from here on (its controller takes the Playback menu):
        // nothing left to ask or to seek.
        MacPlaybackCommandCenter.shared.unregister(self)
        resumeQuestion = nil
        pendingResume = nil
        pendingPlaylistURL = nil
        isResumingNatively = false
        hideResuming()
        startSeekObservation?.invalidate()
        startSeekObservation = nil
        awaitingStartSeek = false
        startSeekTarget = nil
        isStartingPartWay = false
        starvation.cancel()
        failureObserver?.invalidate()
        failureObserver = nil
        firstFrameWatch?.invalidate()
        firstFrameWatch = nil
        cueSubscription = nil
        cueController?.detach()
        cueController = nil
        removePlayerObservers()
        player?.pause()
        // Release the HTTP connection to the torrent's local server.
        player?.replaceCurrentItem(with: nil)
        player = nil
        remux?.stop()
        remux = nil
        BoundedStorageSession.session(for: streamer)?.detachHTTPPlayer(self)
        statusLine = "Playing with VLC…".localized
        vlcURL = url
    }

    /// Formats AVPlayer resolved, refreshed asynchronously by the stats timer.
    private var trackSummaries: [PlayerTrackSummary] = []
    private var isLoadingTrackSummaries = false

    private func reloadTrackSummaries() {
        guard !isLoadingTrackSummaries, let item = player?.currentItem else { return }
        isLoadingTrackSummaries = true
        Task { @MainActor [weak self] in
            let summaries = await PlayerTrackSummary.load(from: item)
            guard let self = self else { return }
            self.trackSummaries = summaries
            self.isLoadingTrackSummaries = false
        }
    }

    /// 1 Hz: played / known position, a held seek target (and the far-target
    /// hand-off), the positions reported to the remux, the stuck-playback
    /// safety net, the one-time replacement of an item started on live EVENT
    /// playlists, stats.
    private func refreshStats() {
        // Loading: the stall rules need the clock even when no status comes.
        if player == nil, vlcURL == nil, !stopped, !loadingDone {
            applyLoadingPhase(loadingTracker.update(streamer: streamer, fromCallback: false))
        }
        // A saved position whose engine is not known yet (the player's own
        // limit of the wait is counted here).
        resolvePendingResume()
        // The resume question shows the clock time once the MKV header gave
        // the movie's length (the percentage before).
        if let question = resumeQuestion, question.durationSeconds <= 0,
           let length = remux?.session?.totalDurationSeconds, length > 0 {
            resumeQuestion?.durationSeconds = length
        }
        // The last position playback actually reached — playing through it,
        // item ready, not recovering (`PlayedPositionTracker`): a seek target
        // AVPlayer still waits for (held past the remux frontier) never
        // counts.
        if let player = player {
            playedPosition.note(time: player.currentTime().seconds, clock: ProcessInfo.processInfo.systemUptime,
                                isPlaying: player.timeControlStatus == .playing,
                                isItemReady: player.currentItem?.status == .readyToPlay,
                                isRecovering: starvation.isRecovering)
        }
        noteHeldSeek(isJump: false)
        checkFarSeekTarget()
        // Position / duration of a ready item — while a starvation recovery
        // runs, the position it recovers (it follows a user seek during the
        // wait).
        if starvation.isRecovering {
            if let time = starvation.resumeTime, time.isFinite, time >= 0 { lastKnownTime = time }
        } else if let item = player?.currentItem, item.status == .readyToPlay {
            let time = item.currentTime().seconds
            if time.isFinite, time >= 0 { lastKnownTime = time }
            let duration = item.duration.seconds
            if duration.isFinite, duration > 0 { lastKnownDuration = duration }
        }
        noteHighWater()
        tickUpNext()
        if MacPlaybackProgress.isCheckpointDue(), player?.timeControlStatus == .playing { saveProgressIfNeeded(status: .watching) }
        reportPlaybackPositions()
        checkResumingText()
        publishCommandState()
        checkStuckPlayback()
        checkDirectStall()
        checkBoundedReverseScan()
        rebuildLiveBornItemIfEnded()
        rebuildForLateSubtitlesIfDue()
        // The stats text only while it shows (it is hidden 10 s after the
        // start; "n" brings it back, up to date within a second): this used
        // to reload every track's format and rebuild the text once a second
        // for the whole film. Until the Atmos verdict below is logged, the
        // tracks are still read.
        guard (showStats && vlcURL == nil) || !loggedAtmosVerdict else { return }
        reloadTrackSummaries()
        var lines = ["Engine  \(engineLine)"]
        if player?.currentItem != nil {
            for track in trackSummaries {
                if track.mediaType == .video {
                    lines.append("Video   \(track.fourCC)  \(track.width)×\(track.height)")
                    continue
                }
                let atmos = track.fourCC == "ec-3" ? "  → Dolby (Atmos, rendu spatial macOS)" : ""
                lines.append("Audio   \(track.fourCC)  \(track.channels) ch\(atmos)")
                // One clear, greppable verdict line the first time the audio
                // format resolves — THE line to read for Atmos.
                if !loggedAtmosVerdict {
                    loggedAtmosVerdict = true
                    let jocSignalled = remux?.session?.audioRenditions.contains(where: { $0.isAtmos }) ?? false
                    if track.fourCC == "ec-3" && jocSignalled {
                        print("[Atmos] ✅ DOLBY ATMOS ACTIF — flux DD+ JOC (16 objets), AVPlayer décode ec-3 \(track.channels) ch. Rendu spatial: Centre de contrôle ▸ Son ▸ Audio spatial.")
                    } else if track.fourCC == "ec-3" {
                        print("[Atmos] DD+ (E-AC-3) natif, \(track.channels) ch — Atmos seulement si le flux porte du JOC")
                    } else {
                        print("[Atmos] ❌ pas d'Atmos — piste audio '\(track.fourCC)' \(track.channels) ch (il faut une release DD+/E-AC-3 Atmos)")
                    }
                }
            }
        }
        if let remux = remux {
            lines.append(contentsOf: remux.renditionSummary.map { "Track   \($0)" })
            lines.append("Remux   \(remux.statsSummary)")
        }
        if let cues = cueController {
            lines.append("Subs    \(cues.selected?.language ?? "off") · \(cues.available.count) available")
        }
        if starvation.isRecovering, let time = starvation.resumeTime {
            if starvation.isRebuildingStuckItem {
                lines.append("Recovery stuck playback: new item at \(ResumePolicy.clockString(seconds: time))")
            } else if starvation.isWaitingForPlay {
                lines.append("Recovery paused: new item on play, at \(ResumePolicy.clockString(seconds: time))")
            } else {
                lines.append("Recovery waiting for data at \(ResumePolicy.clockString(seconds: time)) · attempt "
                             + "\(starvation.attemptsWithoutProgress)/\(starvation.maxAttemptsWithoutProgress)")
            }
        } else if starvation.recoveryCount > 0 {
            lines.append("Recovery \(starvation.recoveryCount) starvation(s) overcome natively")
        }
        statsText = " " + lines.joined(separator: "\n ") + " "
    }

    /// Remux path, every tick — also while a starvation recovery runs — and
    /// at once when the current item's time jumps (a seek): the last
    /// position playback reached (`played`) and where the player needs
    /// data now (`wanted`: while recovering, the position the recovery
    /// waits for; during the start seek, its target — right after
    /// `seek(to:)` is issued `currentTime()` still reads 0:00; before the
    /// start seek of a native resume, the resume point: the item is not
    /// there yet, or still loads at 0:00, and the remux must not be told
    /// the player needs 0:00; else `currentTime()` — the playhead, or a
    /// pending seek target). The remux runs its lookahead from those and
    /// deletes only segments neither needs
    /// (`RemuxPlayback.updatePlaybackPositions`).
    private func reportPlaybackPositions() {
        guard !isDirectPlayback, vlcURL == nil, let remux = remux else { return }
        let time: Double?
        if starvation.isRecovering {
            time = starvation.resumeTime
        } else if let target = startSeekTarget {
            time = target
        } else if isResumingNatively, player == nil || awaitingStartSeek, let target = remux.resumeTargetSeconds {
            time = target
        } else {
            time = player?.currentTime().seconds
        }
        let wanted = time.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        remux.updatePlaybackPositions(played: playedPosition.lastPlayedTime, wanted: wanted)
    }

    /// END safety net (1 Hz, remux path). Once the remux has finished, every
    /// byte is local: an item frozen while the user wants it playing (ready,
    /// rate ≠ 0, time unmoved for `StuckPlaybackWatch.stuckSeconds`) won't
    /// recover by waiting, and AVPlayer posts no failure for it. In the end
    /// zone (last second / last segment) that is the natural end: paused, as
    /// AVPlayer does at an item's end. Elsewhere the item is rebuilt in
    /// place (at the stuck position, i.e. a pending seek target too), at
    /// most twice for one position, then VLC there. Never during a
    /// starvation recovery, over AirPlay or in Picture in Picture (a sample
    /// gap — timers suspended — restarts the observation).
    ///
    /// The same holds before the remux has finished once playback has run
    /// and the media to play at the frozen position is on disk
    /// (`RemuxPlayback.hasMedia`: 10 s of it): an item whose request for a
    /// segment was held too long may never play it (tvOS drops the video
    /// variant for good, `ResumePolicy.jumpNeedsNewItem`; the same rule
    /// here). Not before playback ever ran: a start waits for its first
    /// segments without being stuck.
    private func checkStuckPlayback() {
        guard let player = player else { return }
        let remux = isDirectPlayback ? nil : self.remux
        let time = player.currentTime().seconds
        let isFinished = remux?.isFinished == true
        let hasMediaThere = playedPosition.lastPlayedTime != nil && time.isFinite && !awaitingStartSeek
            && startSeekTarget == nil && remux?.hasMedia(fromPlayerSeconds: time) == true
        let eligible = (isFinished || hasMediaThere) && !starvation.isRecovering && !stopped && vlcURL == nil
            && !isPictureInPictureActive && !player.isExternalPlaybackActive
        guard let stuckAt = stuckWatch.note(time: time, clock: ProcessInfo.processInfo.systemUptime,
                                            wantsPlayback: player.rate != 0,
                                            isItemReady: player.currentItem?.status == .readyToPlay,
                                            isEligible: eligible),
              let finished = remux else { return }
        // On AVPlayer's timeline: the EXTINF list it plays (VOD: the frozen
        // list; EVENT: the real durations).
        let session = finished.session
        let endZone = StuckPlaybackWatch.endZoneStart(segmentDurations: session?.playerTimelineDurations()
                                                                        ?? session?.segmentDurations() ?? [],
                                                      itemDuration: player.currentItem?.duration.seconds)
        let action = stuckWatch.decide(at: stuckAt, endZoneStart: endZone)
        print("[Player] AVPlayer stuck at \(String(format: "%.3f", stuckAt)) s on "
              + (isFinished ? "a finished remux" : "media that is on disk")
              + " (end zone from \(endZone.map { String(format: "%.3f", $0) } ?? "?") s) → \(action)")
        switch action {
        case .naturalEnd:
            player.pause()
            tellUpNextTheEnd("stuck at the end of a finished remux")
        case .rebuild:
            starvation.rebuildNow(player: player, at: stuckAt, reason: StuckPlaybackWatch.reason)
        case .fallback:
            fallBackToVLC(StuckPlaybackWatch.reason, resumeTime: stuckAt)
        }
    }

    /// Bounded storage, direct path, 1 Hz: AVPlayer waiting for 8 s at the
    /// same time while the data ahead of the server's read position is on
    /// disk is not waiting for the download — macOS AVPlayer's loader stops
    /// requesting after a far seek's back-fill reached deleted data (part-3
    /// coverage md2–md5). The item is rebuilt at the playhead
    /// (`BoundedDirectStallWatch`). Full mode: never.
    private func checkDirectStall() {
        guard let player = player else { return }
        let isWaiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            && player.currentItem?.status == .readyToPlay
        let eligible = isWaiting && isDirectPlayback && vlcURL == nil && !stopped && !starvation.isRecovering
            && boundedStorage?.isBounded == true && boundedStorage?.hasDataAheadOfReader() == true
        guard let time = directStall.note(time: player.currentTime().seconds, clock: ProcessInfo.processInfo.systemUptime,
                                          isWaiting: isWaiting, isEligible: eligible) else { return }
        print("[Player] bounded direct route: AVPlayer waiting at \(String(format: "%.1f", time)) s for "
              + "\(Int(BoundedDirectStallWatch.stallSeconds)) s with the data on disk → rebuilding the item")
        starvation.rebuildNow(player: player, at: time, reason: BoundedDirectStallWatch.reason)
    }

    /// Bounded storage, 1 Hz: a reverse scan (J key, a held rewind) stops at
    /// the earliest point still available, with the message, and plays on
    /// from there (`BoundedStorageUX.reverseScanLimit`).
    private func checkBoundedReverseScan() {
        guard let player = player, isItemHealthy, !stopped else { return }
        let now = player.currentTime().seconds
        guard let landing = BoundedStorageUX.reverseScanLimit(time: now, rate: player.rate,
                                                              playedReference: playedPosition.lastPlayedTime,
                                                              session: boundedStorage) else { return }
        player.rate = BoundedStorageUX.resumeRate(after: player)
        limitRewind(target: now, from: playedPosition.lastPlayedTime ?? now, landing: landing)
    }

    /// A new current item (the first one, a recovery's replacement): when
    /// AVPlayer starts it on live EVENT playlists — remux of a file without a
    /// Matroska Duration that hasn't finished yet — it is replaced once the
    /// remux has finished (`rebuildLiveBornItemIfEnded`).
    private func noteAttachedItem(_ item: AVPlayerItem) {
        let remux = isDirectPlayback ? nil : self.remux
        liveBornWatch.attached(ObjectIdentifier(item),
                               isEventSession: (remux?.session?.totalDurationSeconds ?? 1) <= 0,
                               remuxFinished: remux?.isFinished ?? true)
        // Its master playlist has every OpenSubtitles list known so far.
        lateSubtitles.attached()
        loadCommandTracks(of: item)
    }

    /// Remux path, 1 Hz: AVFoundation keeps the live bookkeeping of an item
    /// it started on EVENT playlists after it sees ENDLIST, and that item
    /// later breaks (seekable range collapsed, seeks and audio / subtitle
    /// switches that never complete — `LiveBornItemWatch`). So once the
    /// remux has finished, that item is rebuilt once in place at the current
    /// time through the stuck-item path (selection and position kept, under
    /// 0.3 s without picture), playing on only if the user wants playback
    /// (`PlaybackIntentWatch`). Waits for the
    /// next tick while a recovery runs, over AirPlay or in Picture in
    /// Picture.
    private func rebuildLiveBornItemIfEnded() {
        guard let player = player, !isDirectPlayback, vlcURL == nil, let remux = remux else { return }
        let time = player.currentTime().seconds
        let eligible = !starvation.isRecovering && !stopped && time.isFinite && time >= 0
            && !isPictureInPictureActive && !player.isExternalPlaybackActive
        guard liveBornWatch.shouldRebuild(current: player.currentItem.map { ObjectIdentifier($0) },
                                          remuxFinished: remux.isFinished, isEligible: eligible) else { return }
        let playing = playIntent.wantsPlayback
        print("[Player] remux finished: replacing the item AVPlayer started on live EVENT playlists at "
              + "\(String(format: "%.3f", time)) s (\(playing ? "playing" : "paused"))")
        starvation.rebuildNow(player: player, at: time, reason: LiveBornItemWatch.reason,
                              resumesPlayback: playing, exactPosition: true)
    }

    /// Remux path, 1 Hz: the OpenSubtitles list came after AVPlayer read the
    /// master playlist (`LateSubtitlesWatch`: it reads it once). The item is
    /// rebuilt once in place on a master that lists it, the way a live-born
    /// one is (selection and position kept, playing on only if the user
    /// wants playback); subtitles the user did not choose get the preferred
    /// language's, as on a first start. Waits for the next tick while a
    /// recovery runs, a start part-way has not landed, over AirPlay or in
    /// Picture in Picture.
    private func rebuildForLateSubtitlesIfDue() {
        guard let player = player, !isDirectPlayback, vlcURL == nil, remux != nil, player.currentItem != nil else { return }
        let time = player.currentTime().seconds
        let eligible = !starvation.isRecovering && !stopped && time.isFinite && time >= 0
            && !awaitingStartSeek && startSeekTarget == nil
            && !isPictureInPictureActive && !player.isExternalPlaybackActive
        guard lateSubtitles.shouldRebuild(isEligible: eligible) else { return }
        let playing = playIntent.wantsPlayback
        print("[Player] OpenSubtitles answered after the master playlist was read: replacing the item at "
              + "\(String(format: "%.3f", time)) s (\(playing ? "playing" : "paused")) for its subtitles")
        starvation.rebuildNow(player: player, at: time, reason: LateSubtitlesWatch.reason,
                              resumesPlayback: playing, exactPosition: true, picksSubtitlesAnew: true)
    }

    /// The session's furthest native position (1 Hz, and at close).
    private func noteHighWater() {
        guard player != nil, vlcURL == nil, let fraction = knownPlaybackFraction() else { return }
        highWater = max(highWater, fraction)
    }

    /// Closing the native player: saves the known position (≥ 80 % marks the
    /// title watched) — never below the session's resume point unless it
    /// played past it. Nothing while buffering, and nothing once VLC took
    /// over: MacVLCController saves its own position.
    private func saveProgressIfNeeded(status: Trakt.WatchedStatus = .finished) {
        guard !stopped, vlcURL == nil, player != nil, let media,
              let fraction = knownPlaybackFraction(), fraction > 0 else { return }
        noteHighWater()
        MacPlaybackProgress.save(fraction, for: media, resumePoint: resumePoint, highWater: highWater,
                                 status: status, profileID: profileID)
    }

    /// `MacAVPlayerRepresentable`: Picture in Picture started / ended.
    func pictureInPictureChanged(_ active: Bool) {
        isPictureInPictureActive = active
    }

    // MARK: - Playback menu

    /// The current item's audio and subtitle choices (loaded once per item).
    private var commandGroups: (item: AVPlayerItem, audible: AVMediaSelectionGroup?, legible: AVMediaSelectionGroup?)?

    /// The native player answers the Playback menu from now on
    /// (`MacPlaybackCommandCenter`), until VLC takes over or it stops.
    private func registerPlaybackCommands() {
        MacPlaybackCommandCenter.shared.register(self, handlers: MacPlaybackCommandHandlers(
            togglePlay: { [weak self] in self?.commandTogglePlay() },
            skip: { [weak self] seconds in self?.commandSkip(by: seconds) },
            selectAudioTrack: { [weak self] id in self?.commandSelectAudioTrack(id) },
            selectSubtitleTrack: { [weak self] id in self?.commandSelectSubtitleTrack(id) }))
        publishCommandState()
    }

    /// Play / Pause, as the player view's own button does (a rate change:
    /// the play intent and a waiting recovery follow it the same way).
    private func commandTogglePlay() {
        guard let player = player, vlcURL == nil else { return }
        if player.rate != 0 { player.pause() } else { player.play() }
    }

    /// ±10 s: a seek like the player view's own — its time jump goes
    /// through the same checks (the remux's positions, bounded storage).
    private func commandSkip(by seconds: Double) {
        guard let player = player, vlcURL == nil, let item = player.currentItem, item.status == .readyToPlay else { return }
        let now = player.currentTime().seconds
        guard now.isFinite else { return }
        var target = max(0, now + seconds)
        let duration = item.duration.seconds
        if duration.isFinite, duration > 0 { target = min(target, max(0, duration - 1)) }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func loadCommandTracks(of item: AVPlayerItem) {
        Task { @MainActor [weak self, weak item] in
            guard let asset = item?.asset else { return }
            let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard let self = self, let item = item, self.player?.currentItem === item else { return }
            self.commandGroups = (item, audible, legible)
            self.publishCommandState()
        }
    }

    /// The file's own subtitles the menu lists (never the forced-only ones:
    /// they show by themselves).
    private static func commandSubtitleOptions(in group: AVMediaSelectionGroup) -> [AVMediaSelectionOption] {
        group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
    }

    private static let commandSubtitlesOffID = "off"

    /// What the Playback menu shows: playing or paused, the item's audio
    /// tracks, and the subtitles — the remux's own tracks, or on the direct
    /// path the OpenSubtitles entries of the overlay (`SubtitleCueController`,
    /// what the sheet's subtitle button offers).
    private func publishCommandState() {
        guard let player = player, vlcURL == nil, !stopped else { return }
        var state = MacPlaybackCommandState(isPlaying: player.rate != 0)
        let groups = commandGroups.flatMap { $0.item === player.currentItem ? $0 : nil }
        if let groups, let audible = groups.audible, audible.options.count > 1 {
            let selected = groups.item.currentMediaSelection.selectedMediaOption(in: audible)
            state.audioTracks = audible.options.enumerated().map { index, option in
                MacCommandTrack(id: String(index), name: option.displayName, isSelected: option == selected)
            }
        }
        let off = "Off".localized
        if let cues = cueController {
            state.subtitleTracks = [MacCommandTrack(id: Self.commandSubtitlesOffID, name: off, isSelected: cues.areSubtitlesOff)]
                + cues.available.map { subtitle in
                    MacCommandTrack(id: subtitle.link, name: ExternalSubtitleLoader.menuTitle(for: subtitle),
                                    isSelected: cues.selected == subtitle)
                }
        } else if let groups, let legible = groups.legible {
            let options = Self.commandSubtitleOptions(in: legible)
            if !options.isEmpty {
                let selected = groups.item.currentMediaSelection.selectedMediaOption(in: legible)
                state.subtitleTracks = [MacCommandTrack(id: Self.commandSubtitlesOffID, name: off,
                                                        isSelected: selected.map { !options.contains($0) } ?? true)]
                    + options.enumerated().map { index, option in
                        MacCommandTrack(id: String(index), name: option.displayName, isSelected: option == selected)
                    }
            }
        }
        MacPlaybackCommandCenter.shared.update(self, state)
    }

    private func commandSelectAudioTrack(_ id: String) {
        guard let groups = commandGroups, groups.item === player?.currentItem, let audible = groups.audible,
              let index = Int(id), audible.options.indices.contains(index) else { return }
        groups.item.select(audible.options[index], in: audible)
        publishCommandState()
    }

    private func commandSelectSubtitleTrack(_ id: String) {
        if let cues = cueController {
            // As the sheet's subtitle button: nil turns the overlay and the
            // file's own non-forced subtitles off.
            if id == Self.commandSubtitlesOffID {
                cues.select(nil)
            } else if let subtitle = cues.available.first(where: { $0.link == id }) {
                cues.select(subtitle)
            }
        } else if let groups = commandGroups, groups.item === player?.currentItem, let legible = groups.legible {
            let options = Self.commandSubtitleOptions(in: legible)
            if id == Self.commandSubtitlesOffID {
                groups.item.select(nil, in: legible)
            } else if let index = Int(id), options.indices.contains(index) {
                groups.item.select(options[index], in: legible)
            }
        }
        publishCommandState()
    }

    // MARK: - Bounded storage

    /// The stream's bounded storage. Its `isBounded` is false in full mode:
    /// nothing below acts then.
    private var boundedStorage: BoundedStorageSession? { BoundedStorageSession.session(for: streamer) }

    /// The loading screen's line, at most every 5 s (it reads the free space).
    private func refreshBoundedNote() {
        guard !boundedPlaybackEnded else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - boundedNoteAt >= 5 || (boundedNote == nil && boundedStorage?.isBounded == true) else { return }
        boundedNoteAt = now
        boundedNote = BoundedStorageUX.loadingNote(for: streamer)
        #if DEBUG
        if boundedNote != nil { MacDebugHooks.snapshotPlayerWindow(named: "bounded-loading", after: 1) }
        #endif
    }

    /// Bounded storage, after a time jump of a healthy item (the player
    /// view's scrubber, ±15 s, the keyboard, a remote command): a playhead
    /// that went further back than what is still on disk goes to the
    /// earliest point still available, with the message — the user's
    /// decision: no new download, no VLC for a rewind. Checked 0.35 s after
    /// the last jump of a burst: a drag on the timeline is not fought.
    private func scheduleBoundedRewindCheck() {
        guard boundedStorage?.isBounded == true else { return }
        boundedRewindCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.checkBoundedRewind() }
        }
        boundedRewindCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func checkBoundedRewind() {
        guard isItemHealthy, let player = player else { return }
        let now = player.currentTime().seconds
        // From the last position playback actually reached (not a seek
        // target AVPlayer still holds: a far seek forward, then back, stays
        // allowed).
        guard let reference = playedPosition.lastPlayedTime,
              let landing = BoundedStorageUX.limitedRewindTarget(now, from: reference, session: boundedStorage) else { return }
        limitRewind(target: now, from: reference, landing: landing)
    }

    /// `unavailableSegmentRequested` in bounded mode: a pruned segment
    /// BEHIND the last played position is a rewind past the kept media —
    /// blocked: the playhead goes to the earliest point still available
    /// (unless it is already there: the request was the blocked seek's).
    /// False for a pruned span ahead, and outside bounded mode.
    private func limitBoundedRewind(toPrunedSegmentAt playerSeconds: Double) -> Bool {
        guard let session = boundedStorage, session.isBounded, let player = player,
              let reference = playedPosition.lastPlayedTime, playerSeconds < reference else { return false }
        let now = player.currentTime().seconds
        let earliest = session.earliestRewindTime(fromPlayerTime: reference) ?? reference
        if now.isFinite, now >= earliest { return true }
        // AVKit seeks all along a timeline drag, and each pruned segment it
        // asks for lands here — the time-jump check limits the rewind 0.35 s
        // after the last jump instead, so the drag is not fought.
        if isItemHealthy {
            scheduleBoundedRewindCheck()
            return true
        }
        let target = now.isFinite ? min(now, reference) : playerSeconds
        let landing = BoundedStorageUX.limitedRewindTarget(target, from: reference, session: session) ?? reference
        limitRewind(target: target, from: reference, landing: landing)
        return true
    }

    /// Bounded storage, during a starvation recovery: the user moved the
    /// dead item's playhead into deleted media. Instead of VLC there, it
    /// goes to the earliest point still available — the recovery follows it
    /// as the user's new target at its next look — with the message. True
    /// when it did.
    private func limitRecoveringRewind(to seconds: Double) -> Bool {
        guard let session = boundedStorage, session.isBounded, player != nil,
              let reference = playedPosition.lastPlayedTime, seconds < reference else { return false }
        let landing = BoundedStorageUX.limitedRewindTarget(seconds, from: reference, session: session) ?? reference
        limitRewind(target: seconds, from: reference, landing: landing)
        return true
    }

    /// Moves the playhead to `landing` (a limited rewind) and says why.
    private func limitRewind(target: Double, from reference: Double, landing: Double) {
        BoundedStorageUX.logLimited(player: "AVPlayer", target: target, playhead: reference, landing: landing,
                                    session: boundedStorage)
        // Remux path: the rewind stopped at the edge of what a native jump
        // skipped (a resume, a far seek) — never downloaded, which is what
        // the message then says (`isRewindFloorNeverDownloaded`).
        if !isDirectPlayback, boundedStorage?.isRewindFloorNeverDownloaded == true {
            print("[Resume] rewind to \(String(format: "%.1f", target)) s blocked at \(String(format: "%.1f", landing)) s "
                  + "(bounded, never downloaded)")
        }
        player?.seek(to: CMTime(seconds: landing, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        let toast = BoundedStorageToastMessage(text: BoundedStorageUX.rewindLimitedMessage(for: boundedStorage))
        boundedToast = toast
        DispatchQueue.main.asyncAfter(deadline: .now() + BoundedStorageToastMessage.visibleSeconds) { [weak self] in
            guard let self, self.boundedToast?.id == toast.id else { return }
            self.boundedToast = nil
        }
        #if DEBUG
        MacDebugHooks.snapshotPlayerWindow(named: "bounded-toast", after: 1)
        #endif
    }

    /// Bounded storage: the hand-off to VLC at `resumeTime` (nil: the
    /// current position) would read deleted torrent data (HTTP 410). VLC
    /// continues where playback was instead when THAT is still there (a
    /// rewind target that is gone); `.end` when nothing can play here.
    private enum BoundedHandOff { case asked, at(Double), end }

    private func boundedHandOff(resumeTime: Double?) -> BoundedHandOff {
        guard let session = boundedStorage, session.isBounded, player != nil else { return .asked }
        let current: Double? = {
            if starvation.isRecovering, let time = starvation.resumeTime { return time }
            if let player = player, player.currentItem?.status == .readyToPlay {
                let time = player.currentTime().seconds
                if time.isFinite, time >= 0 { return time }
            }
            return starvation.abandonedTime ?? lastKnownTime
        }()
        guard let wanted = resumeTime ?? current, !session.canResumeOverHTTP(atPlayerSeconds: wanted) else { return .asked }
        if let played = playedPosition.lastPlayedTime, played > wanted, session.canResumeOverHTTP(atPlayerSeconds: played) {
            print("[Bounded] VLC can't resume at \(Int(wanted)) s (deleted) — at the last played position \(Int(played)) s")
            return .at(played)
        }
        print("[Bounded] VLC can't resume at \(Int(wanted)) s: that part of the torrent is deleted")
        return .end
    }

    /// Bounded storage: native playback can't go on and VLC can't resume
    /// where it would have to (deleted): stop, cancel the stream (its disk
    /// space comes back at once) and say so on the player's status screen,
    /// which stays as it is until the user closes the player (the stream's
    /// progress, still reported every 0.5 s until the cancel lands, no
    /// longer overwrites it: `boundedPlaybackEnded`).
    private func endPlaybackForBoundedStorage(_ reason: String) {
        print("[Bounded] native playback unavailable (\(reason)) and its data is deleted — stopped")
        boundedPlaybackEnded = true
        MacPlaybackCommandCenter.shared.unregister(self)
        noteHighWater()
        starvation.cancel()
        failureObserver?.invalidate()
        failureObserver = nil
        firstFrameWatch?.invalidate()
        firstFrameWatch = nil
        boundedRewindCheck?.cancel()
        cueSubscription = nil
        cueController?.detach()
        cueController = nil
        removePlayerObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        remux?.stop()
        remux = nil
        BoundedStorageSession.session(for: streamer)?.detachHTTPPlayer(self)
        isWaitingForData = false
        isResumingNatively = false
        resumeQuestion = nil
        pendingResume = nil
        hideResuming()
        buffering = 0
        loadingDone = true
        showsLoadingSpinner = false
        loadingPhase = .starting
        // Title on the status line, the reason under it (one sentence each).
        statusLine = BoundedStorageUX.cannotContinueTitle
        boundedNote = BoundedStorageUX.cannotContinueMessage
        // Nothing can play this stream any more: give its space back now
        // (`stop()` cancels again when the player closes — harmless).
        streamer.cancelStreamingAndDeleteData(true)
    }

    /// Episode chaining: the finished episode's stream stops and its data is
    /// deleted BEFORE the next one starts in the same sheet — `stop()` keeps
    /// the data, and the next stream's purge would not run while this
    /// controller's view has not disappeared yet (SwiftUI's order of
    /// `onDisappear` / `onAppear` is not given). Bounded storage gets its
    /// space back, and the same season pack can be added again (one stream
    /// per torrent: error -7 otherwise).
    ///
    /// `then` runs once the space the stream held is back: libtorrent
    /// closes and deletes its file on its own thread, and the next stream
    /// measures the free space as it starts (bounded storage: a start
    /// before that failed with « not enough space », the -5 seen on the
    /// rig). At most `spaceWait` seconds.
    func stopForNextEpisode(then next: @escaping () -> Void = {}) {
        guard !stopped else { return next() }
        let folder = streamer.savePath
        let volume = folder.map { ($0 as NSString).deletingLastPathComponent }
        let held = folder.map(Self.allocatedBytes) ?? 0
        let before = volume.flatMap(Self.freeBytes) ?? 0
        // Only when space is short (bounded storage, or a few GB free):
        // elsewhere the free space other apps change would only delay the
        // start for nothing.
        let isTight = boundedStorage?.isBounded == true || before < Self.tightFreeBytes
        stop(deletingData: true)
        let gone = folder.map { !FileManager.default.fileExists(atPath: $0) } ?? true
        print("[UpNext] Mac: the finished episode's stream stopped, its data deleted "
              + "(\(folder.map { ($0 as NSString).lastPathComponent } ?? "no folder") \(gone ? "gone" : "STILL THERE"), "
              + "\(held / 1_048_576) MiB held)")
        guard let volume, held > 0, isTight else { return next() }
        let started = ProcessInfo.processInfo.systemUptime
        var last: Int64 = -1
        func check() {
            let free = Self.freeBytes(volume) ?? 0
            let waited = ProcessInfo.processInfo.systemUptime - started
            // Back (90 % of what the folder held) and settled, or waited enough.
            if (free >= before + held * 9 / 10 && free == last) || waited >= Self.spaceWait {
                print("[UpNext] Mac: \(free / 1_048_576) MiB free after \(String(format: "%.1f", waited)) s "
                      + "(\(before / 1_048_576) MiB before the stop) — the next episode starts")
                return next()
            }
            last = free
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { check() }
        }
        check()
    }

    /// The longest the next episode waits for the space of the finished one.
    static let spaceWait: TimeInterval = 8
    /// Below this free space the next episode waits for the finished one's.
    static let tightFreeBytes: Int64 = 6 * 1_073_741_824

    private static func freeBytes(_ path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        if let important = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        return (try? FileManager.default.attributesOfFileSystem(forPath: path)[.systemFreeSize] as? NSNumber)?.int64Value
    }

    /// What a folder takes on disk (allocated, not logical: bounded storage
    /// and sparse files).
    private static func allocatedBytes(_ path: String) -> Int64 {
        guard let items = FileManager.default.enumerator(at: URL(fileURLWithPath: path),
                                                         includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in items {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    func stop(deletingData: Bool = false) {
        #if DEBUG
        debugObservers.forEach { NotificationCenter.default.removeObserver($0) }
        debugObservers = []
        #endif
        saveProgressIfNeeded()
        stopped = true
        MacPlaybackCommandCenter.shared.unregister(self)
        statsTimer?.invalidate()
        statsTimer = nil
        startSeekObservation?.invalidate()
        startSeekObservation = nil
        deficitSubscription = nil
        deficitMonitor?.detach(self)
        starvation.cancel()
        failureObserver?.invalidate()
        failureObserver = nil
        firstFrameWatch?.invalidate()
        firstFrameWatch = nil
        cueSubscription = nil
        cueController?.detach()
        removePlayerObservers()
        boundedRewindCheck?.cancel()
        player?.pause()
        player = nil
        remux?.stop()
        remux = nil
        BoundedStorageSession.session(for: streamer)?.detachHTTPPlayer(self)
        streamer.cancelStreamingAndDeleteData(deletingData)
    }
}

/// AVKit's native macOS player view (controls, PiP, fullscreen).
struct MacAVPlayerRepresentable: NSViewRepresentable {
    let player: AVPlayer
    /// Picture in Picture started (true) / ended (false).
    var onPictureInPictureChanged: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// The sheet's minimum size: AVKit's content view never starts at zero
    /// (its width / height == 0 constraints conflicted with its own).
    static let initialSize = CGSize(width: 1024, height: 576)

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(frame: NSRect(origin: .zero, size: Self.initialSize))
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        context.coordinator.onChange = onPictureInPictureChanged
        view.pictureInPictureDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
        context.coordinator.onChange = onPictureInPictureChanged
    }

    /// A proposal without a size (sheet appearing, view swap) gets the
    /// sheet's minimum, never zero.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVPlayerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: Self.initialSize)
    }

    /// Reports the view's Picture in Picture state.
    final class Coordinator: NSObject, AVPlayerViewPictureInPictureDelegate {
        var onChange: ((Bool) -> Void)?

        func playerViewWillStartPicture(inPicture playerView: AVPlayerView) {
            onChange?(true)
        }

        func playerView(_ playerView: AVPlayerView, failedToStartPictureInPictureWithError error: Error) {
            onChange?(false)
        }

        func playerViewDidStopPicture(inPicture playerView: AVPlayerView) {
            onChange?(false)
        }
    }
}
