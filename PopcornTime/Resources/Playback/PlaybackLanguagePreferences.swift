import Foundation
import AVFoundation

// CONTRACT FILE — owned by agent C2. Shared by the tvOS, iOS and macOS apps.
//
// Storage (same on the three apps' Settings screens):
//   "preferredAudioLanguage"    — localized language NAME ("Français") (codes
//                                  like "fr" must be accepted too).
//   "preferredSubtitleLanguage" — same convention.
//
// Language identification is deliberately tolerant: values come from the
// settings screens (localized names, possibly written under another UI
// language), Matroska / MP4 track languages (ISO 639-2 B or T codes, BCP 47
// tags), HLS renditions (BCP 47) and free-form track names written by
// release groups or VLC ("Track 1 - [French]", "VFF - Français", "English SDH").

enum PlaybackLanguagePreferences {

    /// UserDefaults keys (written by the Settings screens of the three apps).
    static let audioLanguageDefaultsKey = "preferredAudioLanguage"
    static let subtitleLanguageDefaultsKey = "preferredSubtitleLanguage"

    /// Common ISO 639-1 codes offered by the settings pickers (tvOS / iOS / macOS).
    static let pickerLanguageCodes: [String] = [
        "en", "fr", "de", "es", "it", "pt", "nl", "ru", "ja", "ko", "zh", "ar",
        "he", "tr", "pl", "cs", "sk", "hu", "ro", "bg", "el", "uk", "hr", "sr",
        "sl", "da", "fi", "no", "sv", "ca", "hi", "th", "vi", "id", "ms", "fa",
    ]

    /// ISO 639-1 code of the preferred audio language, nil = none.
    static var preferredAudioLanguageCode: String? {
        return storedCode(forKey: audioLanguageDefaultsKey)
    }

    /// ISO 639-1 code of the preferred subtitle language, nil = none.
    static var preferredSubtitleLanguageCode: String? {
        return storedCode(forKey: subtitleLanguageDefaultsKey)
    }

    /// ISO 639-1 code for a language name ("Français", "French") or code
    /// ("fr", "fre", "fra", "fr-FR"); nil when unknown.
    /// Languages without an ISO 639-1 code come back as their ISO 639-3 code
    /// ("fil", "yue") — still a valid BCP 47 primary tag.
    static func isoCode(for nameOrCode: String) -> String? {
        let trimmed = nameOrCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let code = code(fromTag: trimmed) { return code }
        let normalized = normalizedName(trimmed)
        if let code = nameIndex[normalized] ?? releaseAliases[normalized] { return code }
        // "Français (Canada)", "English [SDH]", "Portuguese - Brazil": retry on
        // the leading part only.
        if let cut = trimmed.firstIndex(where: { "([{-–—,/|".contains($0) }), cut > trimmed.startIndex {
            let head = String(trimmed[..<cut])
            if head.count < trimmed.count { return isoCode(for: head) }
        }
        return nil
    }

    /// True when a track language tag / name designates `code` (ISO 639-1).
    static func matches(_ trackLanguageOrName: String?, code: String) -> Bool {
        guard let raw = trackLanguageOrName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let target = isoCode(for: code) else { return false }
        // 1. The whole value is a code / tag / name ("fre", "fr-FR", "Français").
        if isoCode(for: raw) == target { return true }
        // 2. Bracketed parts, as VLC and release groups write them:
        //    "Track 1 - [French]", "Commentary (eng)".
        for part in enclosedParts(of: raw) where isoCode(for: part) == target {
            return true
        }
        // 3. Words: language names (current UI language, English, French,
        //    native), ISO 639-2 codes and release aliases ("VFF"). The bare
        //    2-letter code is NOT matched as a word ("it", "no", "en" inside
        //    titles would give false positives).
        let folded = normalizedName(raw)
        let words = folded.split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !words.isEmpty else { return false }
        let tokens = matchTokens(for: target)
        if words.contains(where: { tokens.words.contains($0) }) { return true }
        for phrase in tokens.phrases where containsPhrase(words, phrase) {
            return true
        }
        return false
    }

    /// Once the item's asset has loaded its media selection groups, select
    /// the audible option matching the preferred audio language and — when a
    /// preferred subtitle language is set — the matching legible option
    /// (unless the item's subtitles are managed by an overlay, see
    /// `setLegibleSelectionManagedExternally(for:)`).
    /// No-op for groups without a match. Safe to call right after creating the item.
    static func applyPreferredMediaSelection(to item: AVPlayerItem) {
        let audioCode = preferredAudioLanguageCode
        let subtitleCode = preferredSubtitleLanguageCode
        guard audioCode != nil || subtitleCode != nil else { return }
        Task { @MainActor [weak item] in
            guard let asset = item?.asset else { return }
            // Progressive files without alternate groups simply have no
            // group: `try?` + nil checks make this a no-op, never a crash.
            var audible: AVMediaSelectionGroup?
            var legible: AVMediaSelectionGroup?
            if audioCode != nil {
                audible = try? await asset.loadMediaSelectionGroup(for: .audible)
            }
            if subtitleCode != nil {
                legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            }
            guard let item else { return }
            if let code = audioCode, let group = audible {
                let names = await loadNames(of: group.options)
                if let option = preferredAudibleOption(in: group, code: code, names: names) {
                    select(option, in: group, item: item, kind: "audio", name: names[option])
                }
            }
            if let code = subtitleCode, let group = legible, !externallyManagedLegibleItems.contains(item) {
                let names = await loadNames(of: group.options)
                // The remux master's DEFAULT subtitle is the remuxer's own
                // pick for the preferred language (see preferredLegibleOption).
                if let option = preferredLegibleOption(in: group, code: code, names: names,
                                                       prefersGroupDefault: isHLS(asset)),
                   !externallyManagedLegibleItems.contains(item) {
                    select(option, in: group, item: item, kind: "subtitles", name: names[option])
                }
            }
        }
    }

    /// The remux path plays the HLS master RemuxPlayback serves
    /// (".../master.m3u8"); the direct path a progressive file.
    private static func isHLS(_ asset: AVAsset) -> Bool {
        guard let url = (asset as? AVURLAsset)?.url else { return false }
        return url.pathExtension.lowercased() == "m3u8"
    }

    /// Items whose subtitle (legible) selection belongs to an overlay — the
    /// `SubtitleCueController` of the direct MP4 paths, which draws
    /// OpenSubtitles over the video and makes the same preferred-language
    /// choice for the file's own tracks itself. It must be the only one
    /// deciding, so the file's subtitles and the overlay never show together
    /// and a pick from the overlay menu is never undone.
    @MainActor private static let externallyManagedLegibleItems = NSHashTable<AVPlayerItem>.weakObjects()

    /// `applyPreferredMediaSelection(to:)` then leaves `item`'s legible group alone.
    @MainActor static func setLegibleSelectionManagedExternally(for item: AVPlayerItem) {
        externallyManagedLegibleItems.add(item)
    }

    // MARK: - Settings helpers (tvOS / iOS / macOS pickers)

    /// Localized, capitalized language name ("Français") — the value the
    /// Settings screens of the three apps store.
    static func storedName(forCode code: String) -> String {
        return Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
    }

    /// Display name for a picker row (current UI language).
    static func displayName(forCode code: String) -> String {
        return storedName(forCode: code)
    }

    /// Picker codes sorted by their localized display name.
    static var sortedPickerLanguageCodes: [String] {
        return pickerLanguageCodes.sorted {
            displayName(forCode: $0).localizedStandardCompare(displayName(forCode: $1)) == .orderedAscending
        }
    }

    // MARK: - Track-name heuristics (shared by the VLC and AVPlayer paths)

    /// Commentary tracks ("Commentary", "Commentaire du réalisateur"…).
    static func isCommentary(_ name: String?) -> Bool {
        guard let name else { return false }
        let folded = normalizedName(name)
        return ["comment", "kommentar", "comentario", "commento"].contains { folded.contains($0) }
    }

    /// Audio description for the visually impaired.
    static func isAudioDescription(_ name: String?) -> Bool {
        guard let name else { return false }
        let folded = normalizedName(name)
        if folded.contains("audiodescri") || folded.contains("audio descri") || folded.contains("description audio") {
            return true
        }
        let words = Set(folded.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return words.contains("ad")
            || folded.contains("visually impaired") || folded.contains("malvoyant")
    }

    /// Forced-only subtitle tracks ("Forced", "Français (forcés)", "Forzados").
    static func isForcedSubtitle(_ name: String?) -> Bool {
        guard let name else { return false }
        let words = Set(normalizedName(name).split(whereSeparator: { !$0.isLetter }).map(String.init))
        return !words.isDisjoint(with: ["forced", "force", "forces", "forcee", "forcees", "forzados", "forzadas", "forzati", "erzwungen"])
    }

    /// Subtitles for the deaf / hard of hearing.
    static func isHearingImpaired(_ name: String?) -> Bool {
        guard let name else { return false }
        let folded = normalizedName(name)
        let words = Set(folded.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return !words.isDisjoint(with: ["sdh", "cc", "hi", "sme", "malentendants"])
            || folded.contains("hard of hearing") || folded.contains("closed caption")
    }

    // MARK: - AVFoundation selection

    /// Always an explicit selection, even when the option already looks
    /// selected: before the item is ready the "current" option is merely the
    /// DEFAULT rendition, and AVPlayer's automatic media selection (driven by
    /// the SYSTEM languages) would replace it later. An explicit
    /// `select(_:in:)` overrides the automatic criteria for good.
    @MainActor
    private static func select(_ option: AVMediaSelectionOption, in group: AVMediaSelectionGroup,
                               item: AVPlayerItem, kind: String, name: String?) {
        item.select(option, in: group)
        print("[Playback] preferred \(kind) → '\(name ?? option.displayName)' (\(option.extendedLanguageTag ?? "?"))")
    }

    /// The renditions' own names: HLS NAME / track title (title metadata).
    /// `displayName` is synthesized by AVFoundation from the language and
    /// characteristics ("French", "French SDH") and hides commentary tracks,
    /// so the heuristics below need the real name.
    static func loadNames(of options: [AVMediaSelectionOption]) async -> [AVMediaSelectionOption: String] {
        var names: [AVMediaSelectionOption: String] = [:]
        for option in options {
            let titles = AVMetadataItem.metadataItems(from: option.commonMetadata, filteredByIdentifier: .commonIdentifierTitle)
            for title in titles {
                if let value = try? await title.load(.stringValue), !value.isEmpty {
                    names[option] = value
                    break
                }
            }
        }
        return names
    }

    private static func optionMatches(_ option: AVMediaSelectionOption, code: String, name: String?) -> Bool {
        if let tag = option.extendedLanguageTag, matches(tag, code: code) { return true }
        if let language = option.locale?.language.languageCode?.identifier, matches(language, code: code) { return true }
        return matches(name, code: code) || matches(option.displayName, code: code)
    }

    /// Best audible option in the preferred language: playable, not a
    /// commentary / audio-description track; the rendition flagged DEFAULT
    /// wins (the remuxer marks the best-quality track of the preferred
    /// language), then quality hints, then group order.
    /// `names`: rendition names from `loadNames(of:)` (displayName otherwise).
    static func preferredAudibleOption(in group: AVMediaSelectionGroup, code: String,
                                       names: [AVMediaSelectionOption: String] = [:]) -> AVMediaSelectionOption? {
        let playable = AVMediaSelectionGroup.playableMediaSelectionOptions(from: group.options)
        let candidates = playable.filter { optionMatches($0, code: code, name: names[$0]) }
        guard !candidates.isEmpty else { return nil }
        func isSecondary(_ option: AVMediaSelectionOption) -> Bool {
            let name = names[option] ?? option.displayName
            return option.hasMediaCharacteristic(.describesVideoForAccessibility)
                || option.hasMediaCharacteristic(.isAuxiliaryContent) // commentary renditions
                || isCommentary(name) || isAudioDescription(name)
        }
        let main = candidates.filter { !isSecondary($0) }
        let pool = main.isEmpty ? candidates : main
        if let defaultOption = group.defaultOption, pool.contains(defaultOption) { return defaultOption }
        return pool.enumerated().max { lhs, rhs in
            let l = audioQualityHint(lhs.element, name: names[lhs.element])
            let r = audioQualityHint(rhs.element, name: names[rhs.element])
            return l != r ? l < r : lhs.offset > rhs.offset   // ties → earliest in group order
        }?.element
    }

    /// Best legible option in the preferred language: playable, never a
    /// forced-only track. Three kinds of candidates, in this order:
    ///  1. the file's own tracks — SDH included: written by people, in sync
    ///     with this very release;
    ///  2. the OpenSubtitles renditions RemuxPlayback adds to the remux master
    ///     (`isExternalSubtitleName`): an OpenSubtitles file (picked by
    ///     download count) may not be in sync;
    ///  3. machine translations (`isMachineGenerated`): on OS 27 AVFoundation
    ///     adds a "<Language> Translated" option per language to items with
    ///     an English subtitle track — the last resort.
    /// Within a kind, regular subtitles before SDH, in group order.
    /// - `prefersGroupDefault` (the remux path's HLS master): before that, the
    ///   rendition flagged DEFAULT wins when it is one of the candidates, as in
    ///   `preferredAudibleOption`. The remuxer flags the file's own best track
    ///   of the preferred language (non-forced, regular before SDH), and an
    ///   OpenSubtitles rendition only when it found none — so an OpenSubtitles
    ///   DEFAULT gives way when the file does have a matching track after all
    ///   (one the remuxer missed: language "und", the language in its name).
    ///   A machine translation never wins as the DEFAULT.
    /// Direct (progressive MP4) items pass `prefersGroupDefault: false` and
    /// have no OpenSubtitles option: the file's own track, else a machine
    /// translation — which `SubtitleCueController` shows only when the
    /// OpenSubtitles search has nothing in that language that can be shown.
    static func preferredLegibleOption(in group: AVMediaSelectionGroup, code: String,
                                       names: [AVMediaSelectionOption: String] = [:],
                                       prefersGroupDefault: Bool = false) -> AVMediaSelectionOption? {
        let playable = AVMediaSelectionGroup.playableMediaSelectionOptions(from: group.options)
        let candidates = playable.filter {
            optionMatches($0, code: code, name: names[$0])
                && !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
                && !isForcedSubtitle(names[$0])
        }
        guard !candidates.isEmpty else { return nil }
        func isExternal(_ option: AVMediaSelectionOption) -> Bool {
            return isExternalSubtitleName(names[option]) || isExternalSubtitleName(option.displayName)
        }
        let external = candidates.filter { isExternal($0) }
        let machine = candidates.filter { !isExternal($0) && isMachineGenerated($0) }
        let embedded = candidates.filter { !isExternal($0) && !isMachineGenerated($0) }
        if prefersGroupDefault, let defaultOption = group.defaultOption, candidates.contains(defaultOption),
           !machine.contains(defaultOption), embedded.isEmpty || !isExternal(defaultOption) {
            return defaultOption
        }
        func isSDH(_ option: AVMediaSelectionOption) -> Bool {
            return option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility)
                || option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility)
                || isHearingImpaired(names[option])
        }
        let pool = !embedded.isEmpty ? embedded : !external.isEmpty ? external : machine
        return pool.first(where: { !isSDH($0) }) ?? pool.first
    }

    /// A legible option made by a machine, not written by people. On OS 27
    /// AVFoundation adds such options by itself to items with an English
    /// subtitle track (an MP4 track or an HLS WebVTT rendition): its
    /// translation into each of some 20 languages ("German (Germany)
    /// Translated", tag "de-DE"; on HLS only into languages no rendition
    /// carries), which matches a preferred language like the file's own
    /// tracks do. Recognised by the official characteristic
    /// `AVMediaCharacteristic.machineGenerated` ("public.machine-generated",
    /// SDK 26: "distinguish machine generated content from human authored
    /// content"); those options also carry `.languageTranslation`, which a
    /// translation written by people may carry too. A content author may set
    /// it on a track as well. Always false before OS 26, which has neither
    /// the characteristic nor these options.
    static func isMachineGenerated(_ option: AVMediaSelectionOption) -> Bool {
        if #available(macOS 26.0, tvOS 26.0, *) {
            return option.hasMediaCharacteristic(.machineGenerated)
        }
        return false
    }

    /// The legible option that stays on when the user turns subtitles off
    /// (« Désactivés »): a forced-only one. Forced subtitles translate what the
    /// viewer isn't meant to understand (foreign dialogue, signs); AVPlayer
    /// shows them by itself when no subtitle is chosen.
    /// 1. a forced-only option in the language of `audio` (the item's selected
    ///    audible option): same language tag first, then same language;
    /// 2. else `current` (the group's selected option) when it is forced-only;
    /// 3. else the group's default option when it is forced-only;
    /// 4. else nil: no subtitle at all.
    /// Only playable options count. Options flagged forced-only
    /// (`containsOnlyForcedSubtitles`, what AVPlayer itself picks) rank before
    /// those only named so (`isForcedSubtitle`), then group order.
    /// `names`: rendition names from `loadNames(of:)`.
    static func forcedLegibleOption(in group: AVMediaSelectionGroup, audio: AVMediaSelectionOption?,
                                    current: AVMediaSelectionOption?,
                                    names: [AVMediaSelectionOption: String] = [:]) -> AVMediaSelectionOption? {
        let playable = AVMediaSelectionGroup.playableMediaSelectionOptions(from: group.options)
        let flagged = playable.filter { $0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
        let named = playable.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) && isForcedSubtitle(names[$0]) }
        let forced = flagged + named
        guard !forced.isEmpty else { return nil }
        if let audio {
            if let tag = audio.extendedLanguageTag?.lowercased(),
               let exact = forced.first(where: { $0.extendedLanguageTag?.lowercased() == tag }) {
                return exact
            }
            if let code = languageCode(of: audio), let sameLanguage = forced.first(where: { languageCode(of: $0) == code }) {
                return sameLanguage
            }
        }
        if let current, forced.contains(current) { return current }
        if let defaultOption = group.defaultOption, forced.contains(defaultOption) { return defaultOption }
        return nil
    }

    /// ISO 639-1 code (or 639-3) of an option's language: its extended
    /// language tag, else its locale; nil when undetermined ("und").
    private static func languageCode(of option: AVMediaSelectionOption) -> String? {
        if let tag = option.extendedLanguageTag, let code = isoCode(for: tag) { return code }
        if let language = option.locale?.language.languageCode?.identifier { return isoCode(for: language) }
        return nil
    }

    /// What RemuxPlayback appends to the NAME of the OpenSubtitles renditions
    /// it adds to the remux master ("Français (OpenSubtitles)"; a duplicate
    /// name gets a counter after it: "… (OpenSubtitles) (2)").
    static let externalSubtitleNameMarker = "(OpenSubtitles)"

    /// True for an OpenSubtitles rendition of the remux master, as opposed to
    /// one of the file's own subtitle tracks.
    static func isExternalSubtitleName(_ name: String?) -> Bool {
        guard let name else { return false }
        return name.range(of: externalSubtitleNameMarker, options: .caseInsensitive) != nil
    }

    /// Rough quality ordering from the rendition name / codec (only used to
    /// break ties between several renditions of the preferred language).
    private static func audioQualityHint(_ option: AVMediaSelectionOption, name: String?) -> Int {
        let name = normalizedName(name ?? option.displayName)
        var score = 0
        if name.contains("atmos") { score += 8 }
        if name.contains("7.1") { score += 4 } else if name.contains("5.1") { score += 3 }
        let subtypes = option.mediaSubTypes.map { $0.uint32Value }
        if subtypes.contains(0x6563_2D33) || name.contains("e-ac-3") || name.contains("eac3") { score += 2 }       // 'ec-3'
        else if subtypes.contains(0x6163_2D33) || name.contains("ac-3") || name.contains("ac3") { score += 1 }    // 'ac-3'
        if subtypes.contains(0x664C_6143) || subtypes.contains(0x616C_6163) || name.contains("flac") { score += 2 }  // 'fLaC', 'alac'
        return score
    }

    // MARK: - Code / name normalization

    private static func storedCode(forKey key: String) -> String? {
        guard let value = UserDefaults.standard.string(forKey: key) else { return nil }
        return isoCode(for: value)
    }

    /// Lowercased, diacritics folded, whitespace collapsed ("Français " → "francais").
    static func normalizedName(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// ISO 639-2/B → ISO 639-2/T (Foundation only knows the T codes).
    private static let bibliographicToTerminology: [String: String] = [
        "fre": "fra", "ger": "deu", "chi": "zho", "cze": "ces", "dut": "nld", "gre": "ell",
        "per": "fas", "rum": "ron", "slo": "slk", "ice": "isl", "mac": "mkd", "may": "msa",
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "geo": "kat", "tib": "bod",
        "wel": "cym", "mao": "mri", "scc": "srp", "scr": "hrv",
    ]

    /// Deprecated ISO 639-1 codes and OpenSubtitles' private codes.
    private static let legacyCodes: [String: String] = [
        "iw": "he", "in": "id", "ji": "yi", "jw": "jv", "mo": "ro",
        "pb": "pt", "pob": "pt",                 // OpenSubtitles: Portuguese (Brazil)
        "ze": "zh", "zhe": "zh", "zt": "zh", "zht": "zh", "zhs": "zh", "chs": "zh", "cht": "zh",
        "ea": "es", "spl": "es", "spn": "es",    // OpenSubtitles: Spanish (Latin America / Europe)
    ]

    /// Release-name conventions and common alternative names.
    private static let releaseAliases: [String: String] = [
        "vf": "fr", "vff": "fr", "vfq": "fr", "vfi": "fr", "vf2": "fr", "truefrench": "fr",
        "castellano": "es", "latino": "es", "espanol latino": "es",
        "brazilian": "pt", "brasileiro": "pt", "brazilian portuguese": "pt",
        "mandarin": "zh", "farsi": "fa", "flemish": "nl",
    ]

    /// 3-letter codes that are also everyday words — never matched as bare
    /// words inside a track name (still matched as a whole value / in brackets).
    private static let ambiguousWordCodes: Set<String> = [
        "may", "cat", "ice", "per", "fin", "est", "lit", "tel", "her", "sun", "nor",
        "dan", "pan", "con", "mal", "bis", "hat", "art", "son", "run", "lav",
    ]

    private static let undeterminedCodes: Set<String> = ["und", "mul", "zxx", "mis", "unk", "xxx"]

    /// "fr", "FRE", "fra", "fr-FR", "pt_BR", "zh-Hant-TW" → ISO 639-1 (or 639-3).
    private static func code(fromTag tag: String) -> String? {
        let lower = tag.lowercased()
        guard lower.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || $0 == "-" || $0 == "_" }) else { return nil }
        guard let primary = lower.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init),
              (2...3).contains(primary.count) else { return nil }
        if let alias = legacyCodes[primary] { return alias }
        if undeterminedCodes.contains(primary) { return nil }
        if primary.count == 3, primary >= "qaa", primary <= "qtz" { return nil } // private-use range
        let terminology = bibliographicToTerminology[primary] ?? primary
        let languageCode = Locale.LanguageCode(terminology)
        guard languageCode.isISOLanguage else { return nil }
        if let alpha2 = languageCode.identifier(.alpha2), alpha2.count == 2 { return alpha2 }
        return terminology
    }

    /// Normalized language name → code, built once (≈15 ms) from Foundation's
    /// ISO tables: every language in the current UI language, the user's
    /// first preferred languages, English and French (a name stored before
    /// the device language was changed still resolves); the picker languages
    /// in a few more UI languages; and each language's own name ("deutsch",
    /// "espanol", "русский").
    private static let nameIndex: [String: String] = {
        var index: [String: String] = [:]
        func add(_ name: String?, _ code: String) {
            guard let name else { return }
            let key = normalizedName(name)
            if !key.isEmpty, index[key] == nil { index[key] = code }
        }
        let all = Locale.LanguageCode.isoLanguageCodes.map(\.identifier)
        let twoLetter = all.filter { $0.count == 2 }
        // Priority order resolves rare name collisions in favour of common languages.
        let ordered = pickerLanguageCodes
            + twoLetter.filter { !pickerLanguageCodes.contains($0) }
            + all.filter { $0.count == 3 }
        var identifiers = [Locale.current.identifier] + Locale.preferredLanguages.prefix(3) + ["en", "fr"]
        identifiers = identifiers.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        for identifier in identifiers {
            let locale = Locale(identifier: identifier)
            for code in ordered { add(locale.localizedString(forLanguageCode: code), code) }
        }
        for identifier in ["de", "es", "it", "pt", "nl"] {
            let locale = Locale(identifier: identifier)
            for code in pickerLanguageCodes { add(locale.localizedString(forLanguageCode: code), code) }
        }
        for code in twoLetter {
            add(Locale(identifier: code).localizedString(forLanguageCode: code), code)
        }
        return index
    }()

    private struct MatchTokens {
        var words: Set<String> = []
        var phrases: [[String]] = []
    }

    private static let tokenCacheLock = NSLock()
    nonisolated(unsafe) private static var tokenCache: [String: MatchTokens] = [:]

    /// Words / phrases designating `code` inside a free-form track name.
    private static func matchTokens(for code: String) -> MatchTokens {
        tokenCacheLock.lock()
        defer { tokenCacheLock.unlock() }
        if let cached = tokenCache[code] { return cached }
        var tokens = MatchTokens()
        func addName(_ name: String?) {
            guard let name else { return }
            let parts = normalizedName(name).split(whereSeparator: { !$0.isLetter }).map(String.init)
            if parts.count == 1 { tokens.words.insert(parts[0]) } else if parts.count > 1 { tokens.phrases.append(parts) }
        }
        for locale in [Locale.current, Locale(identifier: "en"), Locale(identifier: "fr"), Locale(identifier: code)] {
            addName(locale.localizedString(forLanguageCode: code))
        }
        let languageCode = Locale.LanguageCode(code)
        if let alpha3 = languageCode.identifier(.alpha3), alpha3.count == 3 { tokens.words.insert(alpha3) }
        if code.count == 3 { tokens.words.insert(code) }
        for (bibliographic, terminology) in bibliographicToTerminology
        where Locale.LanguageCode(terminology).identifier(.alpha2) == code || terminology == code {
            tokens.words.insert(bibliographic)
        }
        for (legacy, modern) in legacyCodes where modern == code && legacy.count == 3 { tokens.words.insert(legacy) }
        tokens.words.subtract(ambiguousWordCodes)
        tokens.words = tokens.words.filter { $0.count >= 3 }
        // Release aliases are specific enough to match at any length ("VF").
        for (alias, aliasCode) in releaseAliases where aliasCode == code {
            let parts = alias.split(separator: " ").map(String.init)
            if parts.count == 1 { tokens.words.insert(alias) } else { tokens.phrases.append(parts) }
        }
        tokenCache[code] = tokens
        return tokens
    }

    /// Contents of "[…]" and "(…)" groups.
    private static func enclosedParts(of value: String) -> [String] {
        var parts: [String] = []
        var current: String?
        for character in value {
            switch character {
            case "[", "(":
                current = ""
            case "]", ")":
                if let part = current?.trimmingCharacters(in: .whitespaces), !part.isEmpty { parts.append(part) }
                current = nil
            default:
                current?.append(character)
            }
        }
        return parts
    }

    private static func containsPhrase(_ words: [String], _ phrase: [String]) -> Bool {
        guard !phrase.isEmpty, words.count >= phrase.count else { return false }
        for start in 0...(words.count - phrase.count) where Array(words[start..<(start + phrase.count)]) == phrase {
            return true
        }
        return false
    }
}
