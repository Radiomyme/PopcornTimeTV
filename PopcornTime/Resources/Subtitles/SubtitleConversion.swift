

import Foundation

// CONTRACT FILE — owned by agent C1. Pure Foundation (no UIKit / PopcornKit)
// so the remux engine and the headless test harness can use it.
//
// Every text subtitle we meet — OpenSubtitles downloads (SRT, MicroDVD,
// SubViewer, ASS/SSA, WebVTT, MPL2, TMPlayer, SAMI in any legacy code page)
// and Matroska text tracks (S_TEXT/UTF8, ASS/SSA, WebVTT) — is turned into
// WebVTT cues: payload limited to <i>/<b>/<u>, entities escaped, never a
// blank line inside a cue (a blank line terminates a WebVTT cue, which is
// how the CRLF bug made Apple's parser drop every cue), top positioning kept.
// Thread-safe: the only shared state is two small lock-protected caches.

/// One subtitle cue on the media timeline.
struct SubtitleCue: Equatable {
    /// Seconds on the media timeline.
    var start: Double
    var end: Double
    /// WebVTT cue payload: plain text with optional <i>, <b>, <u> tags and
    /// "\n" line breaks; `&`, `<`, `>` escaped as WebVTT requires.
    var text: String
    /// WebVTT cue settings (e.g. "line:10% align:center"), nil for defaults.
    var settings: String?
}

enum SubtitleFormat: String {
    case srt, webvtt, ass, microDVD, subViewer, unknown
    // C1 additions — other text formats OpenSubtitles serves (.mpl, .txt, .smi).
    case mpl2, tmPlayer, sami
}

enum SubtitleConversion {

    /// Display time for an embedded Matroska block without BlockDuration.
    static let matroskaDefaultDuration: Double = 4.0
    /// Display time for a parsed cue whose end is missing or not after its
    /// start (capped by the next cue's start).
    static let fallbackCueDuration: Double = 3.0

    /// Decode subtitle bytes to text. Order: BOM (UTF-8/16LE/16BE) → strict
    /// UTF-8 → `encodingHint` (OpenSubtitles `SubEncoding` / IANA names such
    /// as "CP1251", "ISO-8859-2", "GB18030", "Big5", "Shift_JIS") → a code
    /// page chosen from `languageHint` (ISO 639-1/2: ru→CP1251, ar→CP1256,
    /// el→CP1253, he→CP1255, tr→CP1254, pl/cs/hu/ro…→CP1250, zh→GB18030,
    /// ja→Shift_JIS, ko→EUC-KR…) → Windows-1252 → ISO Latin-1.
    ///
    /// Details: UTF-32 BOMs, BOM-less UTF-16 (NUL byte pattern) and
    /// ISO-2022 escape sequences are recognised; a mostly-UTF-8 file with
    /// some legacy lines (OpenSubtitles injects its ad lines in the declared
    /// code page into UTF-8 files) is decoded line by line, each legacy line
    /// with the hint / language code page; a single-byte hint is only
    /// second-guessed when it reads as no text of the hinted language at all
    /// (e.g. "CP1252" on a CP1251 Russian file); undefined bytes of a code
    /// page are dropped instead of failing the file; trailing NUL padding is
    /// dropped; the result is NFC-normalised (CP1258 Vietnamese tone marks).
    static func decodeText(_ data: Data, encodingHint: String? = nil, languageHint: String? = nil) -> String? {
        SubtitleTextDecoder.decode([UInt8](data), encodingHint: encodingHint, languageHint: languageHint)
    }

    static func detectFormat(_ text: String) -> SubtitleFormat {
        SubtitleSniffer.detect(SubtitleText.lines(SubtitleText.normalize(text)))
    }

    /// Parse any supported text format. `frameRate` is only used by MicroDVD
    /// ({frame}{frame}text) when the file doesn't declare one ({1}{1}23.976).
    ///
    /// `format` is a hint: an unmistakable header (WEBVTT, [Script Info],
    /// <SAMI>) wins over it, and when the hinted parser finds nothing the
    /// content is sniffed. Cues come back sorted by start, end > start,
    /// exact duplicates (ASS layers) removed, empty payloads dropped.
    static func parse(_ text: String, format: SubtitleFormat? = nil, frameRate: Double = 23.976) -> [SubtitleCue] {
        let lines = SubtitleText.lines(SubtitleText.normalize(text))
        let fps = frameRate.isFinite && frameRate > 1 ? frameRate : 23.976
        if let strong = SubtitleSniffer.strongSignature(lines) {
            return SubtitleParsers.parse(lines, as: strong, frameRate: fps)
        }
        if let hinted = format, hinted != .unknown {
            let cues = SubtitleParsers.parse(lines, as: hinted, frameRate: fps)
            if !cues.isEmpty { return cues }
        }
        let detected = SubtitleSniffer.detect(lines)
        guard detected != .unknown, detected != format else { return [] }
        return SubtitleParsers.parse(lines, as: detected, frameRate: fps)
    }

    /// Serialize cues to a WebVTT document (cues sorted by start time).
    /// `timestampMap`: emit `X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000`
    /// (cue times = media timeline) for HLS segment files.
    static func makeWebVTT(_ cues: [SubtitleCue], timestampMap: Bool = false) -> String {
        var out = "WEBVTT\n"
        if timestampMap { out += "X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n" }
        out += "\n"
        let ordered = cues.enumerated().sorted {
            $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset
        }
        for (_, cue) in ordered {
            let startMs = SubtitleText.milliseconds(cue.start)
            let endMs = SubtitleText.milliseconds(cue.end)
            guard endMs > startMs else { continue }   // WebVTT cues must end after they start
            let payload = SubtitleText.safePayload(cue.text)
            guard !payload.isEmpty else { continue }
            out += SubtitleText.vttTimestamp(startMs) + " --> " + SubtitleText.vttTimestamp(endMs)
            if let settings = cue.settings.map(SubtitleText.singleLine), !settings.isEmpty {
                out += " " + settings
            }
            out += "\n" + payload + "\n\n"
        }
        return out
    }

    /// Convenience for external files: decode + detect + parse + serialize.
    /// Returns nil when nothing could be parsed.
    static func webVTT(fromSubtitleData data: Data,
                       formatHint: String? = nil,
                       encodingHint: String? = nil,
                       languageHint: String? = nil) -> String? {
        webVTT(fromSubtitleData: data, formatHint: formatHint, encodingHint: encodingHint,
               languageHint: languageHint, frameRate: nil, timestampMap: false)
    }

    /// C1 addition — same as above, plus `frameRate` for MicroDVD files that
    /// don't declare one (pass `Subtitle.frameRate`, the OpenSubtitles
    /// `MovieFPS`) and `timestampMap` as in `makeWebVTT`.
    static func webVTT(fromSubtitleData data: Data,
                       formatHint: String?,
                       encodingHint: String?,
                       languageHint: String?,
                       frameRate: Double?,
                       timestampMap: Bool) -> String? {
        guard let text = decodeText(data, encodingHint: encodingHint, languageHint: languageHint) else { return nil }
        let cues = parse(text, format: format(fromHint: formatHint), frameRate: frameRate ?? 23.976)
        guard !cues.isEmpty else { return nil }
        return makeWebVTT(cues, timestampMap: timestampMap)
    }

    /// C1 addition — OpenSubtitles `SubFormat` / file extension → parser
    /// hint. Ambiguous values ("sub" = MicroDVD or SubViewer, "txt") return
    /// nil so the content decides.
    static func format(fromHint hint: String?) -> SubtitleFormat? {
        guard let key = hint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !key.isEmpty else { return nil }
        switch key.hasPrefix(".") ? String(key.dropFirst()) : key {
        case "srt", "subrip", "s_text/utf8", "s_text/ascii": return .srt
        case "vtt", "webvtt", "s_text/webvtt": return .webvtt
        case "ass", "ssa", "s_text/ass", "s_text/ssa": return .ass
        case "mpl", "mpl2": return .mpl2
        case "smi", "sami": return .sami
        case "tmp", "tmplayer": return .tmPlayer
        case "microdvd": return .microDVD
        case "subviewer": return .subViewer
        default: return nil
        }
    }

    /// True for Matroska text subtitle codecs we can convert
    /// (S_TEXT/UTF8, S_TEXT/ASCII, S_TEXT/SSA, S_TEXT/ASS, S_TEXT/WEBVTT, S_SSA, S_ASS).
    /// C1: also WebM's D_WEBVTT/SUBTITLES and D_WEBVTT/CAPTIONS.
    static func isTextSubtitleCodec(_ codecID: String) -> Bool {
        textCodecs.contains(codecID.trimmingCharacters(in: .whitespaces).uppercased())
    }

    private static let textCodecs: Set<String> = [
        "S_TEXT/UTF8", "S_TEXT/ASCII", "S_TEXT/SSA", "S_TEXT/ASS", "S_TEXT/WEBVTT", "S_SSA", "S_ASS",
        "D_WEBVTT/SUBTITLES", "D_WEBVTT/CAPTIONS",
    ]

    /// One embedded Matroska text block → cue. `start` / `duration` in
    /// seconds (duration from BlockDuration; nil → a 4 s default).
    /// `codecPrivate` = the track's CodecPrivate (ASS/SSA header, WebVTT
    /// header) — may be empty. `additions` = BlockAdditional payload
    /// (WebVTT cue settings) when present.
    static func cue(fromMatroskaBlock data: Data,
                    codecID: String,
                    codecPrivate: Data,
                    start: Double,
                    duration: Double?,
                    additions: Data?) -> SubtitleCue? {
        let codec = codecID.trimmingCharacters(in: .whitespaces).uppercased()
        guard textCodecs.contains(codec), start.isFinite else { return nil }
        let text = SubtitleText.normalize(decodeText(data) ?? "")
        guard !SubtitleText.isBlank(Substring(text)) else { return nil }
        let length = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? matroskaDefaultDuration
        let end = start + length
        var raw: RawCue
        switch codec {
        case "S_TEXT/SSA", "S_TEXT/ASS", "S_SSA", "S_ASS":
            raw = SubtitleParsers.assBlock(text, script: ASSHeaderCache.shared.script(for: codecPrivate), start: start, end: end)
        case "S_TEXT/WEBVTT":
            raw = SubtitleParsers.render(text, start: start, end: end, options: .vtt)
            if let settings = additions.flatMap(SubtitleParsers.webVTTSettings(fromAdditions:)) { raw.settings = settings }
        case "D_WEBVTT/SUBTITLES", "D_WEBVTT/CAPTIONS":
            // WebM layout: identifier LF settings LF payload.
            let block = SubtitleParsers.splitWebMBlock(text)
            raw = SubtitleParsers.render(block.payload, start: start, end: end, options: .vtt)
            if let settings = block.settings ?? additions.flatMap(SubtitleParsers.webVTTSettings(fromAdditions:)) {
                raw.settings = settings
            }
        default: // S_TEXT/UTF8, S_TEXT/ASCII: SRT-style payload
            raw = SubtitleParsers.render(text, start: start, end: end, options: .srt)
        }
        guard !raw.text.isEmpty else { return nil }
        return SubtitleCue(start: start, end: end, text: raw.text, settings: raw.settings)
    }

    /// Cue payload → display text for overlays: tags removed, entities
    /// unescaped, line breaks kept.
    static func plainText(_ cueText: String) -> String {
        var stripped = String.UnicodeScalarView()
        var inTag = false
        for scalar in cueText.unicodeScalars {
            if inTag {
                if scalar == ">" { inTag = false }
            } else if scalar == "<" {
                inTag = true
            } else {
                stripped.append(scalar)
            }
        }
        guard stripped.contains("&") else { return String(stripped) }
        let scalars = Array(stripped)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            if scalars[i] == "&", let (replacement, next) = SubtitleText.entity(scalars, i) {
                out.append(contentsOf: replacement.unicodeScalars)
                i = next
            } else {
                out.append(scalars[i])
                i += 1
            }
        }
        return String(out)
    }
}

// MARK: - Shared text helpers

fileprivate enum SubtitleText {

    /// CRLF / CR → LF, BOMs and NULs removed, Unicode line separators → LF.
    static func normalize(_ text: String) -> String {
        var s = text
        if s.unicodeScalars.contains("\r") {
            s = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        if s.unicodeScalars.contains(where: { $0 == "\u{FEFF}" || $0 == "\u{0}" || $0 == "\u{2028}" || $0 == "\u{2029}" }) {
            s = s.replacingOccurrences(of: "\u{FEFF}", with: "")
                .replacingOccurrences(of: "\u{0}", with: "")
                .replacingOccurrences(of: "\u{2028}", with: "\n")
                .replacingOccurrences(of: "\u{2029}", with: "\n")
        }
        return s
    }

    static func lines(_ normalized: String) -> [Substring] {
        normalized.split(separator: "\n", omittingEmptySubsequences: false)
    }

    static func trim<S: StringProtocol>(_ s: S) -> String {
        s.trimmingCharacters(in: .whitespaces)
    }

    static func isBlank(_ s: Substring) -> Bool {
        s.unicodeScalars.allSatisfy { $0.properties.isWhitespace || $0 == "\u{200B}" }
    }

    /// An SRT cue number ("12").
    static func isIndexLine(_ s: Substring) -> Bool {
        let t = trim(s)
        return !t.isEmpty && t.utf8.count <= 9 && t.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    static func singleLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: Timestamps

    @inline(__always) static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

    /// Tolerant timestamp at `start` (leading spaces skipped):
    /// `[h:]m:s[(,|.)fraction]` — any number of hour digits, 1-digit fields,
    /// missing hours — or `h:m:s:fraction` (colon before the milliseconds,
    /// seen in broken SRTs). The fraction is decimal ("5" = 500 ms).
    /// Returns the seconds and the index just past the timestamp.
    static func scanTimestamp(_ b: [UInt8], from start: Int, minGroups: Int = 2) -> (seconds: Double, end: Int)? {
        var i = start
        while i < b.count, b[i] == 0x20 || b[i] == 0x09 { i += 1 }
        var groups: [Int] = []
        var lastDigits = 0
        while groups.count < 4 {
            if !groups.isEmpty {
                guard i + 1 < b.count, b[i] == 0x3A, isDigit(b[i + 1]) else { break }
                i += 1
            }
            var value = 0, digits = 0
            while i < b.count, isDigit(b[i]) {
                if digits < 9 { value = value * 10 + Int(b[i] - 0x30) }
                digits += 1
                i += 1
            }
            guard digits > 0 else { break }
            groups.append(value)
            lastDigits = min(digits, 9)
        }
        var fraction = 0, fractionDigits = 0
        if groups.count == 4 {
            fraction = groups.removeLast()
            fractionDigits = min(lastDigits, 6)
            while lastDigits > 6 { fraction /= 10; lastDigits -= 1 }
        } else if i + 1 < b.count, b[i] == 0x2C || b[i] == 0x2E, isDigit(b[i + 1]) {
            i += 1
            while i < b.count, isDigit(b[i]) {
                if fractionDigits < 6 {
                    fraction = fraction * 10 + Int(b[i] - 0x30)
                    fractionDigits += 1
                }
                i += 1
            }
        }
        guard groups.count >= max(1, minGroups) else { return nil }
        let whole = groups.reduce(0) { $0 * 60 + $1 }
        var scale = 1
        for _ in 0..<fractionDigits { scale *= 10 }
        // Integer units, one division: the result is the double nearest to
        // the decimal value (round trips through makeWebVTT exactly).
        return (Double(whole * scale + fraction) / Double(scale), i)
    }

    /// "start --> end[ rest]" (SRT and WebVTT timing lines). `rest` holds
    /// WebVTT cue settings or SRT "X1:… Y2:…" coordinates.
    static func parseTimingLine(_ line: Substring) -> (start: Double, end: Double, rest: String)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let left = Array(line[..<arrow.lowerBound].utf8)
        let right = Array(line[arrow.upperBound...].utf8)
        // Left side: its last timestamp-looking token (broken files put the
        // cue number on the same line).
        var tokenEnd = left.count
        while tokenEnd > 0, left[tokenEnd - 1] == 0x20 || left[tokenEnd - 1] == 0x09 { tokenEnd -= 1 }
        var tokenStart = tokenEnd
        while tokenStart > 0, isDigit(left[tokenStart - 1]) || left[tokenStart - 1] == 0x3A
                || left[tokenStart - 1] == 0x2C || left[tokenStart - 1] == 0x2E {
            tokenStart -= 1
        }
        guard tokenStart < tokenEnd else { return nil }
        let token = Array(left[tokenStart..<tokenEnd])
        guard let start = scanTimestamp(token, from: 0, minGroups: 2), start.end == token.count,
              let end = scanTimestamp(right, from: 0, minGroups: 2) else { return nil }
        let rest = String(decoding: right[end.end...], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return (start.seconds, end.seconds, rest)
    }

    static func milliseconds(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds * 1000, 3.6e12).rounded())
    }

    /// HH:MM:SS.mmm — hours always at least two digits.
    static func vttTimestamp(_ ms: Int) -> String {
        let hours = ms / 3_600_000, minutes = (ms / 60_000) % 60, seconds = (ms / 1000) % 60, millis = ms % 1000
        return pad(hours, 2) + ":" + pad(minutes, 2) + ":" + pad(seconds, 2) + "." + pad(millis, 3)
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let s = String(value)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    // MARK: Payload

    static func escape(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { $0 == "&" || $0 == "<" || $0 == ">" }) else { return s }
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out.append(contentsOf: "&amp;".unicodeScalars)
            case "<": out.append(contentsOf: "&lt;".unicodeScalars)
            case ">": out.append(contentsOf: "&gt;".unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// Defensive pass for payloads handed to `makeWebVTT`: no CR, no blank
    /// line (it would end the cue), no "-->" (it would start a new one).
    static func safePayload(_ text: String) -> String {
        var t = text
        if t.unicodeScalars.contains("\r") {
            t = t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        var joined = t.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !isBlank($0) }
            .joined(separator: "\n")
        if joined.contains("-->") { joined = joined.replacingOccurrences(of: "-->", with: "--&gt;") }
        return joined
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "nbsp": "\u{00A0}", "lrm": "\u{200E}", "rlm": "\u{200F}",
        "quot": "\"", "apos": "'",
    ]

    /// HTML/WebVTT character reference at `s[i] == "&"` → (text, index after ';').
    static func entity(_ s: [Unicode.Scalar], _ i: Int) -> (String, Int)? {
        var j = i + 1
        var name = String.UnicodeScalarView()
        while j < s.count, j - i <= 12, s[j] != ";" {
            let c = s[j]
            let allowed = c.isASCII && (c.properties.isAlphabetic || ("0"..."9").contains(c) || (c == "#" && j == i + 1))
            guard allowed else { return nil }
            name.append(c)
            j += 1
        }
        guard j < s.count, s[j] == ";", !name.isEmpty else { return nil }
        let key = String(name)
        if key.hasPrefix("#") {
            let digits = key.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits)
            }
            guard let v = value, v != 0, let scalar = Unicode.Scalar(v) else { return nil }
            return (String(scalar), j + 1)
        }
        guard let replacement = namedEntities[key.lowercased()] else { return nil }
        return (replacement, j + 1)
    }
}

// MARK: - Format detection

fileprivate enum SubtitleSniffer {

    /// Headers no other format can have; they override any format hint.
    static func strongSignature(_ lines: [Substring]) -> SubtitleFormat? {
        guard let first = lines.first(where: { !SubtitleText.isBlank($0) }) else { return nil }
        let head = SubtitleText.trim(first)
        if head.hasPrefix("WEBVTT") { return .webvtt }
        let lower = head.lowercased()
        if lower == "[script info]" { return .ass }
        if lower.hasPrefix("<sami") { return .sami }
        return nil
    }

    static func detect(_ lines: [Substring]) -> SubtitleFormat {
        if let strong = strongSignature(lines) { return strong }
        var counts: [SubtitleFormat: Int] = [:]
        var assSections = 0
        var sami = false
        for line in lines.prefix(5000) {
            let t = SubtitleText.trim(line)
            guard let first = t.utf8.first else { continue }
            if first == UInt8(ascii: "[") {
                let lower = t.lowercased()
                if lower == "[script info]" || lower == "[events]" || lower == "[v4+ styles]"
                    || lower == "[v4 styles]" || lower == "[v4 styles+]" {
                    assSections += 1
                    continue
                }
            }
            if t.count >= 9, t.prefix(9).lowercased() == "dialogue:" { counts[.ass, default: 0] += 1; continue }
            if !sami, t.range(of: "<sync", options: .caseInsensitive) != nil { sami = true }
            let line = Substring(t)
            if SubtitleParsers.framePrefix(line, open: 0x7B, close: 0x7D) != nil { counts[.microDVD, default: 0] += 1; continue }
            if SubtitleParsers.framePrefix(line, open: 0x5B, close: 0x5D) != nil { counts[.mpl2, default: 0] += 1; continue }
            if t.contains("-->"), SubtitleText.parseTimingLine(line) != nil { counts[.srt, default: 0] += 1; continue }
            if SubtitleParsers.subViewerTiming(t) != nil { counts[.subViewer, default: 0] += 1; continue }
            if SubtitleParsers.tmPlayerLine(t) != nil { counts[.tmPlayer, default: 0] += 1; continue }
        }
        if sami { return .sami }
        if assSections > 0, counts[.ass, default: 0] > 0 { return .ass }
        var best = SubtitleFormat.unknown, bestCount = 0
        for format in [SubtitleFormat.srt, .ass, .microDVD, .mpl2, .subViewer, .tmPlayer] {
            let count = counts[format, default: 0]
            if count > bestCount { best = format; bestCount = count }
        }
        return best
    }
}

// MARK: - Parsers

/// A parsed cue before sorting / end-time fix-up. `end` nil = unknown.
fileprivate struct RawCue {
    var start: Double
    var end: Double?
    var text: String
    var settings: String?
}

fileprivate enum SubtitleParsers {

    static func parse(_ lines: [Substring], as format: SubtitleFormat, frameRate: Double) -> [SubtitleCue] {
        let raw: [RawCue]
        switch format {
        case .srt: raw = srt(lines)
        case .webvtt: raw = webVTT(lines)
        case .ass: raw = ASSScript.parse(lines).cues
        case .microDVD: raw = microDVD(lines, frameRate: frameRate)
        case .subViewer: raw = subViewer(lines)
        case .mpl2: raw = mpl2(lines)
        case .tmPlayer: raw = tmPlayer(lines)
        case .sami: raw = sami(lines.joined(separator: "\n"))
        case .unknown: raw = []
        }
        return finalize(raw)
    }

    /// Sort by start (stable), give every cue an end after its start, cut
    /// runaway end times, drop empty payloads and exact duplicates.
    static func finalize(_ raw: [RawCue]) -> [SubtitleCue] {
        var items: [(index: Int, cue: RawCue)] = []
        items.reserveCapacity(raw.count)
        for (index, cue) in raw.enumerated() where !cue.text.isEmpty && cue.start.isFinite {
            items.append((index, cue))
        }
        items.sort { $0.cue.start != $1.cue.start ? $0.cue.start < $1.cue.start : $0.index < $1.index }
        var timed: [SubtitleCue] = []
        timed.reserveCapacity(items.count)
        for (k, item) in items.enumerated() {
            let start = max(0, item.cue.start)
            var end = item.cue.end ?? -1
            if !end.isFinite || SubtitleText.milliseconds(end) <= SubtitleText.milliseconds(start) {
                var next: Double?
                var j = k + 1
                while j < items.count {
                    if SubtitleText.milliseconds(items[j].cue.start) > SubtitleText.milliseconds(start) {
                        next = items[j].cue.start
                        break
                    }
                    j += 1
                }
                end = min(start + SubtitleConversion.fallbackCueDuration, next ?? .infinity)
            }
            timed.append(SubtitleCue(start: start, end: end, text: item.cue.text, settings: item.cue.settings))
        }
        // Runaway end time: a bottom cue still up after a minute while later
        // cues keep starting under it is a typo ("00:17:35.38,80:17:38.22" in
        // a real file — 80 hours on screen). End it where the next cue starts.
        // Positioned cues (ASS signs, top captions) may overlap dialogue.
        for k in timed.indices where timed[k].end - timed[k].start > 60 && timed[k].settings == nil {
            var later = 0
            var nextStart: Double?
            var j = k + 1
            while j < timed.count, timed[j].start < timed[k].end, later < 2 {
                if SubtitleText.milliseconds(timed[j].start) > SubtitleText.milliseconds(timed[k].start) {
                    later += 1
                    if nextStart == nil { nextStart = timed[j].start }
                }
                j += 1
            }
            if later >= 2, let next = nextStart { timed[k].end = next }
        }
        struct Key: Hashable { let start: Int; let end: Int; let text: String; let settings: String? }
        var seen = Set<Key>()
        var out: [SubtitleCue] = []
        out.reserveCapacity(timed.count)
        for cue in timed {
            let key = Key(start: SubtitleText.milliseconds(cue.start), end: SubtitleText.milliseconds(cue.end),
                          text: cue.text, settings: cue.settings)
            if seen.insert(key).inserted { out.append(cue) }
        }
        return out
    }

    /// Markup → WebVTT payload, plus positioning from {\anN}.
    static func render(_ text: String, start: Double, end: Double?, options: MarkupOptions,
                       style: ASSStyle = ASSStyle(), styles: [String: ASSStyle] = [:]) -> RawCue {
        var renderer = MarkupRenderer(style: style, styles: styles)
        renderer.feed(text, options)
        return RawCue(start: start, end: end, text: renderer.builder.render(),
                      settings: ASSStyle.settings(forAlignment: renderer.alignment ?? style.alignment))
    }

    // MARK: SubRip

    /// Every line between two timing lines is cue text, minus the next cue's
    /// number; blank lines inside are collapsed by the renderer. Cue numbers
    /// are optional.
    static func srt(_ lines: [Substring]) -> [RawCue] {
        var out: [RawCue] = []
        var current: (start: Double, end: Double, text: [Substring])?
        func flush() {
            guard let cue = current else { return }
            var text = cue.text
            while let last = text.last, SubtitleText.isBlank(last) { text.removeLast() }
            if text.count >= 2, let last = text.last, SubtitleText.isIndexLine(last) {
                text.removeLast()
                while let last = text.last, SubtitleText.isBlank(last) { text.removeLast() }
            }
            out.append(render(text.joined(separator: "\n"), start: cue.start, end: cue.end, options: .srt))
        }
        for line in lines {
            if line.contains("-->"), let timing = SubtitleText.parseTimingLine(line) {
                flush()
                current = (timing.start, timing.end, [])
            } else if current != nil {
                current?.text.append(line)
            }
        }
        flush()
        return out
    }

    // MARK: WebVTT

    static func webVTT(_ lines: [Substring]) -> [RawCue] {
        var out: [RawCue] = []
        var i = 0
        while i < lines.count, SubtitleText.isBlank(lines[i]) { i += 1 }
        if i < lines.count, SubtitleText.trim(lines[i]).hasPrefix("WEBVTT") {
            while i < lines.count, !SubtitleText.isBlank(lines[i]) { i += 1 }   // header block
        }
        while i < lines.count {
            while i < lines.count, SubtitleText.isBlank(lines[i]) { i += 1 }
            guard i < lines.count else { break }
            var block: [Substring] = []
            while i < lines.count, !SubtitleText.isBlank(lines[i]) { block.append(lines[i]); i += 1 }
            let first = SubtitleText.trim(block[0])
            if first.hasPrefix("NOTE"), first.count == 4 || first.dropFirst(4).first?.isWhitespace == true { continue }
            if first == "STYLE" || first == "REGION" { continue }
            let timingIndex: Int
            if block[0].contains("-->") {
                timingIndex = 0
            } else if block.count > 1, block[1].contains("-->") {
                timingIndex = 1   // block[0] = cue identifier
            } else {
                continue
            }
            guard let timing = SubtitleText.parseTimingLine(block[timingIndex]) else { continue }
            var cue = render(block[(timingIndex + 1)...].joined(separator: "\n"), start: timing.start, end: timing.end, options: .vtt)
            if let settings = sanitizedSettings(timing.rest) { cue.settings = settings }
            out.append(cue)
        }
        return out
    }

    /// Keeps the cue settings AVFoundation understands; drops `region:`
    /// (REGION blocks are not carried over) and anything unknown.
    static func sanitizedSettings(_ s: String) -> String? {
        let allowed: Set<String> = ["vertical", "line", "position", "size", "align"]
        let tokens = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).filter { token in
            guard let colon = token.firstIndex(of: ":") else { return false }
            let key = token[..<colon].lowercased()
            return allowed.contains(key) && token.index(after: colon) < token.endIndex
        }
        return tokens.isEmpty ? nil : tokens.joined(separator: " ")
    }

    /// Matroska S_TEXT/WEBVTT BlockAdditional: cue settings on the first
    /// line (tolerates the identifier-first order too).
    static func webVTTSettings(fromAdditions data: Data) -> String? {
        let text = SubtitleText.normalize(String(decoding: data, as: UTF8.self))
        for line in SubtitleText.lines(text).prefix(2) {
            if let settings = sanitizedSettings(String(line)) { return settings }
        }
        return nil
    }

    /// WebM D_WEBVTT block: "identifier\nsettings\npayload".
    static func splitWebMBlock(_ text: String) -> (payload: String, settings: String?) {
        let lines = SubtitleText.lines(text)
        guard lines.count >= 3 else { return (text, nil) }
        let settings = sanitizedSettings(String(lines[1]))
        guard settings != nil || SubtitleText.isBlank(lines[1]) else { return (text, nil) }
        return (lines[2...].joined(separator: "\n"), settings)
    }

    // MARK: MicroDVD ({frame}{frame}text) and MPL2 ([ds][ds]text)

    /// `open` digits `close` `open` digits? `close` prefix → (first, second, text).
    static func framePrefix(_ line: Substring, open: UInt8, close: UInt8) -> (first: Int, second: Int?, text: Substring)? {
        let u = line.utf8
        var i = u.startIndex
        func number() -> (value: Int, digits: Int) {
            var value = 0, digits = 0
            while i < u.endIndex, SubtitleText.isDigit(u[i]) {
                if digits < 10 { value = value * 10 + Int(u[i] - 0x30) }
                digits += 1
                i = u.index(after: i)
            }
            return (value, digits)
        }
        guard i < u.endIndex, u[i] == open else { return nil }
        i = u.index(after: i)
        let first = number()
        guard first.digits > 0, first.digits <= 10, i < u.endIndex, u[i] == close else { return nil }
        i = u.index(after: i)
        guard i < u.endIndex, u[i] == open else { return nil }
        i = u.index(after: i)
        let second = number()
        guard second.digits <= 10, i < u.endIndex, u[i] == close else { return nil }
        i = u.index(after: i)
        return (first.value, second.digits > 0 ? second.value : nil, line[i...])
    }

    static func microDVD(_ lines: [Substring], frameRate: Double) -> [RawCue] {
        var entries: [(first: Int, second: Int?, text: Substring)] = []
        for line in lines {
            if let entry = framePrefix(line.drop(while: { $0 == " " || $0 == "\t" }), open: 0x7B, close: 0x7D) {
                entries.append(entry)
            }
        }
        var fps = frameRate
        // "{1}{1}23.976" (or {0}{0}25): the frame rate the file was made for.
        if let first = entries.first, first.first <= 1, (first.second ?? 0) <= 1,
           let declared = Double(SubtitleText.trim(first.text).replacingOccurrences(of: ",", with: ".")),
           declared >= 5, declared <= 200 {
            fps = declared
            entries.removeFirst()
        } else if let declared = entries.prefix(5).lazy.compactMap({ movieInfoFrameRate($0.text) }).first {
            fps = declared
        }
        return entries.map {
            render(String($0.text), start: Double($0.first) / fps, end: $0.second.map { Double($0) / fps }, options: .microDVD)
        }
    }

    /// SubEdit's declaration cue: "{1}{75}movie info: XVID 480x272 25.0fps 694.7 MB|…".
    static func movieInfoFrameRate(_ text: Substring) -> Double? {
        let lower = text.lowercased()
        guard lower.contains("movie info"), let fps = lower.range(of: "fps") else { return nil }
        var head = lower[..<fps.lowerBound]
        while head.last == " " { head.removeLast() }
        let digits = String(head.reversed().prefix(while: { $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }).reversed())
        guard let value = Double(digits.replacingOccurrences(of: ",", with: ".")), value >= 5, value <= 200 else { return nil }
        return value
    }

    static func mpl2(_ lines: [Substring]) -> [RawCue] {
        lines.compactMap { line in
            guard let entry = framePrefix(line.drop(while: { $0 == " " || $0 == "\t" }), open: 0x5B, close: 0x5D) else { return nil }
            return render(String(entry.text), start: Double(entry.first) / 10, end: entry.second.map { Double($0) / 10 }, options: .mpl2)
        }
    }

    // MARK: SubViewer 2.0

    /// "hh:mm:ss.cc,hh:mm:ss.cc"
    static func subViewerTiming(_ t: String) -> (start: Double, end: Double)? {
        let u = Array(t.utf8)
        guard let start = SubtitleText.scanTimestamp(u, from: 0, minGroups: 3),
              start.end < u.count, u[start.end] == 0x2C,
              let end = SubtitleText.scanTimestamp(u, from: start.end + 1, minGroups: 3),
              u[end.end...].allSatisfy({ $0 == 0x20 || $0 == 0x09 }) else { return nil }
        return (start.seconds, end.seconds)
    }

    static func subViewer(_ lines: [Substring]) -> [RawCue] {
        var out: [RawCue] = []
        var current: (start: Double, end: Double, text: [Substring])?
        func flush() {
            if let cue = current {
                out.append(render(cue.text.joined(separator: "\n"), start: cue.start, end: cue.end, options: .subViewer))
            }
            current = nil
        }
        for line in lines {
            let t = SubtitleText.trim(line)
            if let timing = subViewerTiming(t) {
                flush()
                current = (timing.start, timing.end, [])
            } else if current != nil {
                if t.isEmpty { flush() } else { current?.text.append(line) }
            }
        }
        flush()
        return out
    }

    // MARK: TMPlayer (hh:mm:ss:text — no end times)

    static func tmPlayerLine(_ t: String) -> (seconds: Double, text: String)? {
        let u = Array(t.utf8)
        var i = 0
        func digits(_ maximum: Int) -> Int? {
            var value = 0, count = 0
            while i < u.count, count < maximum, SubtitleText.isDigit(u[i]) {
                value = value * 10 + Int(u[i] - 0x30)
                count += 1
                i += 1
            }
            return count > 0 ? value : nil
        }
        guard let h = digits(2), i < u.count, u[i] == 0x3A else { return nil }
        i += 1
        guard let m = digits(2), i < u.count, u[i] == 0x3A else { return nil }
        i += 1
        guard let s = digits(2), i < u.count else { return nil }
        if u[i] == 0x2C {   // TMPlayer+ "hh:mm:ss,n=" line number
            i += 1
            guard digits(3) != nil else { return nil }
        }
        guard i < u.count, u[i] == 0x3A || u[i] == 0x3D else { return nil }
        i += 1
        return (Double(h * 3600 + m * 60 + s), String(decoding: u[i...], as: UTF8.self))
    }

    static func tmPlayer(_ lines: [Substring]) -> [RawCue] {
        var entries: [(seconds: Double, text: String)] = []
        for line in lines {
            guard let entry = tmPlayerLine(SubtitleText.trim(line)) else { continue }
            let hasText = !SubtitleText.trim(entry.text).isEmpty
            if let last = entries.last, last.seconds == entry.seconds, hasText, !SubtitleText.trim(last.text).isEmpty {
                entries[entries.count - 1].text += "|" + entry.text   // multi-line variant
            } else {
                entries.append(entry)
            }
        }
        var out: [RawCue] = []
        for (k, entry) in entries.enumerated() where !SubtitleText.trim(entry.text).isEmpty {
            // Shown until the next line (an empty line clears), at most 5 s.
            var end = entry.seconds + 5
            if let next = entries[(k + 1)...].first(where: { $0.seconds > entry.seconds }) { end = min(end, next.seconds) }
            out.append(render(entry.text, start: entry.seconds, end: end, options: .tmPlayer))
        }
        return out
    }

    // MARK: SAMI (.smi)

    static func sami(_ text: String) -> [RawCue] {
        let s = Array(text.unicodeScalars)
        let lower = s.map { $0.value >= 0x41 && $0.value <= 0x5A ? Unicode.Scalar($0.value + 0x20)! : $0 }
        func find(_ needle: String, from: Int) -> Int? {
            let n = Array(needle.unicodeScalars)
            guard !n.isEmpty, lower.count >= n.count else { return nil }
            var i = from
            while i <= lower.count - n.count {
                if lower[i] == n[0] {
                    var k = 1
                    while k < n.count, lower[i + k] == n[k] { k += 1 }
                    if k == n.count { return i }
                }
                i += 1
            }
            return nil
        }
        var syncs: [Int] = []
        var position = 0
        while let p = find("<sync", from: position) { syncs.append(p); position = p + 5 }
        let bodyEnd = find("</body", from: syncs.last ?? 0) ?? s.count
        var entries: [(seconds: Double, cls: String?, html: String)] = []
        for (k, sync) in syncs.enumerated() {
            guard let tagEnd = lower[sync...].firstIndex(of: ">") else { continue }
            let tag = String(String.UnicodeScalarView(lower[sync..<tagEnd]))
            guard let startMs = attribute("start", in: tag).flatMap({ Double($0.prefix(while: { $0.isNumber })) }) else { continue }
            let contentEnd = max(tagEnd + 1, k + 1 < syncs.count ? syncs[k + 1] : bodyEnd)
            let content = Array(s[(tagEnd + 1)..<contentEnd])
            let lowerContent = Array(lower[(tagEnd + 1)..<contentEnd])
            let paragraphs = samiParagraphs(content, lowerContent)
            if paragraphs.isEmpty {
                entries.append((startMs / 1000, nil, String(String.UnicodeScalarView(content))))
            } else {
                for p in paragraphs { entries.append((startMs / 1000, p.cls, p.html)) }
            }
        }
        // Bilingual files (KRCC + ENCC…): keep the first class that has text.
        let chosen = entries.first(where: { $0.cls != nil && !render(stripComments($0.html), start: 0, end: nil, options: .sami).text.isEmpty })?.cls
        let kept = entries.filter { $0.cls == nil || $0.cls == chosen }
        var out: [RawCue] = []
        for (k, entry) in kept.enumerated() {
            var cue = render(stripComments(entry.html), start: entry.seconds, end: nil, options: .sami)
            guard !cue.text.isEmpty else { continue }   // "&nbsp;" syncs only clear the screen
            cue.end = kept[(k + 1)...].first(where: { $0.seconds > entry.seconds })?.seconds
            out.append(cue)
        }
        return out
    }

    /// `name=value` (quoted or bare) inside a lowercased tag.
    private static func attribute(_ name: String, in tag: String) -> String? {
        var search = tag.startIndex
        while let range = tag.range(of: name, range: search..<tag.endIndex) {
            search = range.upperBound
            var i = range.upperBound
            while i < tag.endIndex, tag[i] == " " { i = tag.index(after: i) }
            guard i < tag.endIndex, tag[i] == "=" else { continue }
            i = tag.index(after: i)
            while i < tag.endIndex, tag[i] == " " { i = tag.index(after: i) }
            guard i < tag.endIndex else { return nil }
            if tag[i] == "\"" || tag[i] == "'" {
                let quote = tag[i]
                let valueStart = tag.index(after: i)
                let valueEnd = tag[valueStart...].firstIndex(of: quote) ?? tag.endIndex
                return String(tag[valueStart..<valueEnd])
            }
            let valueEnd = tag[i...].firstIndex(where: { $0 == " " || $0 == ">" || $0 == "/" }) ?? tag.endIndex
            return String(tag[i..<valueEnd])
        }
        return nil
    }

    /// `<p class=…>` paragraphs of one SYNC block.
    private static func samiParagraphs(_ content: [Unicode.Scalar], _ lower: [Unicode.Scalar]) -> [(cls: String?, html: String)] {
        var starts: [Int] = []
        var i = 0
        while i + 2 < lower.count {
            if lower[i] == "<", lower[i + 1] == "p", lower[i + 2] == ">" || lower[i + 2] == " " || lower[i + 2] == "\t" || lower[i + 2] == "\n" {
                starts.append(i)
            }
            i += 1
        }
        var out: [(cls: String?, html: String)] = []
        for (k, start) in starts.enumerated() {
            guard let tagEnd = lower[start...].firstIndex(of: ">") else { continue }
            let tag = String(String.UnicodeScalarView(lower[start..<tagEnd]))
            let end = k + 1 < starts.count ? starts[k + 1] : content.count
            guard tagEnd + 1 <= end else { continue }
            out.append((attribute("class", in: tag), String(String.UnicodeScalarView(content[(tagEnd + 1)..<end]))))
        }
        return out
    }

    private static func stripComments(_ html: String) -> String {
        guard html.contains("<!--") else { return html }
        var out = html
        while let open = out.range(of: "<!--") {
            let close = out.range(of: "-->", range: open.upperBound..<out.endIndex)
            out.removeSubrange(open.lowerBound..<(close?.upperBound ?? out.endIndex))
        }
        return out
    }

    // MARK: Matroska ASS/SSA block

    /// "ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text".
    static func assBlock(_ text: String, script: ASSScript, start: Double, end: Double) -> RawCue {
        if text.hasPrefix("Dialogue:"), var cue = script.dialogue(text.dropFirst("Dialogue:".count)) {
            cue.start = start
            cue.end = end
            return cue
        }
        let fields = text.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        let styleName = fields.count == 9 ? SubtitleText.trim(fields[2]) : ""
        let body = fields.count == 9 ? String(fields[8]) : text
        let style = script.style(named: styleName)
        return render(body, start: start, end: end, options: .ass, style: style, styles: script.styles)
    }
}

// MARK: - ASS / SSA

fileprivate struct ASSStyle {
    var italic = false
    var bold = false
    var underline = false
    /// Numpad alignment (1–3 bottom, 4–6 middle, 7–9 top).
    var alignment = 2

    /// SSA v4 `\a` / style alignment (1–3 bottom, 5–7 top, 9–11 middle) → numpad.
    static func numpad(fromLegacy value: Int) -> Int? {
        let horizontal = value & 3
        guard horizontal != 0, value > 0, value < 12 else { return nil }
        switch value & 12 {
        case 0: return horizontal
        case 4: return 6 + horizontal
        case 8: return 3 + horizontal
        default: return nil
        }
    }

    static func settings(forAlignment alignment: Int?) -> String? {
        switch alignment {
        case 7, 8, 9: return "line:10%"
        case 4, 5, 6: return "line:50%"
        default: return nil
        }
    }
}

fileprivate struct ASSScript {
    var styles: [String: ASSStyle] = [:]
    var legacyStyles = false
    var eventFields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]

    static let v4PlusStyleFields = ["name", "fontname", "fontsize", "primarycolour", "secondarycolour", "outlinecolour",
                                    "backcolour", "bold", "italic", "underline", "strikeout", "scalex", "scaley",
                                    "spacing", "angle", "borderstyle", "outline", "shadow", "alignment", "marginl",
                                    "marginr", "marginv", "encoding"]
    static let v4StyleFields = ["name", "fontname", "fontsize", "primarycolour", "secondarycolour", "tertiarycolour",
                                "backcolour", "bold", "italic", "borderstyle", "outline", "shadow", "alignment",
                                "marginl", "marginr", "marginv", "alphalevel", "encoding"]

    /// Parses a whole script (or a Matroska CodecPrivate header): styles,
    /// the [Events] Format line and every Dialogue line. Comment:, Picture:,
    /// Sound:, Movie: and Command: events are ignored.
    static func parse(_ lines: [Substring]) -> (script: ASSScript, cues: [RawCue]) {
        var script = ASSScript()
        var section = ""
        var styleFields: [String]?
        var cues: [RawCue] = []
        for line in lines {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let first = trimmed.first, first != ";" else { continue }
            if first == "[" {
                section = SubtitleText.trim(trimmed).lowercased()
                if section.contains("styles") { script.legacyStyles = !section.contains("+") }
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = SubtitleText.trim(trimmed[..<colon]).lowercased()
            let value = trimmed[trimmed.index(after: colon)...]
            switch key {
            case "dialogue":
                if let cue = script.dialogue(value) { cues.append(cue) }
            case "format":
                let fields = value.split(separator: ",").map { SubtitleText.trim($0).lowercased() }
                if section.contains("events") || fields.contains("text") {
                    if fields.contains("text") { script.eventFields = fields }
                } else {
                    styleFields = fields
                }
            case "style":
                script.addStyle(value, fields: styleFields ?? (script.legacyStyles ? v4StyleFields : v4PlusStyleFields))
            case "scripttype":
                let version = SubtitleText.trim(value).lowercased()
                if version.hasSuffix("v4.00") { script.legacyStyles = true }
                if version.hasSuffix("v4.00+") { script.legacyStyles = false }
            default:
                continue
            }
        }
        return (script, cues)
    }

    private mutating func addStyle(_ value: Substring, fields: [String]) {
        let parts = value.split(separator: ",", maxSplits: max(0, fields.count - 1), omittingEmptySubsequences: false)
            .map { SubtitleText.trim($0) }
        func field(_ name: String) -> String? {
            guard let index = fields.firstIndex(of: name), index < parts.count else { return nil }
            return parts[index]
        }
        guard let name = field("name"), !name.isEmpty else { return }
        func flag(_ name: String) -> Bool { (field(name).flatMap { Int($0) } ?? 0) != 0 }   // -1 or 1 = on
        var style = ASSStyle(italic: flag("italic"), bold: flag("bold"), underline: flag("underline"))
        if let value = field("alignment").flatMap({ Int($0) }) {
            if legacyStyles {
                style.alignment = ASSStyle.numpad(fromLegacy: value) ?? 2
            } else if (1...9).contains(value) {
                style.alignment = value
            }
        }
        styles[name] = style
    }

    func style(named name: String) -> ASSStyle {
        if let style = styles[name] { return style }
        let bare = String(name.drop(while: { $0 == "*" }))
        if let style = styles[bare] { return style }
        if let match = styles.first(where: { $0.key.caseInsensitiveCompare(bare) == .orderedSame }) { return match.value }
        return styles["Default"] ?? ASSStyle()
    }

    /// The part after "Dialogue:". Text = everything after the (n−1)-th comma.
    func dialogue(_ value: Substring) -> RawCue? {
        let count = eventFields.count
        let parts = value.split(separator: ",", maxSplits: max(0, count - 1), omittingEmptySubsequences: false)
        guard parts.count == count,
              let startIndex = eventFields.firstIndex(of: "start"),
              let endIndex = eventFields.firstIndex(of: "end"),
              let start = SubtitleText.scanTimestamp(Array(parts[startIndex].utf8), from: 0, minGroups: 2),
              let end = SubtitleText.scanTimestamp(Array(parts[endIndex].utf8), from: 0, minGroups: 2) else { return nil }
        let styleName = eventFields.firstIndex(of: "style").map { SubtitleText.trim(parts[$0]) } ?? "Default"
        return SubtitleParsers.render(String(parts[count - 1]), start: start.seconds, end: end.seconds,
                                      options: .ass, style: style(named: styleName), styles: styles)
    }
}

/// Parsed CodecPrivate headers of Matroska ASS/SSA tracks (parsed once per
/// track instead of once per block).
fileprivate final class ASSHeaderCache: @unchecked Sendable {
    static let shared = ASSHeaderCache()
    private let lock = NSLock()
    private var scripts: [Data: ASSScript] = [:]

    func script(for codecPrivate: Data) -> ASSScript {
        lock.lock()
        defer { lock.unlock() }
        if let script = scripts[codecPrivate] { return script }
        let text = SubtitleText.normalize(SubtitleConversion.decodeText(codecPrivate) ?? "")
        let script = ASSScript.parse(SubtitleText.lines(text)).script
        if scripts.count >= 16 { scripts.removeAll() }
        scripts[codecPrivate] = script
        return script
    }
}

// MARK: - Markup → WebVTT payload

fileprivate struct MarkupOptions: OptionSet {
    let rawValue: Int
    static let html = MarkupOptions(rawValue: 1 << 0)          // <i> <b> <u> <font> <br> …
    static let assOverrides = MarkupOptions(rawValue: 1 << 1)  // {\i1} {\an8} … blocks
    static let assComments = MarkupOptions(rawValue: 1 << 2)   // ASS: any {…} is hidden
    static let assEscapes = MarkupOptions(rawValue: 1 << 3)    // \N \n \h
    static let entities = MarkupOptions(rawValue: 1 << 4)      // &amp; &#233; …
    static let pipeBreaks = MarkupOptions(rawValue: 1 << 5)    // "|" = line break
    static let slashItalic = MarkupOptions(rawValue: 1 << 6)   // "/" at line start = italic line
    static let microDVDCodes = MarkupOptions(rawValue: 1 << 7) // {y:i} {c:$0000FF} …
    static let bracketBreaks = MarkupOptions(rawValue: 1 << 8) // [br]
    static let collapseSpace = MarkupOptions(rawValue: 1 << 9) // HTML whitespace rules (SAMI)

    static let srt: MarkupOptions = [.html, .assOverrides, .assEscapes, .entities, .microDVDCodes]
    static let vtt: MarkupOptions = [.html, .entities, .assOverrides]
    static let ass: MarkupOptions = [.assOverrides, .assComments, .assEscapes]
    static let microDVD: MarkupOptions = [.pipeBreaks, .slashItalic, .microDVDCodes, .html, .assOverrides]
    static let mpl2: MarkupOptions = [.pipeBreaks, .slashItalic, .html]
    static let tmPlayer: MarkupOptions = [.pipeBreaks, .slashItalic, .html]
    static let subViewer: MarkupOptions = [.bracketBreaks, .html]
    static let sami: MarkupOptions = [.html, .entities, .collapseSpace]
}

/// Turns one cue's source markup into styled runs (`builder`) and an
/// optional numpad alignment. Unknown tags are stripped, unknown "<…"
/// that isn't a tag stays as text (escaped later).
fileprivate struct MarkupRenderer {
    var builder = CueTextBuilder()
    var alignment: Int?
    let baseStyle: ASSStyle
    let styles: [String: ASSStyle]
    private var drawing = false        // ASS \p1 … \p0 vector drawing: not text
    private var hiddenDepth = 0        // inside <rt>/<rp> (ruby annotations)
    private var htmlItalic = 0, htmlBold = 0, htmlUnderline = 0
    private var assItalic: Bool, assBold: Bool, assUnderline: Bool
    private var lineItalic = false, lineBold = false, lineUnderline = false   // MicroDVD {y:…}, leading "/"
    private var cueItalic = false, cueBold = false, cueUnderline = false      // MicroDVD {Y:…}

    init(style: ASSStyle, styles: [String: ASSStyle]) {
        baseStyle = style
        self.styles = styles
        assItalic = style.italic
        assBold = style.bold
        assUnderline = style.underline
        syncStyle()
    }

    private mutating func syncStyle() {
        builder.italic = assItalic || htmlItalic > 0 || lineItalic || cueItalic
        builder.bold = assBold || htmlBold > 0 || lineBold || cueBold
        builder.underline = assUnderline || htmlUnderline > 0 || lineUnderline || cueUnderline
    }

    private mutating func emit(_ scalar: Unicode.Scalar) {
        guard !drawing, hiddenDepth == 0 else { return }
        builder.append(scalar)
    }

    private mutating func emit(_ text: String) {
        for scalar in text.unicodeScalars { emit(scalar) }
    }

    private mutating func lineBreak() {
        builder.append("\n")
        if lineItalic || lineBold || lineUnderline {
            lineItalic = false
            lineBold = false
            lineUnderline = false
            syncStyle()
        }
    }

    mutating func feed(_ text: String, _ options: MarkupOptions) {
        var s = Array(text.unicodeScalars)
        if options.contains(.collapseSpace) { s = Self.collapsingWhitespace(s) }
        var i = 0
        var lineStart = true
        while i < s.count {
            let c = s[i]
            if lineStart {
                lineStart = false
                if options.contains(.slashItalic), c == "/" {
                    lineItalic = true
                    syncStyle()
                    i += 1
                    continue
                }
            }
            switch c {
            case "\n":
                lineBreak()
                lineStart = true
                i += 1
            case "|" where options.contains(.pipeBreaks):
                lineBreak()
                lineStart = true
                i += 1
            case "<" where options.contains(.html):
                if let (tag, next) = Self.htmlTag(s, i), handle(tag) {
                    i = next
                } else {
                    emit(c)
                    i += 1
                }
            case "{":
                if let next = brace(s, i, options) {
                    i = next
                } else {
                    emit(c)
                    i += 1
                }
            case "\\" where options.contains(.assEscapes) && i + 1 < s.count
                && (s[i + 1] == "N" || s[i + 1] == "n" || s[i + 1] == "h"):
                if s[i + 1] == "h" {
                    emit(" ")
                } else {
                    lineBreak()
                    lineStart = true
                }
                i += 2
            case "&" where options.contains(.entities):
                if let (replacement, next) = SubtitleText.entity(s, i) {
                    emit(replacement)
                    i = next
                } else {
                    emit(c)
                    i += 1
                }
            case "[" where options.contains(.bracketBreaks) && Self.isBreakTag(s, i):
                lineBreak()
                lineStart = true
                i += 4
            default:
                emit(c)
                i += 1
            }
        }
    }

    // MARK: {…} blocks

    private mutating func brace(_ s: [Unicode.Scalar], _ i: Int, _ options: MarkupOptions) -> Int? {
        if options.contains(.assOverrides) || options.contains(.assComments),
           let close = Self.index(of: "}", in: s, from: i + 1, limit: 4000) {
            if i + 1 < close, s[i + 1] == "\\" {
                applyOverrides(s[(i + 1)..<close])
                return close + 1
            }
            if options.contains(.assComments) { return close + 1 }
        }
        if options.contains(.microDVDCodes), let next = microDVDCode(s, i) { return next }
        return nil
    }

    /// ASS override tags: \i \b \u \an \a \p \r are honoured, the rest
    /// (colours, fonts, \pos, \move, \fad, \k, \t…) ignored.
    private mutating func applyOverrides(_ body: ArraySlice<Unicode.Scalar>) {
        let text = String(String.UnicodeScalarView(body))
        for piece in text.split(separator: "\\") {
            let tag = SubtitleText.trim(piece)
            guard let first = tag.first else { continue }
            let argument = tag.dropFirst()
            if tag.hasPrefix("an") {
                if alignment == nil, let value = Int(tag.dropFirst(2)), (1...9).contains(value) { alignment = value }
                continue
            }
            if tag.hasPrefix("alpha") { continue }
            switch first {
            case "a":
                if alignment == nil, let value = Int(argument), let mapped = ASSStyle.numpad(fromLegacy: value) { alignment = mapped }
            case "i":
                if tag.hasPrefix("iclip") { break }
                if argument.isEmpty { assItalic = baseStyle.italic } else if let value = Int(argument) { assItalic = value != 0 }
            case "b":
                if tag.hasPrefix("blur") || tag.hasPrefix("be") || tag.hasPrefix("bord") { break }
                if argument.isEmpty {
                    assBold = baseStyle.bold
                } else if let value = Int(argument) {
                    assBold = value == 1 || value >= 600 || (value > 1 && value < 100)
                }
            case "u":
                if argument.isEmpty { assUnderline = baseStyle.underline } else if let value = Int(argument) { assUnderline = value != 0 }
            case "p":
                if tag.hasPrefix("pos") || tag.hasPrefix("pbo") { break }
                if let value = Int(argument) { drawing = value > 0 }
            case "r":
                let style = argument.isEmpty ? baseStyle : (styleNamed(String(argument)) ?? baseStyle)
                assItalic = style.italic
                assBold = style.bold
                assUnderline = style.underline
            default:
                break
            }
        }
        syncStyle()
    }

    private func styleNamed(_ name: String) -> ASSStyle? {
        styles[name] ?? styles.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
    }

    /// MicroDVD control code {k:value} at `i`: {y:i}/{y:b}/{y:u} style the
    /// line, {Y:…} the whole cue; {c:…} {f:…} {s:…} {P:…} {H:…} are dropped.
    private mutating func microDVDCode(_ s: [Unicode.Scalar], _ i: Int) -> Int? {
        guard i + 3 < s.count, s[i + 2] == ":", s[i + 1].isASCII, s[i + 1].properties.isAlphabetic,
              let close = Self.index(of: "}", in: s, from: i + 3, limit: 80) else { return nil }
        let value = String(String.UnicodeScalarView(s[(i + 3)..<close])).lowercased()
        let italic = value.contains("i"), bold = value.contains("b"), underline = value.contains("u")
        switch s[i + 1] {
        case "y":
            lineItalic = lineItalic || italic
            lineBold = lineBold || bold
            lineUnderline = lineUnderline || underline
        case "Y":
            cueItalic = cueItalic || italic
            cueBold = cueBold || bold
            cueUnderline = cueUnderline || underline
        default:
            break
        }
        syncStyle()
        return close + 1
    }

    // MARK: <…> tags

    struct HTMLTag {
        var name: String
        var closing: Bool
        var selfClosing: Bool
    }

    static func htmlTag(_ s: [Unicode.Scalar], _ i: Int) -> (HTMLTag, Int)? {
        var j = i + 1
        guard j < s.count else { return nil }
        var closing = false
        if s[j] == "/" {
            closing = true
            j += 1
        }
        var name = String.UnicodeScalarView()
        while j < s.count, name.count < 40, s[j].isASCII,
              s[j].properties.isAlphabetic || ("0"..."9").contains(s[j]) || s[j] == "." || s[j] == ":" {
            name.append(s[j])
            j += 1
        }
        guard let first = name.first else { return nil }   // "< i>", "<<", "< 3" are text
        var length = 0
        var last: Unicode.Scalar = " "
        while j < s.count, s[j] != ">" {
            if s[j] == "<" || s[j] == "\n" || length > 400 { return nil }
            last = s[j]
            length += 1
            j += 1
        }
        guard j < s.count else { return nil }
        // A digit-led name is only a WebVTT timestamp tag ("<00:01.500>"),
        // never text such as "I <3 you >".
        if ("0"..."9").contains(first) {
            guard !closing, length == 0, name.contains(":") else { return nil }
        }
        return (HTMLTag(name: String(name).lowercased(), closing: closing, selfClosing: last == "/"), j + 1)
    }

    private mutating func handle(_ tag: HTMLTag) -> Bool {
        let base = tag.name.split(separator: ".").first.map(String.init) ?? tag.name
        if let first = base.unicodeScalars.first, ("0"..."9").contains(first) {
            return true   // WebVTT karaoke timestamp <00:01.500>
        }
        func adjust(_ depth: inout Int) {
            if tag.closing { depth = max(0, depth - 1) } else if !tag.selfClosing { depth += 1 }
        }
        switch base {
        case "i", "em": adjust(&htmlItalic)
        case "b", "strong": adjust(&htmlBold)
        case "u", "ins": adjust(&htmlUnderline)
        case "br": lineBreak()
        case "rt", "rp": adjust(&hiddenDepth)
        case "font", "span", "s", "strike", "del", "c", "v", "lang", "ruby", "p", "div", "small", "big",
             "sup", "sub", "center", "a", "html", "body", "head", "title", "sync", "q", "mark", "cite":
            break
        default:
            return false
        }
        syncStyle()
        return true
    }

    // MARK: helpers

    static func index(of target: Unicode.Scalar, in s: [Unicode.Scalar], from start: Int, limit: Int) -> Int? {
        var i = start
        while i < s.count, i - start <= limit {
            if s[i] == target { return i }
            i += 1
        }
        return nil
    }

    static func isBreakTag(_ s: [Unicode.Scalar], _ i: Int) -> Bool {
        guard i + 3 < s.count, s[i + 3] == "]" else { return false }
        return (s[i + 1] == "b" || s[i + 1] == "B") && (s[i + 2] == "r" || s[i + 2] == "R")
    }

    /// HTML semantics: any whitespace run (newlines included) is one space.
    static func collapsingWhitespace(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(s.count)
        var inSpace = false
        for scalar in s {
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                if !inSpace { out.append(" ") }
                inSpace = true
            } else {
                out.append(scalar)
                inSpace = false
            }
        }
        return out
    }
}

/// Styled text runs → WebVTT payload: control characters removed, lines
/// trimmed, blank lines dropped, properly nested <i>/<b>/<u>, `& < >` escaped.
fileprivate struct CueTextBuilder {
    struct Run {
        var text: String.UnicodeScalarView
        var italic: Bool
        var bold: Bool
        var underline: Bool
    }

    var italic = false
    var bold = false
    var underline = false
    private var runs: [Run] = []

    mutating func append(_ scalar: Unicode.Scalar) {
        if let last = runs.last, last.italic == italic, last.bold == bold, last.underline == underline {
            runs[runs.count - 1].text.append(scalar)
        } else {
            var text = String.UnicodeScalarView()
            text.append(scalar)
            runs.append(Run(text: text, italic: italic, bold: bold, underline: underline))
        }
    }

    func render() -> String {
        var lines: [[Run]] = [[]]
        for run in runs {
            var piece = String.UnicodeScalarView()
            func push() {
                if !piece.isEmpty {
                    lines[lines.count - 1].append(Run(text: piece, italic: run.italic, bold: run.bold, underline: run.underline))
                    piece = String.UnicodeScalarView()
                }
            }
            for scalar in run.text {
                if scalar == "\n" {
                    push()
                    lines.append([])
                } else if scalar == "\t" {
                    piece.append(" ")
                } else if !Self.isControl(scalar) {
                    piece.append(scalar)
                }
            }
            push()
        }
        var kept: [[Run]] = []
        for var line in lines {
            while let first = line.first {
                let trimmed = String.UnicodeScalarView(first.text.drop(while: Self.isSpace))
                if trimmed.isEmpty { line.removeFirst() } else { line[0].text = trimmed; break }
            }
            while let last = line.last {
                var text = last.text
                while let scalar = text.last, Self.isSpace(scalar) { text.removeLast() }
                if text.isEmpty { line.removeLast() } else { line[line.count - 1].text = text; break }
            }
            if !line.isEmpty { kept.append(line) }
        }
        var out = ""
        var open: [String] = []
        for (index, line) in kept.enumerated() {
            for (position, run) in line.enumerated() {
                var wanted: [String] = []
                if run.italic { wanted.append("i") }
                if run.bold { wanted.append("b") }
                if run.underline { wanted.append("u") }
                var keep = 0
                while keep < open.count, wanted.contains(open[keep]) { keep += 1 }
                // Close before the line break, open after it: "<i>a</i>\nb".
                while open.count > keep { out += "</" + open.removeLast() + ">" }
                if position == 0, index > 0 { out += "\n" }
                for tag in wanted where !open.contains(tag) {
                    out += "<" + tag + ">"
                    open.append(tag)
                }
                out += SubtitleText.escape(String(run.text))
            }
        }
        while let tag = open.popLast() { out += "</" + tag + ">" }
        return out
    }

    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || scalar == "\u{200B}"
    }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) || v == 0xFEFF || v == 0xFFFE || v == 0xFFFF
    }
}

// MARK: - Text decoding

fileprivate enum SubtitleTextDecoder {

    typealias Encoding = UInt32   // CFStringEncoding

    // CFStringEncoding values (CFStringEncodingExt.h).
    static let windows1252: Encoding = 0x0500
    static let windows1250: Encoding = 0x0501
    static let windows1251: Encoding = 0x0502
    static let windows1253: Encoding = 0x0503
    static let windows1254: Encoding = 0x0504
    static let windows1255: Encoding = 0x0505
    static let windows1256: Encoding = 0x0506
    static let windows1257: Encoding = 0x0507
    static let windows1258: Encoding = 0x0508
    static let windows874: Encoding = 0x041D    // DOSThai: TIS-620 + Windows punctuation
    static let windows932: Encoding = 0x0420    // DOSJapanese: Shift_JIS superset
    static let windows949: Encoding = 0x0422    // DOSKorean: UHC, EUC-KR superset
    static let windows950: Encoding = 0x0423    // DOSChineseTrad: Big5 + Microsoft extensions
    static let isoLatin1: Encoding = 0x0201
    static let isoLatin2: Encoding = 0x0202
    static let isoGreek: Encoding = 0x0207
    static let isoHebrew: Encoding = 0x0208
    static let gb18030: Encoding = 0x0632       // GB2312 / GBK superset
    static let big5HKSCS: Encoding = 0x0A06
    static let eucJP: Encoding = 0x0920
    static let eucKR: Encoding = 0x0940
    static let koi8R: Encoding = 0x0A02
    static let koi8U: Encoding = 0x0A08
    static let viscii: Encoding = 0x0A07
    static let iso2022JP: Encoding = 0x0820
    static let iso2022CN: Encoding = 0x0830
    static let iso2022KR: Encoding = 0x0840
    static let hzGB2312: Encoding = 0x0A05
    static let utf8: Encoding = 0x0800_0100
    static let sevenBitStateful: Set<Encoding> = [0x0820, 0x0821, 0x0822, 0x0823, 0x0830, 0x0831, 0x0840, 0x0A05]
    static let unicodeForms: Set<Encoding> = [0x0100, 0x1000_0100, 0x1400_0100, 0x0C00_0100, 0x1800_0100, 0x1C00_0100]

    static func decode(_ input: [UInt8], encodingHint: String?, languageHint: String?) -> String {
        guard !input.isEmpty else { return "" }
        let b = input
        let hint = resolve(encodingHint)
        let language = Language(languageHint)
        // 1. Byte order marks (UTF-32 before UTF-16: FF FE 00 00 starts both).
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF {
            var body = Array(b[3...])
            while body.last == 0 { body.removeLast() }
            return finish(utf8Stats(body).invalid == 0
                          ? String(decoding: body, as: UTF8.self)
                          : mixedUTF8Lines(body, hint: hint, language: language))
        }
        if b.count >= 4, b[0] == 0xFF, b[1] == 0xFE, b[2] == 0, b[3] == 0 { return finish(utf32(b[4...], bigEndian: false)) }
        if b.count >= 4, b[0] == 0, b[1] == 0, b[2] == 0xFE, b[3] == 0xFF { return finish(utf32(b[4...], bigEndian: true)) }
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE { return finish(utf16(b[2...], bigEndian: false)) }
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF { return finish(utf16(b[2...], bigEndian: true)) }
        // 2. UTF-16 without BOM: ASCII characters leave a NUL every other byte.
        if let bigEndian = utf16WithoutBOM(b) { return finish(utf16(b[...], bigEndian: bigEndian)) }

        // 8-bit encodings from here on; zero padding at the end is not text.
        var bytes = b
        while bytes.last == 0 { bytes.removeLast() }
        guard !bytes.isEmpty else { return "" }

        // 3. 7-bit stateful encodings (ISO-2022-*, HZ) are valid ASCII/UTF-8.
        if !bytes.contains(where: { $0 >= 0x80 }) {
            if case .encoding(let encoding) = hint, sevenBitStateful.contains(encoding),
               bytes.contains(0x1B) || bytes.contains(0x7E), let text = cfDecode(bytes, encoding) {
                return finish(text)
            }
            if let encoding = iso2022Signature(bytes), let text = cfDecode(bytes, encoding) { return finish(text) }
        }

        // 4. Strict UTF-8; then UTF-8 files with some legacy lines (OpenSubtitles
        //    injects its ad lines in the declared code page into UTF-8 files;
        //    concatenated files). Lines of legacy text practically never form
        //    valid multi-byte UTF-8, so counting lines is a safe vote.
        let lines = utf8LineStats(bytes)
        if lines.invalidLines == 0 { return finish(String(decoding: bytes, as: UTF8.self)) }
        if lines.utf8Lines >= 1, lines.utf8Lines >= lines.invalidLines {
            return finish(mixedUTF8Lines(bytes, hint: hint, language: language))
        }

        // 5. The hint (OpenSubtitles SubEncoding).
        if case .encoding(let encoding) = hint, let text = decode(bytes, as: encoding) {
            return finish(languageOverride(text, hintEncoding: encoding, bytes: bytes, language: language) ?? text)
        }

        // 6. The usual code pages of the language.
        if let text = decodeForLanguage(bytes, language) { return finish(text) }

        // 7. Windows-1252, then ISO Latin-1.
        if let table = cache.table(windows1252) { return finish(tableDecode(bytes, table)) }
        return finish(cfDecode(bytes, isoLatin1) ?? String(decoding: bytes, as: UTF8.self))
    }

    private static func finish(_ text: String) -> String {
        var s = text
        if s.unicodeScalars.first == "\u{FEFF}" { s.unicodeScalars.removeFirst() }
        return s.precomposedStringWithCanonicalMapping
    }

    // MARK: Hint names

    enum Hint { case unspecified, utf8, encoding(Encoding) }

    /// OpenSubtitles / IANA / Windows charset names → encoding.
    static func resolve(_ name: String?) -> Hint {
        guard let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return .unspecified }
        let key = String(raw.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) })
        if let hint = resolveKey(key) { return hint }
        if key.hasPrefix("x"), key.count > 1, let hint = resolveKey(String(key.dropFirst())) { return hint }   // "x-cp1251"
        let encoding = CFStringConvertIANACharSetNameToEncoding(raw as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return .unspecified }
        if encoding == utf8 { return .utf8 }
        if unicodeForms.contains(encoding) { return .unspecified }   // real UTF-16/32 was caught by BOM / NUL detection
        return .encoding(encoding)
    }

    private static func resolveKey(_ key: String) -> Hint? {
        switch key {
        case "utf8", "utf8bom", "unicode11utf8":
            return .utf8
        case "ascii", "usascii", "ansix341968", "iso646us", "us", "unknown", "auto", "default", "none", "binary":
            return .unspecified
        case "utf16", "utf16le", "utf16be", "ucs2", "ucs2le", "ucs2be", "unicode", "utf32", "utf32le", "utf32be":
            return .unspecified
        case "gb2312", "gbk", "gb18030", "cp936", "ms936", "windows936", "euccn", "csgb2312", "gb231280", "chinese":
            return .encoding(gb18030)
        case "big5", "big5hkscs", "cp950", "ms950", "windows950", "cnbig5", "csbig5":
            return .encoding(windows950)
        case "shiftjis", "sjis", "cp932", "ms932", "windows932", "windows31j", "mskanji", "csshiftjis", "cswindows31j":
            return .encoding(windows932)
        case "eucjp", "ujis", "cseucpkdfmtjapanese":
            return .encoding(eucJP)
        case "euckr", "cp949", "ms949", "windows949", "uhc", "ksc5601", "ksc56011987", "cseuckr", "korean":
            return .encoding(windows949)
        case "koi8r", "koi8", "cskoi8r":
            return .encoding(koi8R)
        case "koi8u", "koi8ru":
            return .encoding(koi8U)
        case "tis620", "tis6202533", "cp874", "ms874", "windows874", "iso885911", "thai":
            return .encoding(windows874)
        case "latin1", "l1", "iso88591", "cp819", "ibm819", "cp1252", "windows1252", "ms1252", "win1252", "ansi":
            return .encoding(windows1252)   // Latin-1 text reads the same; 0x80–0x9F gain Windows punctuation
        case "viscii", "csviscii":
            return .encoding(viscii)
        case "iso2022jp", "csiso2022jp": return .encoding(iso2022JP)
        case "iso2022jp2": return .encoding(0x0821)
        case "iso2022kr", "csiso2022kr": return .encoding(iso2022KR)
        case "iso2022cn": return .encoding(iso2022CN)
        case "iso2022cnext": return .encoding(0x0831)
        case "hzgb2312", "hz": return .encoding(hzGB2312)
        default:
            break
        }
        for prefix in ["windows", "win", "cp", "ms", "ibm", "dos", ""] where key.hasPrefix(prefix) {
            guard let number = Int(key.dropFirst(prefix.count)) else { continue }
            switch number {
            case 1252: return .encoding(windows1252)
            case 1250: return .encoding(windows1250)
            case 1251: return .encoding(windows1251)
            case 1253...1258: return .encoding(windows1253 + Encoding(number - 1253))
            case 874: return .encoding(windows874)
            case 932: return .encoding(windows932)
            case 936: return .encoding(gb18030)
            case 949: return .encoding(windows949)
            case 950: return .encoding(windows950)
            case 437: return .encoding(0x0400)
            case 737: return .encoding(0x0405)
            case 775: return .encoding(0x0406)
            case 850: return .encoding(0x0410)
            case 852: return .encoding(0x0412)
            case 855: return .encoding(0x0413)
            case 857: return .encoding(0x0414)
            case 860: return .encoding(0x0415)
            case 861: return .encoding(0x0416)
            case 862: return .encoding(0x0417)
            case 863: return .encoding(0x0418)
            case 864: return .encoding(0x0419)
            case 865: return .encoding(0x041A)
            case 866: return .encoding(0x041B)
            case 869: return .encoding(0x041C)
            default: continue
            }
        }
        if key.hasPrefix("iso8859"), let part = Int(key.dropFirst(7)) {
            switch part {
            case 1: return .encoding(windows1252)
            case 9: return .encoding(windows1254)
            case 11: return .encoding(windows874)
            case 2...8, 10, 13...16: return .encoding(0x0200 + Encoding(part))
            default: break
            }
        }
        if key.hasPrefix("latin"), let part = Int(key.dropFirst(5)) {
            switch part {
            case 1: return .encoding(windows1252)
            case 2, 3, 4: return .encoding(0x0200 + Encoding(part))
            case 5: return .encoding(windows1254)
            case 6: return .encoding(0x020A)
            case 7, 8, 9, 10: return .encoding(0x0206 + Encoding(part))
            default: break
            }
        }
        return nil
    }

    // MARK: Languages

    enum Script: UInt8 {
        case latin = 1, greek = 2, cyrillic = 4, hebrew = 8, arabic = 16, thai = 32, cjk = 64, other = 128
    }

    struct Candidate {
        let encoding: Encoding
        let script: Script
    }

    /// Code pages subtitle files of a language are usually written in, most
    /// likely first.
    struct Language {
        private(set) var candidates: [Candidate] = []
        private(set) var isCJK = false
        private(set) var traditionalChinese = false

        private static let aliases: [String: String] = [
            "rus": "ru", "ukr": "uk", "bel": "be", "bul": "bg", "mkd": "mk", "mac": "mk", "kaz": "kk", "kir": "ky",
            "tgk": "tg", "mon": "mn", "tat": "tt", "bak": "ba", "srp": "sr", "scc": "sr", "hrv": "hr", "scr": "hr",
            "bos": "bs", "hbs": "sh", "ara": "ar", "per": "fa", "fas": "fa", "urd": "ur", "pus": "ps", "uig": "ug",
            "snd": "sd", "gre": "el", "ell": "el", "heb": "he", "iw": "he", "yid": "yi", "ji": "yi", "tur": "tr",
            "aze": "az", "pol": "pl", "cze": "cs", "ces": "cs", "slo": "sk", "slk": "sk", "hun": "hu", "rum": "ro",
            "ron": "ro", "mol": "ro", "slv": "sl", "alb": "sq", "sqi": "sq", "est": "et", "lav": "lv", "lit": "lt",
            "vie": "vi", "tha": "th", "chi": "zh", "zho": "zh", "jpn": "ja", "kor": "ko",
        ]

        init(_ hint: String?) {
            guard let raw = hint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return }
            let parts = raw.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
            guard var code = parts.first else { return }
            let subtags = Set(parts.dropFirst())
            // OpenSubtitles: "zt"/"zht" Chinese (traditional), "ze"/"zhe" bilingual.
            traditionalChinese = code == "zt" || code == "zht" || !subtags.isDisjoint(with: ["tw", "hk", "mo", "hant"])
            if ["zt", "zht", "ze", "zhe"].contains(code) { code = "zh" }
            code = Self.aliases[code] ?? code
            func c(_ encoding: Encoding, _ script: Script) -> Candidate { Candidate(encoding: encoding, script: script) }
            switch code {
            case "ru", "be": candidates = [c(windows1251, .cyrillic), c(koi8R, .cyrillic)]
            case "uk": candidates = [c(windows1251, .cyrillic), c(koi8U, .cyrillic)]
            case "bg", "mk", "kk", "ky", "tg", "mn", "tt", "ba": candidates = [c(windows1251, .cyrillic)]
            case "sr": candidates = [c(windows1251, .cyrillic), c(windows1250, .latin)]
            case "bs", "sh": candidates = [c(windows1250, .latin), c(windows1251, .cyrillic)]
            case "pl", "cs", "sk", "hu", "hr", "sl": candidates = [c(windows1250, .latin), c(isoLatin2, .latin)]
            case "ro", "sq": candidates = [c(windows1250, .latin)]
            case "ar", "fa", "ur", "ps", "ug", "sd": candidates = [c(windows1256, .arabic)]
            case "el": candidates = [c(windows1253, .greek), c(isoGreek, .greek)]
            case "he", "yi": candidates = [c(windows1255, .hebrew), c(isoHebrew, .hebrew)]
            case "tr", "az": candidates = [c(windows1254, .latin)]
            case "et", "lv", "lt": candidates = [c(windows1257, .latin)]
            case "vi": candidates = [c(windows1258, .latin), c(viscii, .latin)]
            case "th": candidates = [c(windows874, .thai)]
            case "zh":
                isCJK = true
                let simplified = [c(gb18030, .cjk)], traditional = [c(windows950, .cjk), c(big5HKSCS, .cjk)]
                candidates = traditionalChinese ? traditional + simplified : simplified + traditional
            case "ja": isCJK = true; candidates = [c(windows932, .cjk), c(eucJP, .cjk)]
            case "ko": isCJK = true; candidates = [c(windows949, .cjk), c(eucKR, .cjk)]
            default: break
            }
        }

        /// zh without an explicit variant: Big5 trail bytes 0x40–0x7E never
        /// occur in GB2312 text, so their share decides which family goes first.
        func ordered(_ bytes: [UInt8]) -> [Candidate] {
            guard candidates.contains(where: { $0.encoding == gb18030 }), !traditionalChinese else { return candidates }
            var pairs = 0, lowTrail = 0, i = 0
            while i + 1 < bytes.count {
                if bytes[i] >= 0x81 && bytes[i] <= 0xFE {
                    pairs += 1
                    if bytes[i + 1] >= 0x40 && bytes[i + 1] <= 0x7E { lowTrail += 1 }
                    i += 2
                } else {
                    i += 1
                }
            }
            guard pairs > 0, Double(lowTrail) / Double(pairs) > 0.05 else { return candidates }
            return candidates.filter { $0.encoding != gb18030 } + candidates.filter { $0.encoding == gb18030 }
        }
    }

    /// Second-guess a single-byte hint only when it reads as no text of the
    /// hinted language at all (and a code page of that language reads well).
    static func languageOverride(_ hinted: String, hintEncoding: Encoding, bytes: [UInt8], language: Language) -> String? {
        guard !language.candidates.isEmpty,
              !language.candidates.contains(where: { $0.encoding == hintEncoding }),
              cache.table(hintEncoding) != nil else { return nil }
        let scripts = Set(language.candidates.map(\.script))
        let hintScore = scripts.map { plausibility(hinted, expected: $0) }.max() ?? 1
        guard hintScore < 0.3 else { return nil }
        if language.isCJK {
            for candidate in language.ordered(bytes) {
                if let text = cfDecode(bytes, candidate.encoding) { return text }
            }
            return nil
        }
        guard let best = bestSingleByte(bytes, language.candidates), best.score > 0.7 else { return nil }
        return best.text
    }

    static func decodeForLanguage(_ bytes: [UInt8], _ language: Language) -> String? {
        guard !language.candidates.isEmpty else { return nil }
        if language.isCJK {
            let ordered = language.ordered(bytes)
            for candidate in ordered {
                if let text = cfDecode(bytes, candidate.encoding) { return text }
            }
            var best: (text: String, ratio: Double)?
            for candidate in ordered {
                let attempt = tolerantDecode(bytes, candidate.encoding)
                if attempt.ratio > (best?.ratio ?? 0) { best = attempt }
            }
            return best.flatMap { $0.ratio >= 0.5 ? $0.text : nil }
        }
        guard let best = bestSingleByte(bytes, language.candidates) else { return nil }
        // A wrong language hint must not beat Windows-1252 when that clearly reads better.
        if let table = cache.table(windows1252) {
            let western = tableDecode(bytes, table)
            if plausibility(western, expected: .latin) > best.score + 0.3 { return western }
        }
        return best.text
    }

    static func bestSingleByte(_ bytes: [UInt8], _ candidates: [Candidate]) -> (text: String, score: Double)? {
        var best: (text: String, score: Double)?
        for candidate in candidates {
            guard let table = cache.table(candidate.encoding) else { continue }
            let text = tableDecode(bytes, table)
            let score = plausibility(text, expected: candidate.script)
            if best == nil || score > best!.score + 0.02 { best = (text, score) }
        }
        return best
    }

    /// 0…1: how much `text` looks like real text in `expected` script —
    /// single-script words, letters of that script, mostly lower case, no
    /// C1 controls / replacement characters / symbols glued inside words
    /// ("w³asny" = Polish read as CP1252). Wrong code pages score near 0.
    static func plausibility(_ text: String, expected: Script) -> Double {
        var nonASCII = 0, matching = 0, asciiLetters = 0, lower = 0, cased = 0, suspicious = 0
        var words = 0, impureWords = 0
        var wordMask: UInt8 = 0
        var wordHasNonASCII = false
        var previousWasLetter = false
        var pendingSymbol = false
        func closeWord() {
            if wordHasNonASCII {
                words += 1
                if wordMask & (wordMask &- 1) != 0 { impureWords += 1 }
            }
            wordMask = 0
            wordHasNonASCII = false
        }
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let properties = scalar.properties
            if properties.isAlphabetic {
                if pendingSymbol { suspicious += 1; pendingSymbol = false }
                let script = Self.script(of: v)
                wordMask |= script.rawValue
                if v < 0x80 {
                    asciiLetters += 1
                } else {
                    nonASCII += 1
                    wordHasNonASCII = true
                    if script == expected { matching += 1 }
                    if properties.isLowercase { lower += 1; cased += 1 } else if properties.isUppercase { cased += 1 }
                }
                previousWasLetter = true
                continue
            }
            switch properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: continue   // diacritics stay in the word
            default: break
            }
            if (0x80...0x9F).contains(v) || v == 0xFFFD || (0xE000...0xF8FF).contains(v) { suspicious += 1 }
            // Latin-1 symbols glued between letters ("w³asny"); the ones no
            // language writes against a letter ("¶λφα", "gęśl±") count on
            // either side. « » ¡ ¿ ° stay innocent at word edges.
            let strong = Self.gluedSymbols.contains(v)
            if strong && previousWasLetter {
                suspicious += 1
                pendingSymbol = false
            } else {
                pendingSymbol = (0xA1...0xBF).contains(v) && v != 0xAB && v != 0xBB && (previousWasLetter || strong)
            }
            previousWasLetter = false
            closeWord()
        }
        closeWord()
        let evidence = nonASCII + suspicious
        guard evidence > 0 else { return 1 }
        let purity = words == 0 || expected == .cjk ? 1 : Double(words - impureWords) / Double(words)
        var fit = Double(matching) / Double(max(1, nonASCII))
        if expected == .latin {
            fit *= min(1, Double(asciiLetters) / Double(max(1, asciiLetters + nonASCII)) / 0.5)
        }
        let caseFit = cased == 0 ? 1 : 0.75 + 0.25 * Double(lower) / Double(cased)
        let penalty = min(1, 5 * Double(suspicious) / Double(evidence))
        return purity * fit * caseFit * (1 - penalty)
    }

    /// ¤ ¥ ¦ ¬ ¯ ± ¶ ¹ ¼ ½ ¾ — typical of a byte read in the wrong code page.
    static let gluedSymbols: Set<UInt32> = [0xA4, 0xA5, 0xA6, 0xAC, 0xAF, 0xB1, 0xB6, 0xB9, 0xBC, 0xBD, 0xBE]

    static func script(of v: UInt32) -> Script {
        switch v {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: return .latin
        case 0x370...0x3FF, 0x1F00...0x1FFF: return .greek
        case 0x400...0x52F: return .cyrillic
        case 0x590...0x5FF, 0xFB1D...0xFB4F: return .hebrew
        case 0x600...0x6FF, 0x750...0x77F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
        case 0xE00...0xE7F: return .thai
        case 0x3040...0x30FF, 0x3400...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x1100...0x11FF, 0x3130...0x318F: return .cjk
        default: return .other
        }
    }

    // MARK: Decoders

    /// Single-byte encodings through a 256-entry table (undefined bytes are
    /// dropped instead of failing the whole file); multi-byte ones strictly,
    /// accepting a file where ≥ 90 % of the lines decode.
    static func decode(_ bytes: [UInt8], as encoding: Encoding) -> String? {
        if let table = cache.table(encoding) { return tableDecode(bytes, table) }
        if let text = cfDecode(bytes, encoding) { return text }
        let attempt = tolerantDecode(bytes, encoding)
        return attempt.ratio >= 0.9 ? attempt.text : nil
    }

    static func cfDecode(_ bytes: [UInt8], _ encoding: Encoding) -> String? {
        guard !bytes.isEmpty else { return "" }
        return bytes.withUnsafeBufferPointer { buffer -> String? in
            guard let string = CFStringCreateWithBytes(kCFAllocatorDefault, buffer.baseAddress, buffer.count, encoding, false) else { return nil }
            return string as String
        }
    }

    /// Line by line (LF never occurs inside a GBK/Big5/Shift_JIS/EUC/UHC
    /// character); a line that fails keeps only its ASCII (timings).
    static func tolerantDecode(_ bytes: [UInt8], _ encoding: Encoding) -> (text: String, ratio: Double) {
        var out = ""
        var withText = 0, good = 0
        for (index, line) in bytes.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
            if index > 0 { out += "\n" }
            let chunk = Array(line)
            let hasHigh = chunk.contains(where: { $0 >= 0x80 })
            if hasHigh { withText += 1 }
            if let text = cfDecode(chunk, encoding) {
                out += text
                if hasHigh { good += 1 }
            } else {
                out += String(decoding: chunk.filter { $0 < 0x80 }, as: UTF8.self)
            }
        }
        return (out, withText == 0 ? 1 : Double(good) / Double(withText))
    }

    static func tableDecode(_ bytes: [UInt8], _ table: [Unicode.Scalar?]) -> String {
        var view = String.UnicodeScalarView()
        view.reserveCapacity(bytes.count)
        for byte in bytes {
            if let scalar = table[Int(byte)] { view.append(scalar) }
        }
        return String(view)
    }

    /// Length of the valid UTF-8 sequence at `i` (RFC 3629), 0 when invalid.
    static func utf8SequenceLength(_ b: [UInt8], _ i: Int) -> Int {
        let n = b.count
        let c0 = b[i]
        if c0 < 0x80 { return 1 }
        func continuation(_ k: Int, _ low: UInt8 = 0x80, _ high: UInt8 = 0xBF) -> Bool {
            k < n && b[k] >= low && b[k] <= high
        }
        switch c0 {
        case 0xC2...0xDF: return continuation(i + 1) ? 2 : 0
        case 0xE0: return continuation(i + 1, 0xA0) && continuation(i + 2) ? 3 : 0
        case 0xE1...0xEC, 0xEE...0xEF: return continuation(i + 1) && continuation(i + 2) ? 3 : 0
        case 0xED: return continuation(i + 1, 0x80, 0x9F) && continuation(i + 2) ? 3 : 0
        case 0xF0: return continuation(i + 1, 0x90) && continuation(i + 2) && continuation(i + 3) ? 4 : 0
        case 0xF1...0xF3: return continuation(i + 1) && continuation(i + 2) && continuation(i + 3) ? 4 : 0
        case 0xF4: return continuation(i + 1, 0x80, 0x8F) && continuation(i + 2) && continuation(i + 3) ? 4 : 0
        default: return 0
        }
    }

    static func utf8Stats(_ b: [UInt8]) -> (multiByte: Int, invalid: Int) {
        var multiByte = 0, invalid = 0, i = 0
        while i < b.count {
            if b[i] < 0x80 { i += 1; continue }
            let length = utf8SequenceLength(b, i)
            if length == 0 {
                invalid += 1
                i += 1
            } else {
                multiByte += 1
                i += length
            }
        }
        return (multiByte, invalid)
    }

    /// Lines that contain multi-byte UTF-8 and no invalid sequence, and lines
    /// with at least one invalid sequence.
    static func utf8LineStats(_ b: [UInt8]) -> (utf8Lines: Int, invalidLines: Int) {
        var utf8Lines = 0, invalidLines = 0
        var lineMulti = false, lineInvalid = false
        var i = 0
        while i <= b.count {
            if i == b.count || b[i] == 0x0A {
                if lineInvalid { invalidLines += 1 } else if lineMulti { utf8Lines += 1 }
                lineMulti = false
                lineInvalid = false
                i += 1
                continue
            }
            if b[i] < 0x80 { i += 1; continue }
            let length = utf8SequenceLength(b, i)
            if length == 0 {
                lineInvalid = true
                i += 1
            } else {
                lineMulti = true
                i += length
            }
        }
        return (utf8Lines, invalidLines)
    }

    /// Mostly-UTF-8 text decoded line by line: UTF-8 lines as UTF-8, a UTF-8
    /// line with a few stray bytes byte by byte, any other line with the
    /// hinted / language code page (Windows-1252 last).
    static func mixedUTF8Lines(_ b: [UInt8], hint: Hint, language: Language) -> String {
        var legacy: [Encoding] = []
        if case .encoding(let encoding) = hint { legacy.append(encoding) }
        legacy += language.ordered(b).map(\.encoding)
        legacy.append(windows1252)
        let byteTable = legacy.lazy.compactMap { cache.table($0) }.first ?? []
        var out = ""
        for (index, line) in b.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
            if index > 0 { out += "\n" }
            let chunk = Array(line)
            let stats = utf8Stats(chunk)
            if stats.invalid == 0 {
                out += String(decoding: chunk, as: UTF8.self)
            } else if stats.multiByte > 0, stats.invalid <= stats.multiByte {
                out += mixedUTF8(chunk, fallback: byteTable)
            } else {
                var decoded: String?
                for encoding in legacy {
                    if let table = cache.table(encoding) {
                        decoded = tableDecode(chunk, table)
                    } else {
                        decoded = cfDecode(chunk, encoding)
                    }
                    if decoded != nil { break }
                }
                out += decoded ?? mixedUTF8(chunk, fallback: byteTable)
            }
        }
        return out
    }

    /// UTF-8, with every invalid byte read through `fallback` instead.
    static func mixedUTF8(_ b: [UInt8], fallback: [Unicode.Scalar?]) -> String {
        var view = String.UnicodeScalarView()
        view.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            let length = utf8SequenceLength(b, i)
            guard length > 0 else {
                if Int(b[i]) < fallback.count, let scalar = fallback[Int(b[i])] { view.append(scalar) }
                i += 1
                continue
            }
            let value: UInt32
            switch length {
            case 1: value = UInt32(b[i])
            case 2: value = (UInt32(b[i]) & 0x1F) << 6 | (UInt32(b[i + 1]) & 0x3F)
            case 3: value = (UInt32(b[i]) & 0x0F) << 12 | (UInt32(b[i + 1]) & 0x3F) << 6 | (UInt32(b[i + 2]) & 0x3F)
            default:
                value = (UInt32(b[i]) & 0x07) << 18 | (UInt32(b[i + 1]) & 0x3F) << 12
                    | (UInt32(b[i + 2]) & 0x3F) << 6 | (UInt32(b[i + 3]) & 0x3F)
            }
            if let scalar = Unicode.Scalar(value) { view.append(scalar) }
            i += length
        }
        return String(view)
    }

    static func utf16(_ bytes: ArraySlice<UInt8>, bigEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = bytes.startIndex
        while i + 1 < bytes.endIndex {
            let a = UInt16(bytes[i]), b = UInt16(bytes[i + 1])
            units.append(bigEndian ? (a << 8 | b) : (b << 8 | a))
            i += 2
        }
        while units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    static func utf32(_ bytes: ArraySlice<UInt8>, bigEndian: Bool) -> String {
        var view = String.UnicodeScalarView()
        var i = bytes.startIndex
        while i + 3 < bytes.endIndex {
            let b0 = UInt32(bytes[i]), b1 = UInt32(bytes[i + 1]), b2 = UInt32(bytes[i + 2]), b3 = UInt32(bytes[i + 3])
            let value = bigEndian ? (b0 << 24 | b1 << 16 | b2 << 8 | b3) : (b3 << 24 | b2 << 16 | b1 << 8 | b0)
            if value != 0 { view.append(Unicode.Scalar(value) ?? "\u{FFFD}") }
            i += 4
        }
        return String(view)
    }

    /// true = big-endian, false = little-endian, nil = not UTF-16.
    static func utf16WithoutBOM(_ b: [UInt8]) -> Bool? {
        let n = min(b.count, 8192) & ~1
        guard n >= 16 else { return nil }
        var zeroEven = 0, zeroOdd = 0, i = 0
        while i < n {
            if b[i] == 0 { zeroEven += 1 }
            if b[i + 1] == 0 { zeroOdd += 1 }
            i += 2
        }
        let pairs = n / 2
        if zeroOdd * 10 >= pairs * 3, zeroEven * 20 <= pairs { return false }
        if zeroEven * 10 >= pairs * 3, zeroOdd * 20 <= pairs { return true }
        return nil
    }

    /// ESC sequences that designate ISO-2022 character sets.
    static func iso2022Signature(_ b: [UInt8]) -> Encoding? {
        var i = 0
        while i + 3 < b.count {
            if b[i] == 0x1B {
                let a = b[i + 1], c = b[i + 2], d = b[i + 3]
                if a == 0x24, c == 0x42 || c == 0x40 || c == 0x28 { return iso2022JP }   // ESC $ B, ESC $ @, ESC $ ( D
                if a == 0x24, c == 0x29, d == 0x43 { return iso2022KR }                   // ESC $ ) C
                if a == 0x24, c == 0x29, d == 0x41 || d == 0x47 { return iso2022CN }      // ESC $ ) A / G
            }
            i += 1
        }
        return nil
    }

    // MARK: Single-byte tables

    final class TableCache: @unchecked Sendable {
        private let lock = NSLock()
        private var tables: [Encoding: [Unicode.Scalar?]] = [:]
        private var multiByte: Set<Encoding> = []

        /// 256-entry table for a single-byte encoding, nil for multi-byte ones.
        func table(_ encoding: Encoding) -> [Unicode.Scalar?]? {
            lock.lock()
            defer { lock.unlock() }
            if let table = tables[encoding] { return table }
            // Stateful 7-bit encodings (ISO-2022-*, HZ) must go through CF as a whole.
            if multiByte.contains(encoding) || SubtitleTextDecoder.sevenBitStateful.contains(encoding)
                || encoding == SubtitleTextDecoder.utf8 || SubtitleTextDecoder.unicodeForms.contains(encoding) { return nil }
            var table = [Unicode.Scalar?](repeating: nil, count: 256)
            var highDecoded = 0
            for value in 0..<256 {
                var byte = UInt8(value)
                if let string = CFStringCreateWithBytes(kCFAllocatorDefault, &byte, 1, encoding, false) {
                    let scalars = (string as String).unicodeScalars
                    if scalars.count == 1, let scalar = scalars.first {
                        table[value] = scalar
                        if value >= 0x80 { highDecoded += 1 }
                    }
                }
                if table[value] == nil, value < 0x80 { table[value] = Unicode.Scalar(UInt8(value)) }
            }
            // Lead bytes of multi-byte encodings don't decode on their own
            // (CP932 ≈ 63 lone bytes, GB18030/Big5/EUC ≈ 0); single-byte
            // code pages decode ≥ 90 of 128 (ISO-8859-8 has the most holes).
            guard highDecoded >= 80 else {
                multiByte.insert(encoding)
                return nil
            }
            tables[encoding] = table
            return table
        }
    }

    static let cache = TableCache()
}
