// HomeSettingsModel.swift — the Home's settings as a settings screen lists
// them (iOS and macOS): the content languages and the shelves that can be
// hidden. No SwiftUI: the rows and what a tap changes are decided here
// (unit-tested), on PopcornKit's `HomeSettings` — the same stored values on
// every platform.
import Foundation
import PopcornKit

struct HomeSettingsModel {
    let settings: HomeSettings
    /// Names the languages.
    var locale: Locale = .current
    var text = HomeCardText()

    // MARK: Content languages

    struct Language: Identifiable, Equatable {
        /// ISO 639-1 code.
        let id: String
        /// In the app's language, capitalised as a list entry ("Français").
        let name: String
        let isOn: Bool
    }

    /// The original languages the sources carry most (YTS's additions and
    /// TVMaze's schedules of November 2026), English and French first: the
    /// ones offered. A stored language that is not one of them is listed too.
    static let offeredLanguages = ["en", "fr", "es", "de", "it", "pt", "ja", "ko", "zh", "hi", "ru", "ar",
                                   "tr", "nl", "sv", "da", "no", "pl", "th", "ta", "te"]

    /// Every language keeps its titles: nothing is filtered.
    var showsEveryLanguage: Bool {
        settings.contentLanguages.isEmpty
    }

    /// The languages to tick, by name. All unticked while every language
    /// shows (the switch above them says so).
    var languages: [Language] {
        let chosen = settings.contentLanguages
        var codes = HomeSettingsModel.offeredLanguages
        for code in chosen where !codes.contains(code) { codes.append(code) }
        let rows = codes.map { code in
            Language(id: code, name: name(of: code), isOn: chosen.contains(code))
        }
        return rows.sorted { $0.name.compare($1.name, locale: locale) == .orderedAscending }
    }

    /// "Français, Anglais": the choice in one line, for the row that opens
    /// the list. Nil while every language shows.
    var languageSummary: String? {
        let chosen = settings.contentLanguages
        guard !chosen.isEmpty else { return nil }
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: chosen.map(name(of:)))
    }

    private func name(of code: String) -> String {
        let name = locale.localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// On: every language (the stored list is emptied). Off: back to the
    /// default choice — English, French and the device's language.
    func setShowsEveryLanguage(_ on: Bool) {
        if on {
            settings.contentLanguages = []
        } else {
            settings.resetContentLanguages()
        }
    }

    /// Ticks or unticks a language. The last one stays ticked: an empty
    /// list means "every language", which is the switch's to say.
    func toggleLanguage(_ code: String) {
        var chosen = settings.contentLanguages
        if let index = chosen.firstIndex(of: code) {
            guard chosen.count > 1 else { return }
            chosen.remove(at: index)
        } else {
            chosen.append(code)
        }
        settings.contentLanguages = chosen
    }

    // MARK: Shelves

    struct Shelf: Identifiable, Equatable {
        let id: String
        let title: String
        let isShown: Bool
    }

    /// The shelves a user can hide, in the page's order: the fixed ones —
    /// the « Services » row under Continue Watching only once there is a
    /// TMDB key, as on the Apple TV (`StreamingSettingsStore.shelves`;
    /// hidden, the page is the usual one) — then the genre shelves — the
    /// ones on the page now (`current`) and the ones hidden earlier, so a
    /// hidden shelf can always be shown again.
    /// `listed` is what the open list already shows: those rows keep their
    /// place, so a switch never moves its row nor takes it off the list
    /// (a genre shown again is not on the page until the page is rebuilt).
    func shelves(current: [HomeShelf], listed: [Shelf] = []) -> [Shelf] {
        let hidden = settings.hiddenShelves
        var ids = StreamingSettingsStore.shelves(HomeShelfID.order, hasKey: hasKey)
        let isGenre: (String) -> Bool = { HomeShelfID.genre(of: $0) != nil }
        let genres = listed.map(\.id).filter(isGenre)
            + current.map(\.id).filter(isGenre)
            + hidden.filter(isGenre).sorted()
        for id in genres where !ids.contains(id) { ids.append(id) }
        return ids.map { id in
            Shelf(id: id, title: text.title(of: HomeShelf(id: id, style: .posters, items: [])), isShown: !hidden.contains(id))
        }
    }

    func setShelf(_ id: String, shown: Bool) {
        settings.setShelf(id, hidden: !shown)
    }

    /// A TMDB key is stored: the « Services » row exists.
    private var hasKey: Bool { settings.tmdbAPIKey != nil }

    /// How many shelves are hidden, for the row that opens the list: "2",
    /// or "Aucune" (a count needs no plural rule in any language). The
    /// « Services » row hidden while there is no key is not counted: it is
    /// not listed.
    var hiddenSummary: String {
        let count = settings.hiddenShelves.filter { $0 != HomeShelfID.services || hasKey }.count
        return count == 0 ? text.localize("None") : count.formatted(.number.locale(locale))
    }
}
