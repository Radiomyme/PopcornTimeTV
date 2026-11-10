

import Foundation
import AVFoundation
import VideoToolbox

// CONTRACT FILE — owned by agent B1. Shared by the tvOS, iOS and macOS apps.

/// Watches an AVPlayerItem for fatal playback failures (status `.failed`,
/// `AVPlayerItemFailedToPlayToEndTime`, or never reaching `.readyToPlay`
/// within `readyTimeout` while data is available) and reports the FIRST one
/// on the main queue — as a reason string (`init(item:readyTimeout:onFailure:)`)
/// or as a structured `Failure` (`init(item:readyTimeout:onReport:)`) the
/// caller can classify: download starvation (keep the native player, see
/// `PlaybackStarvationRecovery`) vs. a real decode / format problem (hand the
/// stream over to VLC).
///
/// It also loads the asset's playability: an asset AVFoundation can open but
/// whose video (or every audio) track can't be decoded — e.g. an MP4 with an
/// `hev1` HEVC sample entry, or DTS / TrueHD as the only audio — counts as a
/// failure (AVPlayer would otherwise sit on a black screen or play silently).
/// HLS assets (the remux path) expose no tracks to this check; their
/// failures surface through the item's status.
///
/// Ordinary buffering stalls (`AVPlayerItemPlaybackStalled`, a slow swarm)
/// are NOT failures. Every report is delivered asynchronously on the main
/// queue, at most once; observation stops right after it (and on
/// `invalidate()` / deinit).
final class AVPlayerItemFailureObserver {

    /// What went wrong, as reported to `init(item:readyTimeout:onReport:)`.
    struct Failure {
        enum Kind: Equatable {
            /// The item's `status` became `.failed`.
            case itemFailed
            /// `AVPlayerItemFailedToPlayToEndTime`: the item stopped for good
            /// (its `status` may stay `.readyToPlay`).
            case failedToPlayToEnd
            /// Never `.readyToPlay` within the (extended) readiness timeout.
            case readyTimeout
            /// The asset's video / every audio track can't be played.
            case unplayable
        }
        let kind: Kind
        /// The AVFoundation error, when there is one.
        let error: Error?
        /// Human-readable reason (logs, VLC hand-off).
        let reason: String

        /// What `error` says about the media (`classify(_:)`).
        var errorClass: ErrorClass { AVPlayerItemFailureObserver.classify(error) }

        /// An HTTP 404 somewhere in the error chain
        /// (`isMissingResource(_:)`).
        var isMissingResource: Bool { AVPlayerItemFailureObserver.isMissingResource(error) }
    }

    /// What an AVFoundation error says about the media.
    enum ErrorClass: Equatable {
        /// The data didn't arrive in time (segment / byte-range request
        /// timed out, connection dropped): the media is fine, the download
        /// is slower than playback.
        case starvation
        /// The media itself can't be decoded / parsed: only another engine
        /// (VLC) can play it.
        case format
        /// Anything else.
        case other
    }

    /// Asked on the main queue when `readyTimeout` elapses before the item
    /// is `.readyToPlay`: return true to grant another `readyTimeout` period
    /// (typically "the torrent is still downloading the bytes AVPlayer waits
    /// for"). Granted at most `maxReadyTimeoutExtensions` times.
    var shouldExtendReadyTimeout: (() -> Bool)?
    var maxReadyTimeoutExtensions = 3

    /// True once a failure has been reported.
    private(set) var hasReportedFailure = false

    private weak var item: AVPlayerItem?
    private let readyTimeout: TimeInterval?
    private var onReport: ((Failure) -> Void)?
    private var statusObservation: NSKeyValueObservation?
    private var notificationObservers: [NSObjectProtocol] = []
    private var timeoutWorkItem: DispatchWorkItem?
    private var playabilityTask: Task<Void, Never>?
    private var extensionsUsed = 0
    private var isInvalidated = false

    /// - Parameters:
    ///   - item: the item to watch (held weakly).
    ///   - readyTimeout: seconds allowed to reach `.readyToPlay`; nil = no timeout.
    ///   - onFailure: called at most once, on the main queue, with a reason.
    convenience init(item: AVPlayerItem, readyTimeout: TimeInterval? = nil, onFailure: @escaping (String) -> Void) {
        self.init(item: item, readyTimeout: readyTimeout, onReport: { failure in onFailure(failure.reason) })
    }

    /// - Parameters:
    ///   - item: the item to watch (held weakly).
    ///   - readyTimeout: seconds allowed to reach `.readyToPlay`; nil = no timeout.
    ///   - onReport: called at most once, on the main queue, with the failure.
    init(item: AVPlayerItem, readyTimeout: TimeInterval? = nil, onReport: @escaping (Failure) -> Void) {
        self.item = item
        self.readyTimeout = readyTimeout
        self.onReport = onReport
        // Background / @Sendable closures only get this weak box, and only
        // dereference it on the main queue.
        let ref = WeakRef(self)

        // `.initial` catches an item that is already failed / ready.
        statusObservation = item.observe(\.status, options: [.initial, .new]) { _, _ in
            DispatchQueue.main.async { ref.observer?.statusDidChange() }
        }
        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
                                                        object: item, queue: .main) { note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let reason = "Lecture interrompue : \(AVPlayerItemFailureObserver.describe(error))"
            ref.observer?.report(Failure(kind: .failedToPlayToEnd, error: error, reason: reason))
        })
        if let timeout = readyTimeout, timeout > 0 {
            if Thread.isMainThread {
                armReadyTimeout(after: timeout)
            } else {
                DispatchQueue.main.async { ref.observer?.armReadyTimeout(after: timeout) }
            }
        }
        let asset = item.asset
        playabilityTask = Task.detached(priority: .utility) {
            guard let problem = await AVPlayerItemFailureObserver.playabilityProblem(of: asset),
                  !Task.isCancelled else { return }
            DispatchQueue.main.async { ref.observer?.report(Failure(kind: .unplayable, error: nil, reason: problem)) }
        }
    }

    /// Weak reference for closures that may run off the main thread; only
    /// dereferenced on the main queue, hence `@unchecked Sendable`.
    private final class WeakRef: @unchecked Sendable {
        weak var observer: AVPlayerItemFailureObserver?
        init(_ observer: AVPlayerItemFailureObserver) { self.observer = observer }
    }

    deinit {
        invalidate()
    }

    /// Stop observing (idempotent). Also called on deinit.
    func invalidate() {
        isInvalidated = true
        statusObservation?.invalidate()
        statusObservation = nil
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        playabilityTask?.cancel()
        playabilityTask = nil
        onReport = nil
        shouldExtendReadyTimeout = nil
    }

    // MARK: - Events (main queue)

    private func statusDidChange() {
        guard !isInvalidated, let observed = item else { return }
        switch observed.status {
        case .failed:
            var reason = "Échec AVPlayer : \(Self.describe(observed.error))"
            // HLS failures (remux path) carry the useful detail in the error log.
            if let event = observed.errorLog()?.events.last {
                let comment = event.errorComment ?? ""
                reason += " [log \(event.errorDomain) \(event.errorStatusCode)\(comment.isEmpty ? "" : " " + comment)]"
            }
            report(Failure(kind: .itemFailed, error: observed.error, reason: reason))
        case .readyToPlay:
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
        default:
            break
        }
    }

    private func armReadyTimeout(after seconds: TimeInterval) {
        guard !isInvalidated else { return }
        timeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.readyTimeoutFired() }
        timeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func readyTimeoutFired() {
        guard !isInvalidated, !hasReportedFailure, let item = item, let timeout = readyTimeout else { return }
        switch item.status {
        case .readyToPlay:
            return
        case .failed:
            statusDidChange()
            return
        default:
            break
        }
        if extensionsUsed < maxReadyTimeoutExtensions, shouldExtendReadyTimeout?() == true {
            extensionsUsed += 1
            let waited = Int((timeout * Double(extensionsUsed)).rounded())
            print("[Player] AVPlayer not ready after \(waited) s — still waiting for data (extension \(extensionsUsed)/\(maxReadyTimeoutExtensions))")
            armReadyTimeout(after: timeout)
            return
        }
        let waited = Int((timeout * Double(extensionsUsed + 1)).rounded())
        report(Failure(kind: .readyTimeout, error: nil, reason: "AVPlayer toujours pas prêt après \(waited) s"))
    }

    private func report(_ failure: Failure) {
        guard !isInvalidated, !hasReportedFailure else { return }
        hasReportedFailure = true
        let callback = onReport
        invalidate()
        print("[Player] AVPlayer failure: \(failure.reason)")
        callback?(failure)
    }

    // MARK: - Failure classification (pure)

    /// Starvation / format / other, from the error and its underlying chain
    /// (AVFoundation wraps the CoreMedia / URL error that matters). A format
    /// error anywhere in the chain wins.
    static func classify(_ error: Error?) -> ErrorClass {
        var current = error.map { $0 as NSError }
        var sawStarvation = false
        var depth = 0
        while let ns = current, depth < 8 {
            if isFormatError(domain: ns.domain, code: ns.code) { return .format }
            if isStarvationError(domain: ns.domain, code: ns.code) { sawStarvation = true }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return sawStarvation ? .starvation : .other
    }

    /// AVFoundation codes saying the media can't be decoded / parsed.
    static let formatErrorCodes: Set<Int> = Set([
        AVError.Code.decodeFailed, .invalidSourceMedia, .fileFormatNotRecognized, .fileFailedToParse,
        .contentIsProtected, .decoderNotFound, .contentIsNotAuthorized, .operationNotSupportedForAsset,
        .incompatibleAsset, .failedToParse, .undecodableMediaData, .formatUnsupported, .noSourceTrack,
    ].map { $0.rawValue })

    /// Decoder statuses (OSStatus) that CoreMedia surfaces as is.
    static let decoderErrorStatuses: Set<Int> = Set([
        kVTCouldNotFindVideoDecoderErr, kVTVideoDecoderBadDataErr, kVTVideoDecoderUnsupportedDataFormatErr,
        kVTVideoDecoderMalfunctionErr, kVTVideoDecoderReferenceMissingErr, kVTVideoDecoderUnknownErr,
    ].map { Int($0) })

    /// CoreMedia (HLS) codes of a request that went unanswered:
    /// -12889 "No response for media file in N s" and -15628, both logged
    /// when the remux server holds a segment past AVPlayer's ~6 s per-request
    /// timeout (F3 x1: a 45 s stall ends in FailedToPlayToEnd -12889 with the
    /// item still `.readyToPlay`); -12888 "Playlist File unchanged for longer
    /// than 1.5 * target duration" (an EVENT playlist that stops growing).
    static let starvationCoreMediaCodes: Set<Int> = [-12889, -15628, -12888]

    static func isFormatError(domain: String, code: Int) -> Bool {
        switch domain {
        case AVFoundationErrorDomain:
            return formatErrorCodes.contains(code)
        case "CoreMediaErrorDomain", NSOSStatusErrorDomain:
            // 'fmt?': kAudioFormatUnsupportedDataFormatError / kAudioConverterErr_FormatNotSupported.
            return decoderErrorStatuses.contains(code) || code == 0x666d743f
        default:
            return false
        }
    }

    /// CoreMedia code of an HLS resource answered with HTTP 404
    /// ("HTTP 404: File Not Found"), usually under NSURLErrorDomain -1100.
    static let notFoundCoreMediaCodes: Set<Int> = [-12938]

    /// True when the server answered HTTP 404 for a resource of the item:
    /// NSURLErrorFileDoesNotExist (-1100) or CoreMedia -12938 anywhere in
    /// the underlying-error chain. Measured: AVPlayer retries a 404 segment
    /// with back-off for ~30 s, then posts FailedToPlayToEnd
    /// (NSURLErrorDomain -1100 ← CoreMediaErrorDomain -12938) with the item
    /// still `.readyToPlay`. On the remux path a 404 means "will NEVER
    /// exist" (pruned — deleted for good —, past the end of a finished or
    /// halted remux, unknown rendition) — `RemuxPlayback` holds, then
    /// answers 503, anything that may still appear, and holds a pruned
    /// segment requested ahead of the playhead until playback gets near it —
    /// so it is not starvation: the players hand over to VLC at once. A 503 (a held
    /// request past its deadline, an evicted waiter) is not a 404: it
    /// reaches AVPlayer as NSURLErrorResourceUnavailable (-1008) ←
    /// CoreMedia -16849 "HTTP 503", which `classify` calls starvation.
    static func isMissingResource(_ error: Error?) -> Bool {
        var current = error.map { $0 as NSError }
        var depth = 0
        while let ns = current, depth < 8 {
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorFileDoesNotExist { return true }
            if ns.domain == "CoreMediaErrorDomain" && notFoundCoreMediaCodes.contains(ns.code) { return true }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    static func isStarvationError(domain: String, code: Int) -> Bool {
        switch domain {
        case "CoreMediaErrorDomain":
            return starvationCoreMediaCodes.contains(code)
        case NSURLErrorDomain:
            return [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost,
                    NSURLErrorResourceUnavailable].contains(code)
        case NSPOSIXErrorDomain:
            return code == Int(ETIMEDOUT) || code == Int(ECONNRESET)
        default:
            return false
        }
    }

    /// True when `failure` is download starvation the player recovers from
    /// by rebuilding the item once more data exists, false when it calls for
    /// the VLC fallback. `stillDownloading`: the data at the playhead can
    /// still arrive (remux not finished / torrent incomplete).
    ///  - FailedToPlayToEnd: starvation unless the error is a decode / format
    ///    error — an unclassified error counts only while downloading;
    ///  - item failed: only with a starvation error (timeouts);
    ///  - readiness timeout / unplayable tracks: never (VLC).
    static func isStarvation(_ failure: Failure, stillDownloading: Bool) -> Bool {
        let errorClass = failure.errorClass
        switch failure.kind {
        case .failedToPlayToEnd:
            switch errorClass {
            case .format: return false
            case .starvation: return true
            case .other: return stillDownloading
            }
        case .itemFailed:
            return errorClass == .starvation
        case .readyTimeout, .unplayable:
            return false
        }
    }

    // MARK: - Playability (async asset loading)

    /// nil when the asset looks playable (or can't be judged: HLS, loading
    /// cancelled), else a human-readable reason.
    static func playabilityProblem(of asset: AVAsset) async -> String? {
        do {
            guard try await asset.load(.isPlayable) else {
                return "Média non lisible par AVPlayer"
            }
            let tracks = try await asset.load(.tracks)
            let video = tracks.filter { $0.mediaType == .video }
            let audio = tracks.filter { $0.mediaType == .audio }
            if !video.isEmpty {
                let decodable = try await containsDecodableTrack(video)
                if !decodable {
                    let codecs = await codecList(video)
                    return "Piste vidéo non décodable (\(codecs))"
                }
            }
            if !audio.isEmpty {
                let decodable = try await containsDecodableTrack(audio)
                if !decodable {
                    let codecs = await codecList(audio)
                    return "Aucune piste audio décodable (\(codecs))"
                }
            }
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            if Task.isCancelled { return nil }
            return "Échec de chargement du média : \(describe(error))"
        }
    }

    private static func containsDecodableTrack(_ tracks: [AVAssetTrack]) async throws -> Bool {
        for track in tracks {
            let (playable, decodable) = try await track.load(.isPlayable, .isDecodable)
            if playable && decodable { return true }
        }
        return false
    }

    /// "hev1, ac-3" — the sample-entry FourCCs, for logs.
    private static func codecList(_ tracks: [AVAssetTrack]) async -> String {
        var codes: [String] = []
        for track in tracks {
            let descriptions = (try? await track.load(.formatDescriptions)) ?? []
            for description in descriptions {
                codes.append(fourCC(CMFormatDescriptionGetMediaSubType(description)))
            }
        }
        return codes.isEmpty ? "?" : codes.joined(separator: ", ")
    }

    // MARK: - Helpers

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
        let printable = bytes.allSatisfy { (0x20...0x7e).contains($0) }
        return printable ? String(decoding: bytes, as: UTF8.self) : String(format: "0x%08x", code)
    }

    static func describe(_ error: Error?) -> String {
        guard let error = error else { return "erreur inconnue" }
        let ns = error as NSError
        var text = "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " ← \(underlying.domain) \(underlying.code)"
        }
        return text
    }

    /// Current position of `player` as a 0…1 fraction of its item's
    /// duration, nil while unknown (not ready, live / indefinite duration).
    static func playbackFraction(of player: AVPlayer?) -> Float? {
        guard let player = player, let item = player.currentItem, item.status == .readyToPlay else { return nil }
        let duration = item.duration.seconds
        let time = player.currentTime().seconds
        guard duration.isFinite, duration > 0, time.isFinite, time >= 0 else { return nil }
        return Float(min(max(time / duration, 0), 1))
    }
}

/// Format AVPlayer resolved for one track of the playing item — what the
/// nerd-stats overlays print ("Audio ec-3 6 ch" is the proof Apple's renderer
/// receives the raw E-AC-3 / Atmos).
struct PlayerTrackSummary {
    let mediaType: AVMediaType
    /// Sample-entry FourCC ("hvc1", "dvh1", "avc1", "ec-3", "fLaC"…).
    let fourCC: String
    let width: Int
    let height: Int
    let channels: Int

    /// Loads the formats of the item's current tracks with the async asset
    /// API (no deprecated synchronous getters).
    @MainActor
    static func load(from item: AVPlayerItem) async -> [PlayerTrackSummary] {
        var summaries: [PlayerTrackSummary] = []
        for track in item.tracks {
            guard let assetTrack = track.assetTrack else { continue }
            let mediaType = assetTrack.mediaType
            guard mediaType == .video || mediaType == .audio,
                  let description = (try? await assetTrack.load(.formatDescriptions))?.first else { continue }
            var width = 0, height = 0, channels = 0
            if mediaType == .video, let size = try? await assetTrack.load(.naturalSize) {
                width = Int(size.width)
                height = Int(size.height)
            }
            if mediaType == .audio, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                channels = Int(asbd.pointee.mChannelsPerFrame)
            }
            let fourCC = AVPlayerItemFailureObserver.fourCC(CMFormatDescriptionGetMediaSubType(description))
            summaries.append(PlayerTrackSummary(mediaType: mediaType, fourCC: fourCC,
                                                width: width, height: height, channels: channels))
        }
        return summaries
    }
}

/// The audio / subtitle choice of an item, re-applicable to a NEW item of
/// the same presentation (the starvation recovery rebuilds the item): per
/// group, either "automatic" (AVPlayer's criteria decide — forced subtitles
/// included) or the explicit option, nil meaning off.
struct MediaSelectionSnapshot {
    struct Entry {
        let characteristic: AVMediaCharacteristic
        /// No explicit pick: AVPlayer's automatic selection was in effect.
        let isAutomatic: Bool
        /// The explicitly selected option (all nil = explicitly off).
        let propertyList: Any?
        let languageTag: String?
        let displayName: String?
        /// The selected option is a machine translation
        /// (`PlaybackLanguagePreferences.isMachineGenerated`).
        let isMachineGenerated: Bool
        let index: Int?
        let optionCount: Int

        /// The same option in `group` (another asset of the same media):
        /// the one its property list names, else language + name, else the
        /// option at its position — the first and the last only when they
        /// have its language tag and machine-generated status. OS 27: a late
        /// OpenSubtitles rendition replaces AVFoundation's machine translation
        /// into its language on items built on the later masters, and a
        /// machine translation's property list then names, like its position,
        /// whatever option sits there now — another language (measured).
        func matchingOption(in group: AVMediaSelectionGroup) -> AVMediaSelectionOption? {
            func isSame(_ option: AVMediaSelectionOption) -> Bool {
                option.extendedLanguageTag == languageTag
                    && PlaybackLanguagePreferences.isMachineGenerated(option) == isMachineGenerated
            }
            if let plist = propertyList, let option = group.mediaSelectionOption(withPropertyList: plist), isSame(option) {
                return option
            }
            let named = group.options.filter { $0.displayName == displayName && $0.extendedLanguageTag == languageTag }
            if named.count == 1 { return named[0] }
            if let index = index, group.options.count == optionCount, group.options.indices.contains(index),
               isSame(group.options[index]) {
                return group.options[index]
            }
            return named.first
        }
    }

    let entries: [Entry]

    /// The audible + legible selection of `item`; nil when its asset has
    /// neither group (or they can't load).
    @MainActor
    static func capture(from item: AVPlayerItem) async -> MediaSelectionSnapshot? {
        let asset = item.asset
        var entries: [Entry] = []
        for characteristic in [AVMediaCharacteristic.audible, .legible] {
            guard let group = try? await asset.loadMediaSelectionGroup(for: characteristic) else { continue }
            let selection = item.currentMediaSelection
            let option = selection.selectedMediaOption(in: group)
            entries.append(Entry(characteristic: characteristic,
                                 isAutomatic: selection.mediaSelectionCriteriaCanBeAppliedAutomatically(to: group),
                                 propertyList: option?.propertyList(),
                                 languageTag: option?.extendedLanguageTag,
                                 displayName: option?.displayName,
                                 isMachineGenerated: option.map { PlaybackLanguagePreferences.isMachineGenerated($0) } ?? false,
                                 index: option.flatMap { group.options.firstIndex(of: $0) },
                                 optionCount: group.options.count))
        }
        return entries.isEmpty ? nil : MediaSelectionSnapshot(entries: entries)
    }

    /// Applies every entry to `item` once its groups have loaded; returns
    /// what was applied (logs). A subtitle option the new item no longer has
    /// (`matchingOption` finds none) gives way to the app's own ranking,
    /// never to AVPlayer's pick — another language: in the entry's language
    /// first, else in the preferred subtitle language
    /// (`rankedLegibleOption`). On OS 27 that is how a machine translation
    /// goes: a late OpenSubtitles list adds a rendition in its language to
    /// the later masters, AVFoundation then offers no translation into it on
    /// items built on them, and the ranking picks that rendition. An
    /// automatic entry stays automatic.
    @MainActor
    @discardableResult
    func apply(to item: AVPlayerItem) async -> [String] {
        var applied: [String] = []
        for entry in entries {
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: entry.characteristic) else { continue }
            let kind = entry.characteristic == .audible ? "audio" : "sous-titres"
            if entry.isAutomatic {
                item.selectMediaOptionAutomatically(in: group)
                applied.append("\(kind) auto")
            } else if entry.propertyList == nil && entry.displayName == nil {
                item.select(nil, in: group)
                applied.append("\(kind) off")
            } else if let option = entry.matchingOption(in: group) {
                item.select(option, in: group)
                applied.append("\(kind) \(option.displayName)")
            } else if entry.characteristic == .legible,
                      let option = await Self.rankedLegibleOption(in: group, languageTag: entry.languageTag, of: item) {
                item.select(option, in: group)
                applied.append("\(kind) \(option.displayName) (classement)")
            } else {
                applied.append("\(kind) introuvable")
            }
        }
        return applied
    }

    /// The app's subtitle pick in `group` of `item`
    /// (`PlaybackLanguagePreferences.preferredLegibleOption`; an HLS master's
    /// DEFAULT rendition first, as on a first start) in the language of
    /// `languageTag` — what the user was reading —, else in the preferred
    /// subtitle language; nil when neither has a candidate.
    @MainActor
    private static func rankedLegibleOption(in group: AVMediaSelectionGroup, languageTag: String?,
                                            of item: AVPlayerItem) async -> AVMediaSelectionOption? {
        var codes: [String] = []
        if let tag = languageTag, let code = PlaybackLanguagePreferences.isoCode(for: tag) { codes.append(code) }
        if let preferred = PlaybackLanguagePreferences.preferredSubtitleLanguageCode, !codes.contains(preferred) {
            codes.append(preferred)
        }
        guard !codes.isEmpty else { return nil }
        let names = await PlaybackLanguagePreferences.loadNames(of: group.options)
        let isHLS = (item.asset as? AVURLAsset)?.url.pathExtension.lowercased() == "m3u8"
        for code in codes {
            if let option = PlaybackLanguagePreferences.preferredLegibleOption(in: group, code: code, names: names,
                                                                              prefersGroupDefault: isHLS) {
                return option
            }
        }
        return nil
    }
}

/// The user's play / pause INTENT, and when a native owner CHECKPOINTS the
/// watched progress (pure — the harness tests it). Fed by the owners'
/// `AVPlayer.rateDidChangeNotification` observer (`noteRateChange`: the
/// player's rate and the notification's reason).
///
/// - Intent (`wantsPlayback`): whether the user wants the movie playing —
///   what a starvation recovery and any rebuild of the item end in
///   (`PlaybackStarvationRecovery.handle(…resumesPlayback:…)`,
///   `rebuildNow(…resumesPlayback:…)`): left paused when false, so the movie
///   never restarts by itself while the user is away. Only a change with a
///   reason counts — the user's play / pause through AVKit or the owner's
///   own calls (`.setRateCalled`), the system's (`.audioSessionInterrupted`,
///   `.appBackgrounded`) — and only on a healthy item (`isHealthy`: no
///   recovery or rebuild running — they pause and play the player
///   themselves —, no start seek, no hand-off, the item not failed).
///   AVPlayer's own stop when an item fails carries no reason and comes
///   right AFTER the failure notification, when the owner's recovery already
///   runs (measured on a held HLS segment: FailedToPlayToEnd -12889 at rate
///   1, then rate 0 with no reason 1 ms later); `.setRateFailed` (a rate the
///   item couldn't take) isn't the user's either. While a starvation recovery
///   waits, the user's play / pause on the dead item reaches the intent
///   through the recovery instead (`noteUserPlayback(playing:)`).
/// - Checkpoint: the first pause the user makes — a counted change to rate 0
///   other than `.appBackgrounded`, which the owners' background checkpoint
///   covers — while the owner can save (`canCheckpoint`: the item ready):
///   `noteRateChange` returns true, once per pause (playback running again
///   starts a new one). A kill while suspended (tvOS has no background
///   mode) or a crash later then keeps what was watched.
struct PlaybackIntentWatch {
    /// What a checkpoint saves (the Trakt status).
    enum CheckpointStatus: Equatable {
        /// The user paused, or the app left the foreground and playback stops.
        case paused
        /// Playback goes on in the background (Picture in Picture, AirPlay).
        case watching
    }

    /// The user wants the movie playing: true until a counted pause.
    private(set) var wantsPlayback = true
    /// The current pause was checkpointed; reset when playback runs again.
    private(set) var checkpointedThisPause = false

    init() {}

    /// One rate change of the owner's player: `rate` after the change,
    /// `reason` = the notification's `AVPlayer.rateDidChangeReasonKey`.
    /// - Returns: true when the owner checkpoints the watched progress now
    ///   (`.paused`).
    mutating func noteRateChange(rate: Float, reason: AVPlayer.RateDidChangeReason?, isHealthy: Bool,
                                 canCheckpoint: Bool) -> Bool {
        let playing = rate != 0
        if playing { checkpointedThisPause = false }
        guard isHealthy, let reason = reason, reason != .setRateFailed else { return false }
        wantsPlayback = playing
        guard !playing, canCheckpoint, reason != .appBackgrounded, !checkpointedThisPause else { return false }
        checkpointedThisPause = true
        return true
    }

    /// The user played (`playing`) or paused the dead item while a starvation
    /// recovery waits (`PlaybackStarvationRecovery.onUserPlaybackChanged`;
    /// the owners' rate observer ignores the player while a recovery runs):
    /// the intent follows. No checkpoint: nothing plays.
    mutating func noteUserPlayback(playing: Bool) {
        if playing { checkpointedThisPause = false }
        wantsPlayback = playing
    }

    /// The app entered the background: the checkpoint's status — `.watching`
    /// when the user wants playback and it goes on there (Picture in Picture,
    /// AirPlay), else `.paused`.
    func backgroundCheckpointStatus(isPictureInPictureActive: Bool, isExternalPlaybackActive: Bool) -> CheckpointStatus {
        wantsPlayback && (isPictureInPictureActive || isExternalPlaybackActive) ? .watching : .paused
    }
}

/// The user's HELD seek target (pure — the harness tests it). Fed by the
/// native owners at every look at their positions — the 1 Hz tick and the
/// current item's time jumps — while the item is healthy (playback started,
/// no start seek, no recovery or rebuild, no hand-off, the item not failed
/// and its failure not reported).
///
/// A seek past what can be served soon — past the download, or so far ahead
/// that the sequential remux can't reach it in about 40 s — is HELD:
/// `currentTime()` reads the target at once, playback stays where it was,
/// and AVPlayer posts no time jump until the seek lands. When the data does
/// not come in time the item fails (FailedToPlayToEnd -12889, playing or
/// paused) and AVPlayer first resets `currentTime()` to where playback was
/// BEFORE the seek — in a main-queue turn of its own, about 1 ms before the
/// failure is delivered, with no time jump (measured on a held HLS segment).
/// A recovery or a VLC hand-off from `currentTime()` would silently undo the
/// user's seek: the owners take this target at the failure instead
/// (`take()`, `PlaybackStarvationRecovery.handle(…positionIsUserTarget:…)`).
/// On the remux path they need not wait for that failure: a held `target`
/// the in-order download (or the remux pump, over data on disk) can't bring
/// within about that hold — the remux
/// frontier's measured pace, `FarTargetWatch`, fed at the 1 Hz tick while
/// the user wants playback — goes to VLC at once, at the target.
///
/// `note(wanted:played:isJump:)`: `wanted` = `currentTime()` — the playhead,
/// or a pending seek target —, `played` =
/// `PlayedPositionTracker.lastPlayedTime` (never a held target):
///  - `wanted` more than `StarvationPolicy.userSeekThresholdSeconds` from
///    `played` (from 0 while nothing was played): a pending seek — the target
///    (a new one replaces the old);
///  - else, at a time jump: a seek that landed where playback is (the user
///    came back) — no target;
///  - else, at a tick: the target stays until playback is recorded after it
///    was set (`played` moved: it played at the target, or wherever the user
///    went). A tick that reads the reset position before the failure is
///    delivered sees no new playback, so the target survives it.
/// Between a landed seek (or a recovery's resume) and the next played sample
/// the target is the playhead itself: what `currentTime()` gives then.
struct HeldSeekWatch {
    /// The user's pending seek target (player timeline, s); nil when none.
    private(set) var target: Double?
    /// `played` when `target` was set.
    private var playedAtTarget: Double?

    init() {}

    /// One look at the healthy item's positions (player timeline, s);
    /// `isJump`: a time jump of the current item, else the 1 Hz tick.
    mutating func note(wanted: Double?, played: Double?, isJump: Bool) {
        guard let wanted = wanted, wanted.isFinite, wanted >= 0 else { return }
        if abs(wanted - (played ?? 0)) > StarvationPolicy.userSeekThresholdSeconds {
            target = wanted
            playedAtTarget = played
        } else if isJump || played != playedAtTarget {
            target = nil
            playedAtTarget = nil
        }
    }

    /// The target, forgotten: the owner hands it to the recovery, or to the
    /// VLC hand-off, of the failure it was held through.
    mutating func take() -> Double? {
        defer {
            target = nil
            playedAtTarget = nil
        }
        return target
    }
}

/// Keeps a native AVPlayer through DOWNLOAD STARVATION — shared by the iOS /
/// tvOS `RemuxAVPlayerViewController`, the macOS `MacPlayerController` and
/// the iOS `VideoPlayerWrapper`.
///
/// A torrent that downloads slower than the movie plays starves AVPlayer. On
/// the remux path the server holds the segment request; AVPlayer drops it
/// after ~6 s (-12889 "No response for media file"), retries, and after
/// ~37 s posts `AVPlayerItemFailedToPlayToEndTime` (-12889) while `status`
/// stays `.readyToPlay` — and that item never plays again, even once the
/// segments exist. A NEW item on the same URL, seeked to the same time, plays
/// (F3 x1). Handing such a stream to VLC would throw away HDR / Atmos for a
/// file that plays fine natively: the swarm is just slow.
///
/// The owner reports every failure of its item observer to `handle(…)`.
/// When it is starvation (`AVPlayerItemFailureObserver.isStarvation`) the
/// recovery takes over: player paused, buffering indicator on
/// (`onWaitingChanged`), the audio / subtitle selection captured; it waits
/// until `isDataReady(time, waited)` (remux frontier ≥ time + cushion / more
/// torrent bytes — `StarvationPolicy`). Then a new item (`makeItem`),
/// PRE-POSITIONED at the saved time before it is attached (its first media
/// request is the resume segment — never segments 1, 2… from the start,
/// which the remux may have pruned), replaces the dead one in the SAME
/// AVPlayer (`onItemReplaced`: install the item observer & co.), the
/// selection is re-applied, the item seeks precisely to the saved time once
/// ready and `onResumed` asks the owner to play.
///
/// The user may move the playhead while the recovery WAITS for data (AVKit's
/// transport bar stays usable under the buffering overlay). The failed item
/// never plays nor requests anything again, so each 1 Hz poll compares the
/// player's time with the previous one: a jump of more than
/// `StarvationPolicy.userSeekThresholdSeconds` is the user's new target. The
/// recovery then waits for THAT position (resume time, wait clock, stall cap
/// and attempt budget start over: a user seek consumes no automatic retry;
/// `onRetarget` tells the owner at once — the remux owners move the remux
/// lookahead there, the dead item requests nothing): at once a give-up AT
/// the target when `positionUnavailable` says it can never be played
/// natively again (a rewind into pruned remux segments), else `isDataReady`
/// decides — a rewind into existing data rebuilds at once, a seek ahead
/// waits for the data there. (A seek issued on the dead item does not
/// complete — its completion handler was not called within 12 s, measured —
/// but `currentTime()` moves to the target within a few ms: what the poll
/// reads. A seek still pending when the item failed is completed then,
/// `finished` false, and AVPlayer has reset `currentTime()` to where
/// playback was before it — neither tells that target: the owner passes it,
/// `handle(…positionIsUserTarget: true…)`, from its `HeldSeekWatch`.)
///
/// A user who had PAUSED (`handle(…resumesPlayback: false…)`, the owners'
/// `PlaybackIntentWatch`) is not resumed behind their back: a paused item
/// fails too — AVPlayer keeps buffering while paused and gives up on a held
/// segment (-12889), or on an EVENT playlist that stops growing while the
/// remux sits at its lookahead limit (-12888 → -11866, 43–51 s into the
/// pause, measured). The recovery then takes over without the buffering indicator and
/// waits for the user to press PLAY on the dead item (its rate, observed):
/// no rebuild, no abandon / stall-cap / data checks while the user stays
/// paused — so no rebuild loop and no auto-play — but a scrub still
/// retargets it. Play → the wait above starts (indicator, clock, stall cap),
/// then the rebuild and `onResumed`; pause again before the rebuild → back
/// to waiting for play. Nor is a user who pauses WHILE the recovery waits
/// for data: the user's play / pause on the dead item is observed in both
/// modes — a real play / pause TRANSITION with a user reason: AVPlayer's own
/// stop right after the failure has no reason, and AVKit's scrub posts
/// `setRate:0` notes (iOS 26's slider too, a Picture in Picture restore…)
/// on a player already at 0, which change nothing — a play press while
/// waiting for data changes nothing (playback resumes by itself once the
/// data is there), a pause switches to waiting for play as above once it
/// settled (`pauseSettleSeconds`) with the playhead where it was — AVKit's
/// scrub of a player the user had set playing pauses it, seeks, and restores
/// its rate only when that seek completes, never on a failed item: no pause
/// (`onUserPlaybackChanged` tells the owner's play intent). A play press
/// follows the playhead first, at once and
/// again once it settled (`playPressSettleSeconds`), before any check of the
/// wait: the user typically moves the playhead and presses play within the
/// poll period (tvOS: a scrub then a click; iOS: −10 s then play; Mac: the
/// scrubber then space), and the dead item's `currentTime()` can show such
/// a seek a few ms late — playback resumes at THAT position (`onRetarget`),
/// or VLC takes over there when it can never be played natively again.
/// `play()` on the failed item alone never plays again (it waits forever,
/// measured).
///
/// `rebuildNow(player:at:reason:resumesPlayback:exactPosition:)` runs the
/// same rebuild without a failure and without waiting: the remux owners'
/// safety net for an item stuck on complete data (`StuckPlaybackWatch`), and
/// their one-time replacement of an item AVPlayer started on live EVENT
/// playlists once the remux has finished (`LiveBornItemWatch`: at the exact
/// position, left paused when the user had paused).
///
/// Bounded — the owner then falls back to VLC like for any other failure:
///  - `handle` returns false after `maxAttemptsWithoutProgress` recoveries
///    in a row that didn't move playback past the previous resume point;
///  - `onGiveUp` when the rebuilt item isn't ready and positioned within
///    `rebuildReadyTimeout` (no extensions), when `abandonReason` reports a
///    reason while waiting (e.g. the remux halted), at the remux stall
///    cap (`stallProbe`: the download grew ≥ 1 % but the remux frontier
///    stayed frozen for `stallCapSeconds`), when the user moved the
///    playhead to an unavailable position while waiting, or when it waits
///    for a USER target (`resumeTimeIsUserTarget`) the remux frontier,
///    advancing at its measured pace (`stallProbe` samples,
///    `FarTargetWatch`), would take more than about AVPlayer's own hold of a
///    seek to reach — the in-order download gets there at its own pace,
///    while VLC's byte-range reads make the torrent fetch the target first.
/// The hand-off continues at the position being recovered: `resumeTime` is
/// still set while `onGiveUp` runs, `abandonedTime` keeps it afterwards. A
/// dead swarm (no download activity at all) has no cap: the spinner stays,
/// the user can close. Main queue only.
@MainActor
final class PlaybackStarvationRecovery {

    /// Recoveries in a row without playback progress before giving up.
    var maxAttemptsWithoutProgress = 3
    /// Seconds a rebuilt item gets to be ready and positioned (no
    /// extensions) before the recovery gives up.
    var rebuildReadyTimeout: TimeInterval = StarvationPolicy.rebuildReadyTimeout
    /// Remux stall cap (see `stallProbe`).
    var stallCapSeconds: TimeInterval = StarvationPolicy.remuxStallCapSeconds
    /// Paused-user mode: how long a play press on the dead item settles
    /// before the recovery acts on it (rebuild, abandon, stall cap). The
    /// playhead is read at the press and again then: the dead item's
    /// `currentTime()` can show a seek made right before the press a few ms
    /// late (~5 ms measured on a paused item), and acting on the stale time
    /// would resume at the old paused position.
    var playPressSettleSeconds: TimeInterval = 0.25
    /// How long a pause of the dead item while waiting for data settles
    /// before the recovery waits for play: AVKit's scrub pauses a player the
    /// user had set playing (`beginScrubbing:` → `setRate:0`) and seeks it
    /// within a drag event — and restores the rate only once that seek
    /// completes, which it never does on a failed item. A pause after which
    /// the playhead jumped is that scrub, not the user's pause.
    var pauseSettleSeconds: TimeInterval = 0.25

    /// Show (true) / hide the buffering indicator.
    var onWaitingChanged: ((Bool) -> Void)?
    /// A fresh item for the same media (URL, metadata, spatialization…).
    var makeItem: (() -> AVPlayerItem?)?
    /// The new item is the player's current item: install the failure
    /// observer, subtitle bindings, Up Next… `restoresSelection` is false
    /// when no selection could be captured (apply the preferred languages).
    var onItemReplaced: ((_ item: AVPlayerItem, _ restoresSelection: Bool) -> Void)?
    /// The new item sits at `time` (seek done): play when appropriate.
    var onResumed: ((_ time: Double) -> Void)?
    /// The recovery can't continue (no item could be built, the rebuilt item
    /// never became ready, `abandonReason`, stall cap, a user seek to a
    /// `positionUnavailable` position, a user target the download can't
    /// bring soon — `FarTargetWatch.reason`): fall back. Runs while
    /// `resumeTime` still holds the position being recovered.
    var onGiveUp: ((_ reason: String) -> Void)?
    /// Polled ~1 Hz while waiting for data: a non-nil reason ends the
    /// recovery at once (`onGiveUp`) — e.g. the remux stopped producing for
    /// good (`RemuxPlayback.failureReason`): the data will never come.
    var abandonReason: (() -> String?)?
    /// Remux path: the remux frontier (player timeline, s) and the torrent's
    /// `totalProgress` (0…1), polled ~1 Hz while waiting — the stall cap
    /// (`RemuxStallWatch`) and, for a user target, the frontier's pace
    /// (`FarTargetWatch`). nil, or a nil sample, = neither (direct paths).
    var stallProbe: (() -> (frontierSeconds: Double, downloadProgress: Float)?)?
    /// Remux owners: the download's recent changes their own far-target
    /// watch keeps (`FarTargetWatch.downloadHistory`, fed at every tick).
    /// The far-target pace restarted with the wait starts from them, so a
    /// pause or a slowdown of the download right at its start shows against
    /// the pace before. nil = none (the watch learns the pace as it goes).
    var farTargetHistory: (() -> [(time: TimeInterval, progress: Float)])?
    /// Owner hook. True when `seconds` (player timeline) can never be played
    /// natively again (remux path: the segment was pruned →
    /// `!remux.isAvailable(playerSeconds:)`; direct paths: nil).
    /// Consulted when the user moves the playhead while a recovery waits:
    /// the recovery then gives up AT that time (the abandon path the owners
    /// already route to VLC; `abandonedTime` = that time).
    var positionUnavailable: ((_ seconds: Double) -> Bool)?
    /// Owner hook: the user moved the playhead while the recovery waits —
    /// `seconds` (player timeline) is the new target, `resumeTime` already
    /// holds it. Called before `positionUnavailable` is consulted, from the
    /// 1 Hz poll or a play press on the dead item (paused-user mode). Remux
    /// owners report it to `RemuxPlayback.updatePlaybackPositions` at once,
    /// so the remux lookahead moves there before any rebuild (the dead item
    /// requests nothing).
    var onRetarget: ((_ seconds: Double) -> Void)?
    /// Owner hook: the user played (true) or paused (false) the dead item
    /// while the recovery waits, and the recovery acts on it — a pause while
    /// it waits for data (it then waits for play), a play press while it
    /// waits for play. The owners' play intent follows
    /// (`PlaybackIntentWatch.noteUserPlayback(playing:)`): their own rate
    /// observer ignores the player while a recovery runs.
    var onUserPlaybackChanged: ((_ playing: Bool) -> Void)?

    /// Waiting for data or rebuilding the item.
    private(set) var isRecovering = false
    /// Position being recovered (player timeline, s) — the user's new target
    /// after a seek during the wait; nil when idle.
    private(set) var resumeTime: Double?
    /// True while `resumeTime` is a target the user picked — during this
    /// recovery's wait (`onRetarget`), or the seek AVPlayer still held when
    /// the item failed (`handle(…positionIsUserTarget: true…)`) — kept when
    /// its rebuilt item fails again, still true inside `onGiveUp`; cleared
    /// when the recovery ends (read it BEFORE a `handle(…)` that may end it).
    /// Lets an owner whose playback never started hand VLC that target rather
    /// than its configured start position.
    private(set) var resumeTimeIsUserTarget = false
    /// True while the recovery in progress is a `rebuildNow` (an item stuck
    /// on complete data), not download starvation: owners show their
    /// spinner without the "download slower than playback" text.
    private(set) var isRebuildingStuckItem = false
    /// True while the recovery in progress waits for the user to press play
    /// before it rebuilds (`handle(…resumesPlayback: false…)`: the user had
    /// paused — or paused the dead item while it waited for data) — no
    /// buffering indicator, no rebuild meanwhile.
    private(set) var isWaitingForPlay = false
    /// The rebuild in progress ends with `onResumed` (the owner plays);
    /// false: it ends paused, without `onResumed` (`rebuildNow`'s
    /// `resumesPlayback`, or a paused user who hasn't pressed play).
    private var rebuildResumesPlayback = true
    /// The player's rate changes while a starvation recovery waits (the
    /// user's play / pause on the dead item); removed when released.
    private var rateObserver: ObserverToken?
    /// The dead item's playing state as last seen: what the recovery's own
    /// pause in `begin` left, then what each rate note left. Only a note
    /// that changes it is a play / pause (`userPlaybackChanged`).
    private var observedPlaying = false
    /// A play press on the dead item is settling (`playPressSettleSeconds`):
    /// the 1 Hz poll only follows the playhead meanwhile.
    private var isSettlingPlayPress = false
    /// A pause while waiting for data is settling (`pauseSettleSeconds`):
    /// the 1 Hz poll only follows the playhead meanwhile.
    private var isSettlingPause = false
    /// Bumped by every play / pause on the dead item: only the latest press
    /// — a play or a pause — settles.
    private var playPressCount = 0
    /// The `rebuildNow` in progress seeks exactly to its time, not up to 2 s
    /// before (`exactPosition`).
    private var rebuildSeeksExactly = false
    /// The position a recovery was recovering when it ended without
    /// resuming (`onGiveUp`, or `handle` returned false while recovering /
    /// after the budget): where the owner's VLC hand-off continues once
    /// `resumeTime` is cleared. nil after a native resume and while a new
    /// recovery runs.
    private(set) var abandonedTime: Double?
    private(set) var attemptsWithoutProgress = 0
    /// Recoveries started in this session (logs, stats).
    private(set) var recoveryCount = 0

    private weak var player: AVPlayer?
    private var isDataReady: ((_ time: Double, _ waited: TimeInterval) -> Bool)?
    /// Playback never started and the owner's resume seek was still pending
    /// (duration unknown): the rebuilt item resumes at this 0…1 share of
    /// its duration once ready.
    private var pendingStartFraction: Float?
    private var lastResumeTime: Double?
    private var failureDate = Date()
    private var generation = 0
    private var snapshot: MediaSelectionSnapshot?
    private var snapshotGeneration = 0
    private var snapshotPending = false
    private var replacement: AVPlayerItem?
    private var statusObservation: NSKeyValueObservation?
    private var selectionApplied = false
    private var isSeeking = false
    private var loggedWaitSteps = 0
    private var stallWatch = RemuxStallWatch()
    /// The pace of the remux frontier toward a USER target while waiting
    /// (`stallProbe`): restarted with the wait — `begin`, `retarget(to:)`, a
    /// play press — from the owner's download history (`farTargetHistory`).
    private var farTargetWatch = FarTargetWatch()
    /// The player's time at the previous look while waiting — a poll or a
    /// play press (the first one at `begin`): only a user seek moves it.
    private var observedPlayerTime: Double?

    init() {}

    /// Takes over when `failure` is starvation: returns true (recovering),
    /// false when it isn't — or after too many fruitless attempts — so the
    /// owner falls back to VLC (a recovery in progress then leaves its
    /// position in `abandonedTime`).
    /// - Parameters:
    ///   - position: playback position at the failure (player timeline, s);
    ///     ignored when the failing item is the recovery's own replacement.
    ///   - resumeFraction: playback never started and the owner's resume
    ///     seek is still pending (the item wasn't ready, its duration
    ///     unknown): the 0…1 start position the rebuilt item seeks to once
    ///     its duration is known. `position` is then only the
    ///     pre-positioning hint (0 when unknown).
    ///   - resumesPlayback: the user wants playback (`PlaybackIntentWatch`).
    ///     false — the user had paused —: the recovery waits for the user to
    ///     press play before it rebuilds (`isWaitingForPlay`, see the type's
    ///     doc). Ignored when the failing item is the recovery's own
    ///     replacement: the recovery in progress keeps its mode.
    ///   - positionIsUserTarget: `position` is the user's seek target that
    ///     AVPlayer still held when the item failed (the owner's
    ///     `HeldSeekWatch`; `currentTime()` was reset to the pre-seek
    ///     position): recovered as the user's target (`resumeTimeIsUserTarget`
    ///     from the start), as after a user seek during the wait — the attempt
    ///     budget aside, which counts as for any failure (the owner hands
    ///     each held target over once). Ignored when the failing item is the
    ///     recovery's own replacement.
    ///   - stillDownloading: the data at the playhead can still arrive.
    ///   - isDataReady: polled ~1 Hz with the resume time and the seconds
    ///     waited: true once enough data exists to play again.
    func handle(_ failure: AVPlayerItemFailureObserver.Failure, player: AVPlayer, position: Double,
                resumeFraction: Float? = nil,
                resumesPlayback: Bool = true,
                positionIsUserTarget: Bool = false,
                stillDownloading: Bool,
                isDataReady: @escaping (_ time: Double, _ waited: TimeInterval) -> Bool) -> Bool {
        let wasRecovering = isRecovering
        // A rebuilt item that failed again: the user pressed play to get there
        // — or it is a rebuild that ends paused (`rebuildNow`).
        let waitsForPlay = wasRecovering ? (isWaitingForPlay || !rebuildResumesPlayback) : !resumesPlayback
        var time = wasRecovering ? (resumeTime ?? position) : position
        if !time.isFinite || time < 0 { time = lastResumeTime ?? 0 }
        guard AVPlayerItemFailureObserver.isStarvation(failure, stillDownloading: stillDownloading) else {
            // Decode / format error, readiness timeout…: VLC. A recovery in
            // progress (its rebuilt item failed) hands over where it was.
            if wasRecovering {
                print("[Player] starvation recovery: not starvation (\(failure.reason)) — handing over at \(Self.seconds(time))")
                abandonedTime = time
                cancel()
            }
            return false
        }
        if StarvationPolicy.madeProgress(position: time, since: lastResumeTime) {
            attemptsWithoutProgress = 0
        } else {
            time = StarvationPolicy.resumeTime(position: time, lastResume: lastResumeTime)
        }
        guard attemptsWithoutProgress < maxAttemptsWithoutProgress else {
            print("[Player] starvation recovery: \(attemptsWithoutProgress) attempt(s) without progress at \(Self.seconds(time)) — giving up")
            abandonedTime = time
            cancel()
            return false
        }
        attemptsWithoutProgress += 1
        recoveryCount += 1
        let fraction = wasRecovering ? (pendingStartFraction ?? resumeFraction) : resumeFraction
        // A rebuilt item that failed again: still the user's target, if it
        // was. A new recovery: the user's held seek target, when it is one.
        let userTarget = wasRecovering ? (resumeTimeIsUserTarget && time == resumeTime)
                                       : (positionIsUserTarget && time == position)
        begin(player: player, time: time, startFraction: fraction, captureSelection: !wasRecovering,
              isDataReady: isDataReady, reason: failure.reason, userTarget: userTarget, waitsForPlay: waitsForPlay)
        return true
    }

    /// Stops waiting / rebuilding (idempotent): the owner tears down or
    /// falls back.
    func cancel() {
        generation += 1
        snapshotGeneration += 1
        snapshotPending = false
        statusObservation?.invalidate()
        statusObservation = nil
        rateObserver = nil
        let wasRecovering = isRecovering
        isRecovering = false
        isSeeking = false
        replacement = nil
        resumeTime = nil
        resumeTimeIsUserTarget = false
        isRebuildingStuckItem = false
        isWaitingForPlay = false
        isSettlingPlayPress = false
        isSettlingPause = false
        pendingStartFraction = nil
        isDataReady = nil
        observedPlayerTime = nil
        if wasRecovering { onWaitingChanged?(false) }
    }

    /// Rebuilds the item NOW at `time` (player timeline, s) — the remux
    /// owners' safety net for an item stuck on complete data
    /// (`StuckPlaybackWatch`): every byte is local, so nothing is waited for
    /// but the audio / subtitle selection of the stuck item (captured as for
    /// starvation, at most ~3 s). Then the starvation rebuild path: a new
    /// item PRE-POSITIONED at `time` before it is attached (the player
    /// paused), `onItemReplaced`, the selection re-applied, the precise seek
    /// once ready, `onResumed`; not ready and positioned within
    /// `rebuildReadyTimeout` → `onGiveUp` (VLC at `time`). The same hooks run
    /// as for starvation and `isRecovering` stays true until the resume
    /// (`isRebuildingStuckItem` tells them apart) — but no play / pause is
    /// observed (`onUserPlaybackChanged`): it waits for nothing; the
    /// starvation attempt budget and `recoveryCount` are untouched. Returns
    /// false — nothing done — while a recovery runs, without a current item,
    /// or for a time that isn't finite and ≥ 0.
    /// Also the owners' one-time replacement of an item AVPlayer started on
    /// live EVENT playlists once the remux has finished (`LiveBornItemWatch`):
    /// `resumesPlayback` false (the user had paused) ends the rebuild paused,
    /// without `onResumed`; `exactPosition` makes the precise seek land on
    /// `time` itself (no replay of up to 2 s of a picture that was playing
    /// fine).
    @discardableResult
    func rebuildNow(player: AVPlayer, at time: Double, reason: String, resumesPlayback: Bool = true,
                    exactPosition: Bool = false) -> Bool {
        guard !isRecovering, player.currentItem != nil, time.isFinite, time >= 0 else { return false }
        begin(player: player, time: time, startFraction: nil, captureSelection: true,
              isDataReady: { _, _ in true }, reason: reason, stuckItem: true, resumesPlayback: resumesPlayback,
              exactPosition: exactPosition)
        return true
    }

    // MARK: - Steps

    private func begin(player: AVPlayer, time: Double, startFraction: Float?, captureSelection: Bool,
                       isDataReady: @escaping (Double, TimeInterval) -> Bool, reason: String,
                       stuckItem: Bool = false, userTarget: Bool = false, resumesPlayback: Bool = true,
                       exactPosition: Bool = false, waitsForPlay: Bool = false) {
        generation += 1
        let current = generation
        statusObservation?.invalidate()
        statusObservation = nil
        rateObserver = nil
        replacement = nil
        selectionApplied = false
        isSeeking = false
        self.player = player
        self.isDataReady = isDataReady
        isRecovering = true
        isRebuildingStuckItem = stuckItem
        isWaitingForPlay = waitsForPlay
        isSettlingPlayPress = false
        isSettlingPause = false
        rebuildResumesPlayback = resumesPlayback && !waitsForPlay
        rebuildSeeksExactly = exactPosition
        resumeTime = time
        resumeTimeIsUserTarget = userTarget
        abandonedTime = nil
        pendingStartFraction = startFraction.flatMap { $0.isFinite && $0 > 0 && $0 < 1 ? $0 : nil }
        failureDate = Date()
        loggedWaitSteps = 0
        stallWatch = RemuxStallWatch(cap: stallCapSeconds)
        farTargetWatch = FarTargetWatch(downloadHistory: farTargetHistory?() ?? [])
        // Paused: the next item must not start at 0 before the seek.
        player.pause()
        observedPlayerTime = player.currentTime().seconds
        observedPlaying = player.rate != 0
        if captureSelection, let item = player.currentItem {
            // What the user listens to / reads, re-applied to the new item.
            snapshot = nil
            snapshotPending = true
            snapshotGeneration += 1
            let capture = snapshotGeneration
            Task { @MainActor [weak self] in
                let captured = await MediaSelectionSnapshot.capture(from: item)
                guard let self = self, capture == self.snapshotGeneration else { return }
                self.snapshot = captured
                self.snapshotPending = false
                // A stuck item waits for nothing else: rebuild now, not at
                // the next 1 Hz poll (this poll rebuilds or gives up — it
                // schedules no second chain).
                if self.isRebuildingStuckItem { self.poll(current) }
            }
        }
        if stuckItem {
            print("[Player] native item stuck at \(Self.seconds(time)) on complete data (\(reason)) — rebuilding it there")
        } else {
            let pending = pendingStartFraction.map { ", pending resume at \(Int(($0 * 100).rounded())) %" } ?? ""
            let target = userTarget ? ", the user's seek target" : ""
            print("[Player] download starvation at \(Self.seconds(time))\(pending)\(target) (\(reason)) — keeping the native player, "
                  + (waitsForPlay ? "paused by the user: rebuilding once play is pressed" : "waiting for data")
                  + " (attempt \(attemptsWithoutProgress)/\(maxAttemptsWithoutProgress))")
            // The user's play / pause on the dead item, in both modes: a
            // TRANSITION from the state seen last — first the one the pause
            // above left, so that pause is never taken for theirs — with a
            // user reason. AVPlayer's own stop right after a failure carries
            // none; AVKit's scrub posts `setRate:0` notes on a player already
            // at 0. The rate and the playhead are read here, on the posting
            // thread: each note carries the state it left, in order — a play
            // and a pause delivered within one main-queue turn stay two
            // transitions, and a seek right after a pause is not read as
            // where it paused.
            let box = WeakBox(self)
            rateObserver = ObserverToken(NotificationCenter.default.addObserver(
                forName: AVPlayer.rateDidChangeNotification, object: player, queue: nil) { note in
                let reason = note.userInfo?[AVPlayer.rateDidChangeReasonKey] as? AVPlayer.RateDidChangeReason
                let byUser = reason != nil && reason != .setRateFailed
                let noted = note.object as? AVPlayer
                let playing = (noted?.rate ?? 0) != 0
                let playhead = noted?.currentTime().seconds
                DispatchQueue.main.async {
                    box.value?.userPlaybackChanged(current, playing: playing, playhead: playhead, byUser: byUser)
                }
            })
        }
        if !waitsForPlay { onWaitingChanged?(true) }
        poll(current)
    }

    /// One rate note of the dead item: `playing` and `playhead`, the state it
    /// left (read when it was posted); `byUser`, a user reason. Only a
    /// TRANSITION — a state other than the one seen last (`observedPlaying`,
    /// updated by every note) — with a user reason is the user's play /
    /// pause: AVKit's scrub on a player already at 0 (`setRate:0` before and
    /// after it) is none. Waiting for data: a play press changes nothing —
    /// playback resumes by itself once the data is there —, a pause settles
    /// first (`pauseSettled`: compared with `playhead`), then switches to
    /// waiting for play (indicator off, no rebuild until play). Waiting for
    /// play: a play press starts the wait for
    /// data (indicator, clock, stall cap, the far-target pace), and once the
    /// press settled (`playPressSettleSeconds`) the rebuild and `onResumed`
    /// follow — or the user pauses again before the rebuild: back to waiting
    /// for play. The playhead is followed first, at the press and again once
    /// it settled: a seek the user made on the dead item just before pressing
    /// play (within the 1 Hz poll period, or shown late by `currentTime()`) is
    /// where playback resumes (`onRetarget`), or where the recovery gives up
    /// when it can never be played natively again. The owner's play intent
    /// follows (`onUserPlaybackChanged`).
    private func userPlaybackChanged(_ current: Int, playing: Bool, playhead: Double?, byUser: Bool) {
        guard isRecovering, current == generation, replacement == nil else { return }
        let changed = playing != observedPlaying
        observedPlaying = playing
        guard byUser, changed, playing == isWaitingForPlay else { return }
        // Only the latest press settles.
        playPressCount += 1
        let press = playPressCount
        if !playing {
            isSettlingPlayPress = false
            isSettlingPause = true
            DispatchQueue.main.asyncAfter(deadline: .now() + pauseSettleSeconds) { [weak self] in
                self?.pauseSettled(current, press: press, playhead: playhead)
            }
            return
        }
        isWaitingForPlay = false
        rebuildResumesPlayback = true
        isSettlingPlayPress = true
        onUserPlaybackChanged?(true)
        failureDate = Date()
        loggedWaitSteps = 0
        stallWatch = RemuxStallWatch(cap: stallCapSeconds)
        farTargetWatch = FarTargetWatch(downloadHistory: farTargetHistory?() ?? [])
        if followUserSeek() { return }
        print("[Player] starvation recovery: play pressed — resuming at \(Self.seconds(resumeTime ?? .nan))")
        onWaitingChanged?(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + playPressSettleSeconds) { [weak self] in
            self?.playPressSettled(current, press: press)
        }
    }

    /// The latest pause while waiting for data settled (`pauseSettleSeconds`;
    /// the poll only followed the playhead meanwhile). The dead item's
    /// playhead jumped since (`playhead`, read at the pause): AVKit's scrub,
    /// which paused it before its seek and restores the rate only once that
    /// seek completes (never, on a failed item) — the wait for data goes on.
    /// Played again since: nothing. Else the user's pause: wait for play.
    private func pauseSettled(_ current: Int, press: Int, playhead: Double?) {
        guard isRecovering, current == generation, press == playPressCount, replacement == nil, isSettlingPause else { return }
        isSettlingPause = false
        guard !observedPlaying, let now = player?.currentTime().seconds else { return }
        if StarvationPolicy.userSeekTarget(observed: now, lastObserved: playhead) != nil {
            print("[Player] starvation recovery: the dead item was paused then moved to \(Self.seconds(now)) — "
                  + "a scrub (AVKit pauses it before seeking), not a pause: still waiting for data")
            return
        }
        isWaitingForPlay = true
        rebuildResumesPlayback = false
        onUserPlaybackChanged?(false)
        print("[Player] starvation recovery: paused by the user — rebuilding once play is pressed")
        onWaitingChanged?(false)
    }

    /// The latest play press settled with the user still wanting playback:
    /// a seek that showed late is followed, then the checks of the wait run
    /// — the rebuild now when the data is there, else the 1 Hz poll goes on.
    private func playPressSettled(_ current: Int, press: Int) {
        guard isRecovering, current == generation, press == playPressCount, replacement == nil,
              !isWaitingForPlay else { return }
        isSettlingPlayPress = false
        if followUserSeek() { return }
        _ = proceed(current)
    }

    private func poll(_ current: Int) {
        guard isRecovering, current == generation, replacement == nil else { return }
        if followUserSeek() { return }
        guard resumeTime != nil else { return }
        // A paused user: nothing but the playhead is followed until play,
        // and until a play press or a pause settled (`playPressSettled` acts
        // then; `pauseSettled` decides whether it was a pause).
        if !isWaitingForPlay, !isSettlingPlayPress, !isSettlingPause, proceed(current) { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.poll(current)
        }
    }

    /// The user moved the playhead of the dead item since the last look (the
    /// previous poll or play press, else the recovery's start): it never
    /// plays nor requests anything again, so its time only moves when the
    /// user moves it (`StarvationPolicy.userSeekTarget`). Recover THAT
    /// position (`retarget(to:)`, `onRetarget`) — and give up there at once
    /// (`onGiveUp`, VLC at the target) when it can never be played natively
    /// again (`positionUnavailable`). True when the recovery gave up.
    private func followUserSeek() -> Bool {
        guard let observed = player?.currentTime().seconds else { return false }
        let userTarget = StarvationPolicy.userSeekTarget(observed: observed, lastObserved: observedPlayerTime)
        observedPlayerTime = observed
        guard let target = userTarget else { return false }
        retarget(to: target)
        guard positionUnavailable?(target) == true else { return false }
        giveUp(ResumePolicy.rewindPastBufferReason)
        return true
    }

    /// The checks of the wait for data: the data will never come (abandon),
    /// the stall cap, the data is there (→ rebuild), a user target the
    /// in-order download or the remux pump can't bring soon (`FarTargetWatch`
    /// → VLC there).
    /// True when the recovery rebuilt or gave up.
    private func proceed(_ current: Int) -> Bool {
        guard let time = resumeTime else { return false }
        let waited = Date().timeIntervalSince(failureDate)
        // The data will never come (remux halted…): no point waiting.
        if let reason = abandonReason?() {
            giveUp(reason)
            return true
        }
        // Downloading, but nothing new to remux at the playhead.
        let sample = stallProbe?()
        if let sample = sample,
           stallWatch.shouldGiveUp(frontierSeconds: sample.frontierSeconds, torrentProgress: sample.downloadProgress,
                                   waited: waited) {
            giveUp("Remux bloqué : le téléchargement progresse mais rien de nouveau à lire depuis \(Int(stallWatch.cap)) s")
            return true
        }
        // The selection capture is quick (groups already loaded): give it a
        // moment so a ready-at-once rebuild doesn't lose the user's choice.
        if !snapshotPending || waited > 3, isDataReady?(time, waited) == true {
            rebuild(current)
            return true
        }
        // The user's target, which the remux frontier reaches only at the
        // in-order download's pace: VLC there when that takes too long — its
        // byte-range reads make the torrent fetch it first. (A finished remux
        // has the data: the rebuild above.)
        if resumeTimeIsUserTarget, let sample = sample,
           farTargetWatch.shouldHandOff(target: time, frontierSeconds: sample.frontierSeconds,
                                        downloadProgress: sample.downloadProgress, remuxFinished: false,
                                        now: ProcessInfo.processInfo.systemUptime) {
            print("[Player] starvation recovery: the remux frontier (\(Self.seconds(sample.frontierSeconds))) would need "
                  + "~\(Int((farTargetWatch.estimatedSecondsToTarget ?? 0).rounded())) s to reach the user's target")
            giveUp(FarTargetWatch.reason)
            return true
        }
        let step = Int(waited / 15)
        if step > loggedWaitSteps {
            loggedWaitSteps = step
            print("[Player] starvation recovery: still waiting for data at \(Self.seconds(time)) after \(Int(waited)) s")
        }
        return false
    }

    /// A user seek to `time` while waiting: it is the new target. The wait
    /// (failure date, stall watch, far-target pace) and the attempt budget
    /// start over there — this recovery is the first attempt at `time`, the
    /// previous resume point is forgotten (it must not pull a nearby target
    /// back to the old stall point) — and a pending start fraction no longer
    /// applies. The owner hears of it at once (`onRetarget`).
    private func retarget(to time: Double) {
        print("[Player] starvation recovery: user seek to \(Self.seconds(time)) while waiting for data at "
              + "\(Self.seconds(resumeTime ?? .nan)) — recovering that position")
        resumeTime = time
        resumeTimeIsUserTarget = true
        pendingStartFraction = nil
        failureDate = Date()
        loggedWaitSteps = 0
        stallWatch = RemuxStallWatch(cap: stallCapSeconds)
        farTargetWatch = FarTargetWatch(downloadHistory: farTargetHistory?() ?? [])
        attemptsWithoutProgress = 1
        lastResumeTime = nil
        onRetarget?(time)
    }

    private func rebuild(_ current: Int) {
        guard let player = player, let item = makeItem?() else {
            giveUp("Reprise après famine impossible")
            return
        }
        // The pause below is the recovery's, not the user's.
        rateObserver = nil
        // Paused again: the user may have pressed play on the dead item
        // while waiting — the new one must not start before its selection is
        // restored and its precise seek is done (`onResumed` plays).
        player.pause()
        // Positioned BEFORE it is attached: the fresh item's first media
        // request is the resume segment. An unpositioned item starts at 0
        // and prefetches segments 1, 2…, which the remux may have pruned for
        // good (404, `onUnavailableSegmentRequested` → VLC; review probes
        // rb / rb2: never ready vs ready in 0.2 s). The completion handler
        // must be nil: a seek with one raises on an item that isn't ready
        // yet. The precise seek follows once it is ready.
        if let time = resumeTime, time.isFinite, time > 0 {
            item.seek(to: CMTime(seconds: time, preferredTimescale: 600), completionHandler: nil)
        }
        replacement = item
        selectionApplied = false
        player.replaceCurrentItem(with: item)
        let snapshot = self.snapshot
        onItemReplaced?(item, snapshot != nil)
        if let snapshot = snapshot {
            Task { @MainActor [weak self] in
                let applied = await snapshot.apply(to: item)
                guard let self = self, current == self.generation else { return }
                print("[Player] starvation recovery: selection restored — \(applied.joined(separator: ", "))")
                self.selectionApplied = true
                self.seekIfReady(current)
            }
        } else {
            selectionApplied = true
        }
        let box = WeakBox(self)
        statusObservation = item.observe(\.status, options: [.initial, .new]) { _, _ in
            DispatchQueue.main.async { box.value?.seekIfReady(current) }
        }
        // A selection load that never completes must not block the resume.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, current == self.generation, !self.selectionApplied else { return }
            self.selectionApplied = true
            self.seekIfReady(current)
        }
        // A short, fixed budget for the rebuilt item (no extensions): ready
        // and positioned in time, else VLC at the resume time.
        let budget = rebuildReadyTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + budget) { [weak self] in
            guard let self = self, self.isRecovering, current == self.generation, self.replacement === item else { return }
            let what = self.isRebuildingStuckItem ? "Reprise de l'élément bloqué" : "Reprise après famine"
            self.giveUp("\(what) : nouvel élément toujours pas prêt après \(Int(budget.rounded())) s")
        }
    }

    private func seekIfReady(_ current: Int) {
        guard isRecovering, current == generation, !isSeeking, selectionApplied,
              let player = player, let item = replacement, player.currentItem === item,
              item.status == .readyToPlay, var time = resumeTime else { return }
        if let fraction = pendingStartFraction {
            // Playback never started: the owner's resume point, now that the
            // duration is known (unknown — EVENT playlist — keeps `time`).
            let duration = item.duration.seconds
            if duration.isFinite, duration > 0 {
                time = Double(fraction) * duration
                resumeTime = time
            }
            pendingStartFraction = nil
        }
        isSeeking = true
        statusObservation?.invalidate()
        statusObservation = nil
        print("[Player] starvation recovery: new item ready — seeking to \(Self.seconds(time))")
        // Up to 2 s before (a keyframe), never after: nothing is skipped —
        // exactly there for a rebuild that asked for it (`exactPosition`).
        let box = WeakBox(self)
        let before = rebuildSeeksExactly ? CMTime.zero : CMTime(seconds: 2, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                    toleranceBefore: before,
                    toleranceAfter: .zero) { finished in
            DispatchQueue.main.async { box.value?.seekDidFinish(current, finished: finished) }
        }
    }

    private func seekDidFinish(_ current: Int, finished: Bool) {
        guard isRecovering, current == generation, let time = resumeTime else { return }
        let stuckItem = isRebuildingStuckItem
        isRecovering = false
        isSeeking = false
        replacement = nil
        resumeTime = nil
        resumeTimeIsUserTarget = false
        isRebuildingStuckItem = false
        isWaitingForPlay = false
        pendingStartFraction = nil
        isDataReady = nil
        abandonedTime = nil
        lastResumeTime = time
        let resumes = rebuildResumesPlayback
        rebuildResumesPlayback = true
        rebuildSeeksExactly = false
        print("[Player] \(stuckItem ? "stuck item rebuilt" : "starvation recovery #\(recoveryCount)"): "
              + "native playback \(resumes ? "resumes" : "stays paused") at \(Self.seconds(time))"
              + (finished ? "" : " (seek interrupted)"))
        onWaitingChanged?(false)
        if resumes { onResumed?(time) }
    }

    /// Ends the recovery without resuming (→ the owner's VLC fallback).
    /// `onGiveUp` runs while `resumeTime` still holds the position being
    /// recovered; `abandonedTime` keeps it afterwards.
    private func giveUp(_ reason: String) {
        guard isRecovering else { return }
        abandonedTime = resumeTime
        print("[Player] starvation recovery: \(reason) — giving up at \(Self.seconds(resumeTime ?? .nan))")
        let callback = onGiveUp
        callback?(reason)
        cancel()
    }

    private static func seconds(_ value: Double) -> String {
        value.isFinite ? String(format: "%.1f s", value) : "? s"
    }

    /// Weak reference handed to KVO / notification blocks (any thread),
    /// dereferenced on main only.
    private final class WeakBox: @unchecked Sendable {
        weak var value: PlaybackStarvationRecovery?
        init(_ value: PlaybackStarvationRecovery) { self.value = value }
    }

    /// A notification-center block observer, removed when released.
    private final class ObserverToken {
        private let token: NSObjectProtocol
        init(_ token: NSObjectProtocol) { self.token = token }
        deinit { NotificationCenter.default.removeObserver(token) }
    }
}
