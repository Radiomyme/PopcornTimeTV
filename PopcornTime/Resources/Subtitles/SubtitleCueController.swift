

import Foundation
import AVFoundation
import Combine
import PopcornKit

// CONTRACT FILE — owned by agent C2. Shared by the tvOS, iOS and macOS apps.
//
// External (OpenSubtitles) subtitles for the AVPlayer paths that play a
// progressive MP4/MOV directly (no HLS → OpenSubtitles can't become native
// renditions): downloads + parses the file (SubtitleConversion) and
// publishes the text of the cue active at the player's current time, for an
// overlay to draw.
//
// The file may carry subtitle tracks of its own (tx3g / WebVTT in an MP4),
// which AVPlayer renders itself. The two never show at once: `attach(to:)`
// binds the player's item, and from then on
//  - the preferred subtitle language is served by the file's own matching
//    (playable, non-forced) track when there is one — selected natively, in
//    sync with this very release — and the overlay stays off; otherwise the
//    matching OpenSubtitles entry is drawn; failing that, the machine
//    translation into that language AVFoundation offers on OS 27 ("German
//    (Germany) Translated", made from the file's English track) is selected
//    natively — once the OpenSubtitles search has answered without one, or
//    the one it listed can't be shown (see below);
//  - whenever the overlay shows a subtitle (auto or picked from our menu),
//    the item's own subtitle option is deselected;
//  - when the user turns one of the item's own subtitles on (AVKit's menu),
//    the overlay turns off;
//  - « Désactivés » (`select(nil)`) turns both off: the overlay and the
//    item's own non-forced subtitle. The item's forced-only subtitles for
//    the language being heard (foreign dialogue, signs) stay on, as AVPlayer
//    shows them by itself. `isNativeSubtitleShown` publishes whether one of
//    the item's own non-forced subtitles is on, so the menus only show
//    « Désactivés » / the unfilled icon when none is (`areSubtitlesOff`);
//  - an overlay subtitle the user picked that can't be shown (download
//    error, HTTP error status, empty or unparsable file) leaves
//    « Désactivés » in effect, as the menus then show it: the item's
//    forced-only subtitles come back. One picked automatically for the
//    preferred language gives way to the next choice instead (another
//    OpenSubtitles entry in that language, else the machine translation;
//    « Désactivés » when there is none). It is never downloaded again for a
//    rebuilt item, only when `autoSelectPreferred()` is called again with
//    nothing else left.
// The item's legible selection is then left to this controller alone
// (`PlaybackLanguagePreferences.applyPreferredMediaSelection` skips it).
//
// Frame-based OpenSubtitles files (MicroDVD) that don't declare their frame
// rate are timed with the bound item's own video frame rate, before
// OpenSubtitles' MovieFPS (which describes the release the file was made for).

@MainActor
final class SubtitleCueController: ObservableObject {

    /// OpenSubtitles candidates, best per language.
    @Published private(set) var available: [Subtitle] = []
    /// Currently selected subtitle, nil = off.
    @Published private(set) var selected: Subtitle?
    /// Plain text of the active cue(s) (tags stripped, "\n" kept), nil = none.
    @Published private(set) var currentText: String?
    /// User sync offset in seconds (positive = show later).
    @Published var offset: Double = 0 {
        didSet { if offset != oldValue { refreshText() } }
    }
    /// True while the OpenSubtitles search runs (menus can say so).
    @Published private(set) var isSearching = false
    /// True while the selected subtitle downloads / parses.
    @Published private(set) var isLoadingSelection = false
    /// True while AVPlayer shows one of the bound item's OWN subtitles (a
    /// non-forced option of its legible group: the one selected for the
    /// preferred language — the file's track, or its machine translation —
    /// or one turned on in AVKit's menu).
    @Published private(set) var isNativeSubtitleShown = false

    /// No subtitle on: neither the overlay nor one of the item's own
    /// non-forced subtitles (its forced-only ones may still show). What the
    /// menus' « Désactivés » checkmark and unfilled icon stand for.
    var areSubtitlesOff: Bool { selected == nil && !isNativeSubtitleShown }

    /// Parsed cues of `selected`, sorted by start time.
    private var cues: [PreparedCue] = []
    /// Longest cue duration — bounds the backward scan of `activeText(at:)`.
    private var maxCueDuration: Double = 0
    /// Parsed cues per subtitle link (switching back is instant).
    private var cueCache: [String: [PreparedCue]] = [:]
    private var observation: PlayerTimeObservation?
    private var lastPlayerTime: Double?
    /// Bumped on every selection so a slow download can't overwrite a newer choice.
    private var selectionGeneration = 0
    /// `autoSelectPreferred()` was called before it could decide: the search
    /// hadn't returned, or the item's own subtitles weren't known yet.
    private var wantsPreferredSelection = false
    /// `available` is final: given at init, or the OpenSubtitles search
    /// answered (possibly with nothing), or there is nothing to search. A
    /// machine translation (`nativeTranslationOption`) waits for it.
    private var availableIsFinal = false
    private var userHasChosen = false
    /// « Désactivés » holds: the user picked it, or an overlay subtitle
    /// couldn't be shown (`overlayDidFail(_:)`: the user's pick, or the
    /// automatic one with no other choice left for the preferred language)
    /// — the menus show « Désactivés » either way.
    /// None of the item's own (non-forced) subtitles either — also once its
    /// tracks are known, or on a rebuilt item — until the user turns one on
    /// in AVKit's menu or an overlay subtitle is applied, or, when only the
    /// automatic pick failed, until another choice for the preferred language
    /// turns up once the item's tracks are known (`nativeSubtitlesDidLoad()`).
    /// Only its forced-only subtitles for the language being heard stay on
    /// (`selectNativeSubtitlesOff()`).
    private var userWantsSubtitlesOff = false
    /// Links of the OpenSubtitles entries picked automatically (by
    /// `autoSelectPreferred()`) that couldn't be shown (`overlayDidFail(_:)`).
    /// The automatic choice passes over them while anything else is left for
    /// the preferred language (`applyPreferredChoice(code:)`); a rebuilt item,
    /// or tracks inspected after the failure, never download them again
    /// (`nativeSubtitlesDidLoad()`).
    private var failedAutomaticLinks = Set<String>()
    private let workingDirectory = ExternalSubtitleLoader.makeWorkingDirectory()

    // The attached item's own subtitles (see the file header).
    private weak var nativeItem: AVPlayerItem?
    private var nativeLegibleGroup: AVMediaSelectionGroup?
    /// The item's audio options: which forced subtitles « Désactivés » keeps
    /// depends on the language being heard.
    private var nativeAudibleGroup: AVMediaSelectionGroup?
    /// The item's playable, non-forced option in the preferred subtitle
    /// language — when set, AVPlayer shows it and the overlay stays off.
    /// Never a machine translation (see `nativeTranslationOption`).
    private var nativePreferredOption: AVMediaSelectionOption?
    /// No such option, but a machine translation into the preferred language
    /// (`PlaybackLanguagePreferences.isMachineGenerated`: OS 27's "German
    /// (Germany) Translated"): selected only when OpenSubtitles has nothing
    /// in that language that can be shown (`applyPreferredChoice(code:)`).
    private var nativeTranslationOption: AVMediaSelectionOption?
    private var nativeOptionNames: [AVMediaSelectionOption: String] = [:]
    /// The item's legible group was inspected (or there's no item at all).
    private var nativeSubtitlesKnown = false
    /// The item's option we selected for the preferred language —
    /// `nativePreferredOption` or `nativeTranslationOption` (re-asserted once
    /// ready).
    private var nativeAutoSelection: AVMediaSelectionOption?
    private var nativeInspectionGeneration = 0
    private var nativeSelectionSubscription: AnyCancellable?
    private var nativeStatusObservation: NSKeyValueObservation?
    /// Pending confirmation that a native subtitle turned on by someone else
    /// is a lasting (user) choice — see `nativeSelectionDidChange()`.
    private var nativeChangeCheck: DispatchWorkItem?
    /// Nominal frame rate of the bound item's video track (nil: none, or not
    /// plausible), loaded once per item. Times frame-based OpenSubtitles
    /// files (MicroDVD) that don't declare theirs — see `apply(_:)`.
    private var nativeFrameRateTask: Task<Double?, Never>?

    init(subtitles: [Subtitle] = []) {
        available = subtitles
        // A given list is final: `loadSubtitlesIfNeeded` searches only when
        // it is empty.
        availableIsFinal = !subtitles.isEmpty
    }

    deinit {
        // `observation` removes the AVPlayer time observer in its own deinit.
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    /// Fetch OpenSubtitles for `media` when `available` is empty (no media:
    /// there is nothing to search, the empty list is final).
    func loadSubtitlesIfNeeded(for media: Media?) {
        guard available.isEmpty, !isSearching else { return }
        guard let media else {
            setAvailable([])
            return
        }
        if !media.subtitles.isEmpty {
            setAvailable(media.subtitles)
            return
        }
        isSearching = true
        ExternalSubtitleLoader.search(for: media) { [weak self] subtitles in
            guard let self else { return }
            self.isSearching = false
            if self.available.isEmpty { self.setAvailable(subtitles) }
        }
    }

    /// Start tracking `player`'s time (≈10 Hz periodic observer), and bind
    /// its current item's own subtitles (see the file header) — so attach
    /// once the player has its item.
    func attach(to player: AVPlayer) {
        if let observation, observation.player === player { return }
        removeTimeObserver()
        let token = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            // Delivered on the main queue (see `queue:` above).
            MainActor.assumeIsolated {
                self?.playerTimeDidChange(time)
            }
        }
        observation = PlayerTimeObservation(player: player, token: token)
        bindNativeSubtitles(of: player.currentItem)
        playerTimeDidChange(player.currentTime())
    }

    /// Remove the time observer and unbind the item (idempotent).
    func detach() {
        removeTimeObserver()
        unbindNativeSubtitles()
    }

    /// Select a subtitle (download + parse), or nil to turn subtitles off:
    /// the overlay AND the item's own non-forced subtitle (e.g. the file's
    /// track this controller turned on for the preferred language). The
    /// item's forced-only subtitles for the language being heard stay on
    /// (`selectNativeSubtitlesOff()`). A subtitle that can't be shown ends
    /// in that « Désactivés » state too (`overlayDidFail(_:)`).
    func select(_ subtitle: Subtitle?) {
        userHasChosen = true
        wantsPreferredSelection = false
        userWantsSubtitlesOff = subtitle == nil
        apply(subtitle)
        if subtitle == nil { selectNativeSubtitlesOff() }
    }

    /// Select the subtitle matching the preferred subtitle language, if any:
    /// the file's own matching track wins (AVPlayer shows it, the overlay
    /// stays off), else the OpenSubtitles entry, else the item's machine
    /// translation into that language (OS 27, selected natively once the
    /// search has answered without an entry). An entry picked here before
    /// that couldn't be shown (`overlayDidFail(_:)`) comes last: tried again
    /// only when nothing else is left (the failure may have been transient).
    /// Waits — and decides later by itself — while the item's tracks or the
    /// search results are unknown.
    func autoSelectPreferred() {
        guard !userHasChosen, selected == nil,
              let code = PlaybackLanguagePreferences.preferredSubtitleLanguageCode else { return }
        guard nativeSubtitlesKnown else {
            wantsPreferredSelection = true   // decided once the item is attached and inspected
            return
        }
        if nativePreferredOption != nil || nativeAutoSelection != nil {
            // The file's own track (selected when inspected), or its machine
            // translation selected already.
            wantsPreferredSelection = false
            return
        }
        if applyPreferredChoice(code: code) {
            wantsPreferredSelection = false
        } else if let retry = ExternalSubtitleLoader.preferredSubtitle(in: available, code: code) {
            // Only entries that couldn't be shown are left, and no machine
            // translation: one more try.
            wantsPreferredSelection = false
            apply(retry)
        } else {
            // Nothing yet: retry once the OpenSubtitles search returns.
            wantsPreferredSelection = available.isEmpty
        }
    }

    /// Applies the best choice left for the preferred language `code`: the
    /// file's own track, else an OpenSubtitles entry whose automatic pick
    /// hasn't failed (`failedAutomaticLinks`), else — once the list is final
    /// — the item's machine translation (`nativeTranslationOption`). False
    /// when none is left. The item's tracks must be known.
    private func applyPreferredChoice(code: String) -> Bool {
        if let option = nativePreferredOption {
            selectNativeAutomatically(option)
            return true
        }
        let candidates = available.filter { !failedAutomaticLinks.contains($0.link) }
        if let match = ExternalSubtitleLoader.preferredSubtitle(in: candidates, code: code) {
            apply(match)
            return true
        }
        if availableIsFinal, let translation = nativeTranslationOption {
            // OpenSubtitles has nothing in that language that can be shown:
            // a machine translation beats no subtitle at all.
            print("[Subtitles] no OpenSubtitles '\(code)' subtitle to show: AVFoundation's machine translation instead")
            selectNativeAutomatically(translation)
            return true
        }
        return false
    }

    /// Selects the item's `option` as our choice for the preferred language
    /// (re-asserted once the item is ready): « Désactivés » no longer holds.
    private func selectNativeAutomatically(_ option: AVMediaSelectionOption) {
        userWantsSubtitlesOff = false
        nativeAutoSelection = option
        selectNativeSubtitles(option)
    }

    /// `autoSelectPreferred()` for an item that may not be attached yet:
    /// binds `item`'s own subtitles first (`attach(to:)` then keeps it).
    func autoSelectPreferred(for item: AVPlayerItem) {
        bindNativeSubtitles(of: item)
        autoSelectPreferred()
    }

    /// Ties the overlay to `item`'s own subtitle options (nil: the player has
    /// no item — nothing to coordinate with). `attach(to:)` calls it with the
    /// player's current item; rebinding the same item is a no-op.
    func bindNativeSubtitles(of item: AVPlayerItem?) {
        if let item, item === nativeItem { return }
        unbindNativeSubtitles()
        guard let item else {
            nativeSubtitlesKnown = true
            nativeSubtitlesDidLoad()
            return
        }
        nativeItem = item
        // From now on the item's legible selection is ours alone.
        PlaybackLanguagePreferences.setLegibleSelectionManagedExternally(for: item)
        nativeFrameRateTask = Task { [weak item] in
            guard let asset = item?.asset else { return nil }
            return await ExternalSubtitleLoader.videoFrameRate(of: asset)
        }
        nativeSelectionSubscription = NotificationCenter.default
            .publisher(for: AVPlayerItem.mediaSelectionDidChangeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.nativeSelectionDidChange() }
            }
        nativeStatusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard observed.status == .readyToPlay else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.nativeItemBecameReady() }
            }
        }
        nativeInspectionGeneration += 1
        let generation = nativeInspectionGeneration
        let code = PlaybackLanguagePreferences.preferredSubtitleLanguageCode
        Task { @MainActor [weak self, weak item] in
            guard let asset = item?.asset else { return }
            // Progressive files without subtitle tracks have no legible
            // group; a failed load counts as "none" too.
            let group = try? await asset.loadMediaSelectionGroup(for: .legible)
            var names: [AVMediaSelectionOption: String] = [:]
            var preferred: AVMediaSelectionOption?
            var audible: AVMediaSelectionGroup?
            if let group {
                names = await PlaybackLanguagePreferences.loadNames(of: group.options)
                if let code {
                    preferred = PlaybackLanguagePreferences.preferredLegibleOption(in: group, code: code, names: names)
                }
                // The language being heard picks the forced subtitles « Désactivés » keeps.
                audible = try? await asset.loadMediaSelectionGroup(for: .audible)
            }
            guard let self, let item, generation == self.nativeInspectionGeneration, item === self.nativeItem else { return }
            // The rule returns a machine translation only when the file has
            // no track of its own in that language: it waits for OpenSubtitles.
            let isTranslation = preferred.map(PlaybackLanguagePreferences.isMachineGenerated) ?? false
            self.nativeLegibleGroup = group
            self.nativeAudibleGroup = audible
            self.nativeOptionNames = names
            self.nativePreferredOption = isTranslation ? nil : preferred
            self.nativeTranslationOption = isTranslation ? preferred : nil
            self.nativeSubtitlesKnown = true
            self.nativeSubtitlesDidLoad()
        }
    }

    // MARK: - Private

    private func removeTimeObserver() {
        observation?.invalidate()
        observation = nil
        lastPlayerTime = nil
        if currentText != nil { currentText = nil }
    }

    private func unbindNativeSubtitles() {
        nativeInspectionGeneration += 1
        nativeItem = nil
        nativeLegibleGroup = nil
        nativeAudibleGroup = nil
        nativePreferredOption = nil
        nativeTranslationOption = nil
        nativeOptionNames = [:]
        nativeSubtitlesKnown = false
        nativeAutoSelection = nil
        nativeSelectionSubscription = nil
        nativeStatusObservation?.invalidate()
        nativeStatusObservation = nil
        nativeChangeCheck?.cancel()
        nativeChangeCheck = nil
        nativeFrameRateTask = nil
        setNativeSubtitleShown(false)
    }

    /// The item's own subtitles are known: settle what was waiting for them.
    private func nativeSubtitlesDidLoad() {
        // AVPlayer's automatic selection may have turned one on meanwhile.
        refreshNativeSubtitleState()
        if selected != nil {
            // An OpenSubtitles file was picked before the item's tracks were known.
            deselectNativeSubtitles()
        } else if userWantsSubtitlesOff {
            // « Désactivés » took effect (picked, or a failed overlay) before
            // the item's tracks were known, or holds on a rebuilt item. When
            // it only stands for an automatic pick that couldn't be shown, the
            // best choice left replaces it (`applyPreferredChoice(code:)`:
            // typically this item's machine translation, for tracks inspected
            // after the failure or a rebuilt item) — never the failed entry.
            if !userHasChosen, let code = PlaybackLanguagePreferences.preferredSubtitleLanguageCode,
               applyPreferredChoice(code: code) {
                wantsPreferredSelection = false
            } else {
                selectNativeSubtitlesOff()
            }
        } else if !userHasChosen, let option = nativePreferredOption {
            // The file carries the preferred language: AVPlayer renders it (in
            // sync with this very release), the overlay stays off. Selected
            // here, not by applyPreferredMediaSelection (which leaves bound
            // items alone), so it also happens when OpenSubtitles has nothing.
            wantsPreferredSelection = false
            nativeAutoSelection = option
            selectNativeSubtitles(option)
        } else if wantsPreferredSelection || (!userHasChosen && nativeTranslationOption != nil) {
            // Waiting for the item's tracks — or all it has in the preferred
            // language is a machine translation: the OpenSubtitles entry first
            // (`autoSelectPreferred()` decides now, or once the search answers).
            wantsPreferredSelection = false
            autoSelectPreferred()
        }
    }

    /// AVPlayer applies its automatic (system-language) subtitle choice when
    /// the item becomes ready — seen to briefly override an explicit choice
    /// made before. Re-assert ours (no-op when it already holds).
    private func nativeItemBecameReady() {
        guard nativeSubtitlesKnown, let item = nativeItem, let group = nativeLegibleGroup else { return }
        refreshNativeSubtitleState()
        if selected != nil {
            deselectNativeSubtitles()
        } else if userWantsSubtitlesOff {
            if !nativeSubtitlesOffHolds() { selectNativeSubtitlesOff() }
        } else if !userHasChosen, let option = nativeAutoSelection,
                  item.currentMediaSelection.selectedMediaOption(in: group) != option {
            selectNativeSubtitles(option)
        }
    }

    /// The selected, non-forced option of the item's own subtitles, if any.
    private func selectedNativeSubtitle() -> AVMediaSelectionOption? {
        guard let item = nativeItem, let group = nativeLegibleGroup,
              let option = item.currentMediaSelection.selectedMediaOption(in: group),
              !isForcedOnly(option) else { return nil }
        return option
    }

    private func nativeName(of option: AVMediaSelectionOption) -> String {
        return nativeOptionNames[option] ?? option.displayName
    }

    private func isForcedOnly(_ option: AVMediaSelectionOption) -> Bool {
        return option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
            || PlaybackLanguagePreferences.isForcedSubtitle(nativeOptionNames[option])
    }

    /// Explicit selection: it also overrides AVPlayer's automatic
    /// (system-language) choice for good.
    private func selectNativeSubtitles(_ option: AVMediaSelectionOption) {
        guard let item = nativeItem, let group = nativeLegibleGroup else { return }
        item.select(option, in: group)
        setNativeSubtitleShown(!isForcedOnly(option))
        print("[Subtitles] the file's own '\(nativeName(of: option))' subtitles (\(option.extendedLanguageTag ?? "?")) are shown — overlay off")
    }

    /// The overlay shows a subtitle (or « Désactivés » with no forced
    /// subtitles to keep, see below): none of the item's own at the same
    /// time — the OpenSubtitles text replaces the file's forced lines too.
    /// Explicit even when nothing is selected yet, so AVPlayer's automatic
    /// selection can't turn one on later. (Unknown yet: done once inspected.)
    private func deselectNativeSubtitles(reason: String = "overlay on") {
        guard let item = nativeItem, let group = nativeLegibleGroup else { return }
        guard group.allowsEmptySelection else {
            print("[Subtitles] \(reason): the file's subtitle group can't be emptied")
            refreshNativeSubtitleState()
            return
        }
        let current = item.currentMediaSelection.selectedMediaOption(in: group)
        item.select(nil, in: group)
        setNativeSubtitleShown(false)
        if let current { print("[Subtitles] \(reason): the file's own '\(nativeName(of: current))' subtitles turned off") }
    }

    /// « Désactivés »: none of the item's own non-forced subtitles. Its
    /// forced-only subtitles for the language being heard (foreign dialogue,
    /// signs: what AVPlayer shows by itself when no subtitle is chosen) stay
    /// on — `forcedOptionForSubtitlesOff()` is selected, or nothing when
    /// there is none. Explicit even when it already looks selected, so
    /// AVPlayer's automatic selection can't change it later. (Unknown yet:
    /// done once inspected.)
    private func selectNativeSubtitlesOff() {
        guard let item = nativeItem, let group = nativeLegibleGroup else { return }
        guard let forced = forcedOptionForSubtitlesOff() else {
            deselectNativeSubtitles(reason: "subtitles off")
            return
        }
        let current = item.currentMediaSelection.selectedMediaOption(in: group)
        item.select(forced, in: group)
        setNativeSubtitleShown(false)
        if current != forced {
            print("[Subtitles] subtitles off: the file's own forced subtitles '\(nativeName(of: forced))' (\(forced.extendedLanguageTag ?? "?")) stay on")
        }
    }

    /// The item's forced-only option « Désactivés » keeps, for the audio it
    /// plays now (`PlaybackLanguagePreferences.forcedLegibleOption`); nil:
    /// none.
    private func forcedOptionForSubtitlesOff() -> AVMediaSelectionOption? {
        guard let item = nativeItem, let group = nativeLegibleGroup else { return nil }
        let selection = item.currentMediaSelection
        let audio = nativeAudibleGroup.flatMap { selection.selectedMediaOption(in: $0) }
        return PlaybackLanguagePreferences.forcedLegibleOption(in: group, audio: audio,
                                                               current: selection.selectedMediaOption(in: group),
                                                               names: nativeOptionNames)
    }

    /// The item's subtitle selection is what « Désactivés » selects (true
    /// while its tracks are unknown).
    private func nativeSubtitlesOffHolds() -> Bool {
        guard let item = nativeItem, let group = nativeLegibleGroup else { return true }
        return item.currentMediaSelection.selectedMediaOption(in: group) == forcedOptionForSubtitlesOff()
    }

    /// Publishes whether one of the item's own (non-forced) subtitles is on.
    private func refreshNativeSubtitleState() {
        setNativeSubtitleShown(selectedNativeSubtitle() != nil)
    }

    private func setNativeSubtitleShown(_ shown: Bool) {
        if isNativeSubtitleShown != shown { isNativeSubtitleShown = shown }
    }

    /// The item's media selection changed (subtitles or audio). Our own
    /// changes never select a non-forced subtitle while the overlay is on or
    /// after « Désactivés », so a (non-forced) option that is turned on now
    /// AND stays on is the user's pick in AVKit's menu: the latest choice
    /// wins — the overlay turns off, or « Désactivés » no longer holds.
    /// "Stays": AVPlayer's automatic pass at readyToPlay flips the selection
    /// for an instant (and posts this notification) before restoring the
    /// explicit one, so the decision is made a moment later, on a ready item.
    /// Short of that, while « Désactivés » holds, its forced subtitles follow
    /// the language being heard (the audio switched in AVKit's menu, or the
    /// preferred audio language was applied).
    private func nativeSelectionDidChange() {
        refreshNativeSubtitleState()
        if userWantsSubtitlesOff, selectedNativeSubtitle() == nil, !nativeSubtitlesOffHolds() {
            selectNativeSubtitlesOff()
        }
        guard selected != nil || userWantsSubtitlesOff, selectedNativeSubtitle() != nil else { return }
        nativeChangeCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.confirmNativeSelectionChange() }
        }
        nativeChangeCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: check)
    }

    private func confirmNativeSelectionChange() {
        nativeChangeCheck = nil
        refreshNativeSubtitleState()
        guard nativeItem?.status == .readyToPlay, let option = selectedNativeSubtitle() else { return }
        if selected != nil {
            print("[Subtitles] the file's own '\(nativeName(of: option))' subtitles were turned on — overlay off")
            userHasChosen = true
            wantsPreferredSelection = false
            apply(nil)
        } else if userWantsSubtitlesOff {
            print("[Subtitles] the file's own '\(nativeName(of: option))' subtitles were turned on")
            userWantsSubtitlesOff = false
        }
    }

    /// The final OpenSubtitles list (possibly empty).
    private func setAvailable(_ subtitles: [Subtitle]) {
        available = subtitles
        availableIsFinal = true
        if wantsPreferredSelection {
            wantsPreferredSelection = false
            autoSelectPreferred()
        }
    }

    private func apply(_ subtitle: Subtitle?) {
        guard let subtitle else {
            selectionGeneration += 1
            selected = nil
            isLoadingSelection = false
            setCues([])
            return
        }
        // The overlay shows a subtitle: « Désactivés » no longer holds.
        userWantsSubtitlesOff = false
        // One subtitle at a time: the item's own goes off while ours shows.
        deselectNativeSubtitles()
        // Already shown, or already on its way.
        if selected == subtitle, !cues.isEmpty || isLoadingSelection { return }
        selectionGeneration += 1
        let generation = selectionGeneration
        selected = subtitle
        if let cached = cueCache[subtitle.link] {
            isLoadingSelection = false
            setCues(cached)
            return
        }
        setCues([])
        isLoadingSelection = true
        let frameRateTask = nativeFrameRateTask
        Task { @MainActor [weak self] in
            // The bound item's video frame rate times MicroDVD files without
            // one of their own (known as soon as the item's tracks are, which
            // playback needs anyway; nil when no item is bound).
            let frameRate = await frameRateTask?.value
            guard let self, generation == self.selectionGeneration else { return }
            ExternalSubtitleLoader.loadCues(for: subtitle, into: self.workingDirectory,
                                            frameRate: frameRate) { [weak self] parsed in
                guard let self, generation == self.selectionGeneration else { return }
                self.isLoadingSelection = false
                // nil: download error or HTTP error status; []: empty or
                // unparsable file.
                guard let parsed, !parsed.isEmpty else {
                    print("[Subtitles] overlay: no usable cue in '\(subtitle.language)' (\(subtitle.format ?? "?"))")
                    self.overlayDidFail(subtitle)
                    return
                }
                let prepared = parsed.map(PreparedCue.init)
                self.cueCache[subtitle.link] = prepared
                self.setCues(prepared)
                print("[Subtitles] overlay: \(prepared.count) cues loaded for '\(subtitle.language)'")
            }
        }
    }

    /// The overlay subtitle `subtitle` can't be shown (download error, HTTP
    /// error status, empty or unparsable file). While it is still the
    /// selection:
    ///  - picked by `autoSelectPreferred()`: its link is remembered
    ///    (`failedAutomaticLinks`) and the best choice left for the preferred
    ///    language takes over (`applyPreferredChoice(code:)`: another
    ///    OpenSubtitles entry in that language, else the item's machine
    ///    translation); while the item's tracks are unknown (a rebuilt item
    ///    being inspected), « Désactivés » below until they are
    ///    (`nativeSubtitlesDidLoad()` then decides);
    ///  - picked by the user, or nothing left: back to « Désactivés », which
    ///    the menus then show. `apply(_:)` emptied the item's subtitle
    ///    selection explicitly, which also stops AVPlayer's automatic forced
    ///    pick; nothing replaces the file's forced lines any more, so its
    ///    forced-only subtitles for the language being heard are selected
    ///    again (`selectNativeSubtitlesOff()` — once its tracks are known,
    ///    and on a rebuilt item too).
    private func overlayDidFail(_ subtitle: Subtitle) {
        guard selected == subtitle else { return }
        selected = nil
        if !userHasChosen {
            failedAutomaticLinks.insert(subtitle.link)
            if nativeSubtitlesKnown, let code = PlaybackLanguagePreferences.preferredSubtitleLanguageCode,
               applyPreferredChoice(code: code) {
                return
            }
        }
        userWantsSubtitlesOff = true
        selectNativeSubtitlesOff()
    }

    private func setCues(_ newCues: [PreparedCue]) {
        cues = newCues
        maxCueDuration = newCues.map { $0.end - $0.start }.max() ?? 0
        refreshText()
    }

    private func playerTimeDidChange(_ time: CMTime) {
        guard time.isNumeric else { return }
        lastPlayerTime = time.seconds
        refreshText()
    }

    private func refreshText() {
        let text: String?
        if let time = lastPlayerTime, !cues.isEmpty {
            text = activeText(at: time - offset)
        } else {
            text = nil
        }
        if text != currentText { currentText = text }
    }

    /// Text of every cue active at `time` (overlapping cues joined by "\n").
    private func activeText(at time: Double) -> String? {
        // Binary search: first cue starting after `time`.
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        var texts: [String] = []
        var index = low - 1
        while index >= 0, cues[index].start >= time - maxCueDuration {
            let cue = cues[index]
            if cue.end > time, !cue.text.isEmpty, !texts.contains(cue.text) { texts.append(cue.text) }
            index -= 1
        }
        guard !texts.isEmpty else { return nil }
        return texts.reversed().joined(separator: "\n")
    }
}

/// A cue reduced to what the overlay draws.
private struct PreparedCue {
    let start: Double
    let end: Double
    let text: String

    init(_ cue: SubtitleCue) {
        start = cue.start
        end = cue.end
        text = SubtitleConversion.plainText(cue.text).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Owns an AVPlayer periodic time observer; removes it when invalidated or
/// released (so the controller's deinit needs no main-actor access).
private final class PlayerTimeObservation {
    private(set) weak var player: AVPlayer?
    private var token: Any?

    init(player: AVPlayer, token: Any) {
        self.player = player
        self.token = token
    }

    func invalidate() {
        if let token { player?.removeTimeObserver(token) }   // nonisolated AVPlayer API
        token = nil
    }

    deinit { invalidate() }
}

// MARK: - External subtitle loading (shared with the VLC players)

/// Download + decode + parse of OpenSubtitles files, shared by the AVPlayer
/// overlay (cues) and the VLC players (a clean UTF-8 SRT for
/// `addPlaybackSlave`, so code pages and MicroDVD / SubViewer / ASS files
/// render correctly there too).
enum ExternalSubtitleLoader {

    /// A fresh per-player scratch directory under tmp/PopcornSubtitles.
    static func makeWorkingDirectory() -> URL {
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("PopcornSubtitles", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// OpenSubtitles search for a movie (imdb id) or an episode (show imdb id
    /// + season/episode) — same queries as the tvOS flow. Completion on main.
    static func search(for media: Media, completion: @escaping ([Subtitle]) -> Void) {
        if let episode = media as? Episode {
            SubtitlesManager.shared.search(episode, imdbId: episode.show?.id) { subtitles, _ in
                completion(subtitles)
            }
        } else {
            SubtitlesManager.shared.search(imdbId: media.id) { subtitles, _ in
                completion(subtitles)
            }
        }
    }

    /// The subtitle to auto-select for `code`: exact ISO 639-1 match first,
    /// then any subtitle whose code / language name designates it.
    static func preferredSubtitle(in subtitles: [Subtitle], code: String) -> Subtitle? {
        return subtitles.first(where: { $0.ISO639.lowercased() == code })
            ?? subtitles.first(where: {
                PlaybackLanguagePreferences.matches($0.ISO639, code: code)
                    || PlaybackLanguagePreferences.matches($0.language, code: code)
            })
    }

    /// Format hint from OpenSubtitles' `SubFormat`. "sub" is ambiguous
    /// (MicroDVD or SubViewer) and txt/smi/mpl vary: content detection decides.
    static func formatHint(_ format: String?) -> SubtitleFormat? {
        switch format?.lowercased() {
        case "srt": return .srt
        case "vtt", "webvtt": return .webvtt
        case "ass", "ssa": return .ass
        default: return nil
        }
    }

    /// Decode (BOM / UTF-8 / SubEncoding / language code page) + parse.
    /// The hinted format is tried first, then content detection.
    /// `frameRate`: the PLAYING video's frame rate, for frame-based files
    /// (MicroDVD). Precedence: the file's own declaration ({1}{1}23.976, or a
    /// "movie info" line — applied by the parser), then `frameRate`, then
    /// OpenSubtitles' MovieFPS (`subtitle.frameRate`, the release the file
    /// was made for — possibly another one), then 23.976.
    static func cues(fromSubtitleData data: Data, subtitle: Subtitle, frameRate: Double? = nil) -> [SubtitleCue] {
        guard let text = SubtitleConversion.decodeText(data, encodingHint: subtitle.encoding,
                                                       languageHint: subtitle.ISO639) else { return [] }
        var attempts: [SubtitleFormat?] = []
        if let hint = formatHint(subtitle.format) { attempts.append(hint) }
        let detected = SubtitleConversion.detectFormat(text)
        if detected != .unknown, !attempts.contains(where: { $0 == detected }) { attempts.append(detected) }
        if subtitle.format?.lowercased() == "sub" {
            // OpenSubtitles ".sub" = MicroDVD or SubViewer: try both explicitly.
            for format in [SubtitleFormat.microDVD, .subViewer] where !attempts.contains(where: { $0 == format }) {
                attempts.append(format)
            }
        }
        attempts.append(nil)
        let videoFrameRate = usableVideoFrameRate(frameRate)
        let fps = videoFrameRate ?? subtitle.frameRate ?? 23.976
        if detected == .microDVD {
            let source = videoFrameRate != nil ? "the video's" : subtitle.frameRate != nil ? "OpenSubtitles MovieFPS" : "default"
            print("[Subtitles] MicroDVD '\(subtitle.language)': timed at \(String(format: "%.3f", fps)) fps (\(source)) unless the file declares its own")
        }
        for format in attempts {
            let parsed = SubtitleConversion.parse(text, format: format, frameRate: fps)
            if !parsed.isEmpty { return parsed.sorted { $0.start < $1.start } }
        }
        return []
    }

    /// `fps` when it can time frame-based subtitles: finite, 5…200 fps (the
    /// range the MicroDVD parser accepts for a file's own declaration).
    static func usableVideoFrameRate(_ fps: Double?) -> Double? {
        guard let fps, fps.isFinite, fps >= 5, fps <= 200 else { return nil }
        return fps
    }

    /// A VLCKit video track's frame rate (`VLCMedia.VideoTrack.frameRate` /
    /// `frameRateDenominator`); nil while VLC doesn't know it (0) or when it
    /// isn't plausible.
    static func videoFrameRate(numerator: UInt32, denominator: UInt32) -> Double? {
        guard numerator > 0, denominator > 0 else { return nil }
        return usableVideoFrameRate(Double(numerator) / Double(denominator))
    }

    /// Nominal frame rate of `asset`'s first video track (nil: no video
    /// track, not loadable, or not plausible).
    static func videoFrameRate(of asset: AVAsset) async -> Double? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let rate = try? await track.load(.nominalFrameRate) else { return nil }
        return usableVideoFrameRate(Double(rate))
    }

    /// True for a VLC text track that belongs to a playback SLAVE (an external
    /// subtitle file added with `addPlaybackSlave`): libvlc 4 prefixes the ES
    /// ids of a slave input with the MD5 of its URL
    /// ("5bb6f73ee4bffea25d6ff16bb7ac940d/spu/0"), while the file's own tracks
    /// are "spu/3" ("spu/auto/3"; closed captions "video/0/cc/spu/1").
    static func isVLCSlaveTrackId(_ trackId: String) -> Bool {
        let parts = trackId.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, let source = parts.first, source.count == 32 else { return false }
        return source.allSatisfy { $0.isHexDigit }
    }

    /// The text tracks of the playback slave added once `priorIds` were
    /// listed: among `trackIds` (VLC's order), the new tracks of a slave
    /// input (`isVLCSlaveTrackId`) — the one to select is the last; none
    /// while VLC hasn't registered it. Never a track of the file itself: one
    /// that registers late (closed captions found mid-stream, a subtitle
    /// stream declared later) is not the slave's, and must neither be
    /// selected in its place nor hidden from the file's own tracks.
    static func slaveTrackIds(_ trackIds: [String], addedAfter priorIds: Set<String>) -> [String] {
        return trackIds.filter { !priorIds.contains($0) && isVLCSlaveTrackId($0) }
    }

    /// Menu label: the language, flagged when the file is for the deaf and
    /// hard of hearing ("Français, malentendants").
    static func menuTitle(for subtitle: Subtitle) -> String {
        return subtitle.hearingImpaired ? "\(subtitle.language), malentendants" : subtitle.language
    }

    /// Downloads `subtitle` into `directory` (main-queue completion).
    static func download(_ subtitle: Subtitle, into directory: URL, completion: @escaping (URL?) -> Void) {
        func safe(_ value: String?, _ fallback: String) -> String {
            let cleaned = String((value ?? "").lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8))
            return cleaned.isEmpty ? fallback : cleaned
        }
        // Unique name: OpenSubtitles' suggested names collide across languages.
        let name = "\(safe(subtitle.ISO639, "sub"))-\(UUID().uuidString.prefix(8)).\(safe(subtitle.format, "srt"))"
        PopcornKit.downloadSubtitleFile(subtitle.link, fileName: name, downloadDirectory: directory) { url, error in
            if let error { print("[Subtitles] download failed (\(subtitle.language)): \(error.localizedDescription)") }
            completion(url)
        }
    }

    /// Download + parse off the main thread. `frameRate`: the playing
    /// video's frame rate (see `cues(fromSubtitleData:subtitle:frameRate:)`).
    /// Completion on main; nil when the download failed, [] when nothing
    /// could be parsed.
    static func loadCues(for subtitle: Subtitle, into directory: URL, frameRate: Double? = nil,
                         completion: @escaping ([SubtitleCue]?) -> Void) {
        download(subtitle, into: directory) { url in
            guard let url else { completion(nil); return }
            DispatchQueue.global(qos: .userInitiated).async {
                let data = try? Data(contentsOf: url)
                let parsed = data.map { cues(fromSubtitleData: $0, subtitle: subtitle, frameRate: frameRate) }
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async { completion(parsed) }
            }
        }
    }

    /// For VLC: download, then rewrite as UTF-8 SRT (BOM) so VLC never has to
    /// guess the code page or understand MicroDVD/SubViewer timing. Falls
    /// back to the raw file when parsing fails. `frameRate`: the playing
    /// video's frame rate (MicroDVD without its own), nil while unknown.
    /// Completion on main.
    /// The players download first (`download`) and convert once VLC plays
    /// (`convertForVLC`), when the video's frame rate is known.
    static func prepareVLCSubtitleFile(for subtitle: Subtitle, in directory: URL, frameRate: Double? = nil,
                                       completion: @escaping (URL?) -> Void) {
        download(subtitle, into: directory) { url in
            guard let url else { completion(nil); return }
            convertForVLC(fileAt: url, subtitle: subtitle, frameRate: frameRate) { completion($0) }
        }
    }

    /// Second half of `prepareVLCSubtitleFile`: rewrites the downloaded
    /// `file` as UTF-8 SRT (BOM) next to it, parsed off the main thread with
    /// `frameRate` (the playing video's, see `cues(fromSubtitleData:…)`).
    /// Completion on main with the SRT — or `file` itself when it can't be
    /// parsed (VLC then tries it as is). The raw file is kept, so it can be
    /// converted again.
    static func convertForVLC(fileAt file: URL, subtitle: Subtitle, frameRate: Double?,
                              completion: @escaping (URL) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var result = file
            if let data = try? Data(contentsOf: file) {
                let parsed = cues(fromSubtitleData: data, subtitle: subtitle, frameRate: frameRate)
                if !parsed.isEmpty {
                    let srtURL = file.deletingPathExtension().appendingPathExtension("utf8.srt")
                    let srt = "\u{FEFF}" + makeSRT(parsed)
                    if (try? srt.write(to: srtURL, atomically: true, encoding: .utf8)) != nil {
                        result = srtURL
                    }
                } else {
                    print("[Subtitles] VLC: could not parse '\(subtitle.language)', handing the raw file to VLC")
                }
            }
            let converted = result
            DispatchQueue.main.async { completion(converted) }
        }
    }

    /// Cues → SubRip. Payloads are WebVTT-escaped text with <i>/<b>/<u>:
    /// entities are unescaped (SRT has none), the tags are kept (VLC renders
    /// them) and a top position ("line:10%") becomes the {\an8} override.
    static func makeSRT(_ cues: [SubtitleCue]) -> String {
        var out = ""
        var index = 1
        for cue in cues.sorted(by: { $0.start < $1.start }) where cue.end > cue.start {
            var lines = cue.text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: "\n")
                // Tags first (escaped "&lt;" can't be mistaken for one), then entities.
                .map { unescapeEntities(keepingBasicTags($0)).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }   // a blank line would end the SRT cue
            guard !lines.isEmpty else { continue }
            if isTopPositioned(cue.settings) { lines[0] = "{\\an8}" + lines[0] }
            out += "\(index)\n\(srtTimestamp(cue.start)) --> \(srtTimestamp(cue.end))\n"
            out += lines.joined(separator: "\n") + "\n\n"
            index += 1
        }
        return out
    }

    private static func isTopPositioned(_ settings: String?) -> Bool {
        guard let settings,
              let range = settings.range(of: "line:") else { return false }
        let value = settings[range.upperBound...].prefix { $0.isNumber || $0 == "." || $0 == "-" }
        guard let number = Double(value) else { return false }
        if settings[range.upperBound...].dropFirst(value.count).first == "%" { return number < 50 }
        return number >= 0 && number < 5   // line numbers counted from the top
    }

    /// Removes every markup tag except <i>, <b>, <u> (and their closing
    /// forms) — e.g. WebVTT <c.class>, <v Speaker>, <ruby> — which VLC's SRT
    /// decoder would otherwise print literally.
    private static func keepingBasicTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "<", let close = text[index...].firstIndex(of: ">") {
                let tag = text[text.index(after: index)..<close].lowercased()
                if ["i", "/i", "b", "/b", "u", "/u"].contains(tag) { out += "<\(tag)>" }
                index = text.index(after: close)
            } else {
                out.append(text[index])
                index = text.index(after: index)
            }
        }
        return out
    }

    private static func unescapeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
            .replacingOccurrences(of: "&lrm;", with: "\u{200E}")
            .replacingOccurrences(of: "&rlm;", with: "\u{200F}")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func srtTimestamp(_ seconds: Double) -> String {
        let totalMs = max(0, Int((seconds * 1000).rounded()))
        let ms = totalMs % 1000
        let s = (totalMs / 1000) % 60
        let m = (totalMs / 60_000) % 60
        let h = totalMs / 3_600_000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
