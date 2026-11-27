//
//  ContentLanguagesTests.swift
//  PopcornTimeTests
//
//  Languages by content type (« Vos langues »): a profile's choices and their storage (nothing
//  stored = Automatic, each profile its own, deleted with it); a title's type and original
//  language from the metadata the app loads (Cinemeta, YTS, TVMaze, TMDB answers as they come);
//  the plan a choice makes for a title, what the release ranking and the players read from it;
//  the launch screen's once-per-profile rule, its sequencing, and the editor's model. No network,
//  no real defaults.
//

import Foundation
import XCTest
@testable import PopcornKit

final class ContentLanguagesTests: CheckedTestCase {

    private var origins = TitleOriginStore(fileURL: nil)
    private var choices = ContentLanguageChoices.automatic

    override func setUp() {
        super.setUp()
        origins = TitleOriginStore(fileURL: nil)
        choices = .automatic
        ContentLanguages.environment = ContentLanguages.Environment(
            activeProfileID: { Profile.primaryID },
            choices: { [unowned self] _ in self.choices },
            origins: origins)
        ContentLanguages.clearFocus()
    }

    override func tearDown() {
        ContentLanguages.clearFocus()
        ContentLanguages.environment = ContentLanguages.Environment(
            activeProfileID: { Profile.primaryID }, choices: { _ in .automatic }, origins: TitleOriginStore(fileURL: nil))
        AudioLanguagePreference.override = nil
        super.tearDown()
    }

    // MARK: - Sample metadata (as the sources answer, trimmed to the fields read)

    private func cinemeta(_ genres: [String], _ country: String?) -> [String: Any] {
        var meta: [String: Any] = ["genres": genres, "genre": genres]
        if let country { meta["country"] = country }
        return meta
    }

    private func yts(_ language: String, genres: [String] = []) -> [String: Any] {
        return ["language": language, "genres": genres, "imdb_code": "tt"]
    }

    private func tvmaze(_ type: String, _ language: String?, genres: [String] = []) -> [String: Any] {
        var show: [String: Any] = ["id": 1, "name": "x", "type": type, "genres": genres]
        if let language { show["language"] = language }
        return show
    }

    private func origin(_ parts: TitleOrigin?...) -> TitleOrigin? {
        let store = TitleOriginStore(fileURL: nil)
        for part in parts { store.note(part, for: "tt1") }
        return store.origin(for: "tt1")
    }

    // MARK: - Choices and their storage

    func testChoicesStorage() {
        let storage = MemoryLibraryStorage()
        // Nothing stored: Automatic everywhere (an update, a new profile).
        let none = ContentLanguageSettings.choices(in: storage)
        check(none.isAllAutomatic, "nothing stored is Automatic")
        for type in ContentType.allCases { eq(none[type], .automatic, "\(type) automatic") }

        var chosen = ContentLanguageChoices.automatic
        chosen[.movie] = ContentLanguageChoice(audio: .original, subtitles: .language("fr"))
        chosen[.cartoon] = ContentLanguageChoice(audio: .language("fr"))
        chosen[.anime] = ContentLanguageChoice(audio: .language("ja"), subtitles: .off)
        ContentLanguageSettings.save(chosen, in: storage)
        let read = ContentLanguageSettings.choices(in: storage)
        eq(read, chosen, "the choices read back")
        eq(read[.cartoon].subtitles, .automatic, "an untouched half stays Automatic")
        let plist = storage.object(forKey: ContentLanguageSettings.storageKey) as? [String: [String: String]]
        eq(plist?["movie"]?["audio"], "original", "stored as tags")
        eq(plist?["anime"]?["subtitles"], "off", "Off stored as a tag")

        // Back to Automatic: the key goes.
        ContentLanguageSettings.save(.automatic, in: storage)
        check(storage.object(forKey: ContentLanguageSettings.storageKey) == nil, "all Automatic removes the key")

        // Damaged values read as Automatic.
        storage.set(["anime": ["audio": "", "subtitles": 3], "nonsense": ["audio": "fr"], "movie": "x"], forKey: ContentLanguageSettings.storageKey)
        check(ContentLanguageSettings.choices(in: storage).isAllAutomatic, "unreadable values are Automatic")

        eq(ContentAudioChoice(tag: "auto"), .automatic, "audio tag auto")
        eq(ContentAudioChoice(tag: "ORIGINAL"), .original, "audio tag original")
        eq(ContentAudioChoice(tag: "fr").tag, "fr", "audio tag code")
        eq(ContentSubtitleChoice(tag: "off"), .off, "subtitle tag off")
        eq(ContentSubtitleChoice(tag: nil), .automatic, "subtitle tag missing")
        eq(ContentType(rawValue: "anime"), .anime, "debug argument values are the raw values")
        let seed = ContentLanguageChoices(debugString: "anime=original/fr; cartoon=fr ;movie=auto/off;bogus=x")
        eq(seed[.anime], ContentLanguageChoice(audio: .original, subtitles: .language("fr")), "-PTDebugContentLanguages anime")
        eq(seed[.cartoon], ContentLanguageChoice(audio: .language("fr")), "-PTDebugContentLanguages cartoon")
        eq(seed[.movie], ContentLanguageChoice(subtitles: .off), "-PTDebugContentLanguages movie")
    }

    func testEachProfileHasItsOwn() throws {
        let storage = MemoryLibraryStorage()
        var ids = 0
        let manager = ProfileManager(storage: storage, defaultName: "Me", center: NotificationCenter(),
                                     makeID: { ids += 1; return "p\(ids)" }, eraseExternal: { _ in })
        let other = try manager.create(name: "Sam", avatar: 1)
        var chosen = ContentLanguageChoices.automatic
        chosen[.anime] = ContentLanguageChoice(audio: .original, subtitles: .language("fr"))
        ContentLanguageSettings.save(chosen, in: manager.storage(for: other.id))
        ContentLanguageSettings.markAsked(in: manager.storage(for: other.id))
        check(ContentLanguageSettings.choices(in: manager.storage(for: Profile.primaryID)).isAllAutomatic,
              "the primary profile keeps its own (Automatic)")
        check(!ContentLanguageSettings.wasAsked(in: manager.storage(for: Profile.primaryID)), "the primary profile not asked yet")
        eq(ContentLanguageSettings.choices(in: manager.storage(for: other.id)), chosen, "the other profile's choices")
        check(storage.object(forKey: "profile.p1.contentLanguages") != nil, "stored behind the profile's prefix")
        try manager.delete(other.id)
        check(storage.object(forKey: "profile.p1.contentLanguages") == nil, "deleted with the profile")
        check(storage.object(forKey: "profile.p1.contentLanguagesAsked") == nil, "its flag too")
    }

    // MARK: - Classification

    func testClassificationOfSampleTitles() {
        // Anime films: Animation + Japan (Cinemeta) and/or ja (YTS).
        let spiritedAway = origin(TitleOrigin(cinemeta: cinemeta(["Animation", "Adventure", "Family"], "Japan")),
                                  TitleOrigin(yts: yts("ja", genres: ["Animation", "Fantasy"])))
        eq(ContentClassifier.classify(spiritedAway), .anime, "Spirited Away is anime")
        eq(ContentClassifier.originalLanguage(of: spiritedAway)?.code, "ja", "Spirited Away VO is Japanese")
        eq(ContentClassifier.originalLanguage(of: spiritedAway)?.source, .yts, "from YTS")

        // A US film co-produced in Japan: the FIRST country counts.
        let frozen = origin(TitleOrigin(cinemeta: cinemeta(["Animation", "Adventure", "Comedy"], "United States, Japan")),
                            TitleOrigin(yts: yts("en", genres: ["Animation"])))
        eq(ContentClassifier.classify(frozen), .cartoon, "Frozen is a cartoon")
        eq(ContentClassifier.originalLanguage(of: frozen)?.code, "en", "Frozen VO is English")

        // European animation.
        let persepolis = origin(TitleOrigin(cinemeta: cinemeta(["Animation", "Biography", "Drama"], "France, United States")))
        eq(ContentClassifier.classify(persepolis), .cartoon, "Persepolis is a cartoon")
        eq(ContentClassifier.originalLanguage(of: persepolis)?.code, "fr", "Persepolis VO from its first country")
        eq(ContentClassifier.originalLanguage(of: persepolis)?.source, .country, "inferred from the country")
        let flow = origin(TitleOrigin(cinemeta: cinemeta(["Animation", "Adventure"], "Latvia, France, Belgium")),
                          TitleOrigin(yts: yts("lv", genres: ["Animation"])))
        eq(ContentClassifier.classify(flow), .cartoon, "Flow is a cartoon")
        eq(ContentClassifier.originalLanguage(of: flow)?.code, "lv", "Flow VO is Latvian")

        // The source's language wins over the country (The Little Prince 2015: France first, English).
        let littlePrince = origin(TitleOrigin(cinemeta: cinemeta(["Animation", "Adventure"], "France, Italy, Canada")),
                                  TitleOrigin(yts: yts("en")))
        eq(ContentClassifier.originalLanguage(of: littlePrince)?.code, "en", "The Little Prince VO is English")

        // Live action, Japanese live action, and YTS's noisy "Animation" (Rampage).
        let inception = origin(TitleOrigin(cinemeta: cinemeta(["Action", "Adventure", "Sci-Fi"], "United States, United Kingdom")))
        eq(ContentClassifier.classify(inception), .movie, "Inception is live action")
        let shoplifters = origin(TitleOrigin(cinemeta: cinemeta(["Crime", "Drama"], "Japan")), TitleOrigin(yts: yts("ja", genres: ["Drama"])))
        eq(ContentClassifier.classify(shoplifters), .movie, "Shoplifters is live action")
        eq(ContentClassifier.originalLanguage(of: shoplifters)?.code, "ja", "Shoplifters VO is Japanese")
        let rampage = origin(TitleOrigin(yts: yts("en", genres: ["Action", "Animation", "Sci-Fi"])))
        eq(ContentClassifier.classify(rampage), .movie, "YTS's Animation alone is not trusted")
        let rampageFull = origin(TitleOrigin(yts: yts("en", genres: ["Action", "Animation"])),
                                 TitleOrigin(cinemeta: cinemeta(["Action", "Adventure", "Sci-Fi"], "United States")))
        eq(ContentClassifier.classify(rampageFull), .movie, "Cinemeta's genres decide")
        // The model's genres of a YTS movie are YTS's: a YTS record keeps them out.
        eq(ContentClassifier.classify(rampage, fallbackGenres: ["Action", "Animation"]), .movie,
           "YTS's Animation never comes back through the model's genres")
        // YTS's Animation with Japanese is safe (Godzilla Minus One has no Animation there).
        let yourName = origin(TitleOrigin(yts: yts("ja", genres: ["Animation", "Drama"])))
        eq(ContentClassifier.classify(yourName), .anime, "YTS Animation + ja is anime")
        // A later Cinemeta answer never loses to YTS.
        let order = origin(TitleOrigin(cinemeta: cinemeta(["Action"], "United States")), TitleOrigin(yts: yts("ja", genres: ["Animation"])))
        eq(ContentClassifier.classify(order), .movie, "Cinemeta stays ahead of YTS")

        // Series from TVMaze: type Animation, genre Anime, language name.
        let attackOnTitan = origin(TitleOrigin(tvmaze: tvmaze("Animation", "Japanese", genres: ["Action", "Anime", "Fantasy"])))
        eq(ContentClassifier.classify(attackOnTitan), .anime, "Attack on Titan is anime")
        let simpsons = origin(TitleOrigin(tvmaze: tvmaze("Animation", "English", genres: ["Comedy", "Family"])))
        eq(ContentClassifier.classify(simpsons), .cartoon, "The Simpsons is a cartoon (TVMaze's type)")
        let castlevania = origin(TitleOrigin(tvmaze: tvmaze("Animation", "English", genres: ["Action", "Anime", "Fantasy"])))
        eq(ContentClassifier.classify(castlevania), .cartoon, "Castlevania (US) is a cartoon")
        let miraculous = origin(TitleOrigin(tvmaze: tvmaze("Animation", "French", genres: ["Action", "Children"])))
        eq(ContentClassifier.classify(miraculous), .cartoon, "Miraculous is a cartoon")
        eq(ContentClassifier.originalLanguage(of: miraculous)?.code, "fr", "Miraculous VO is French")
        let breakingBad = origin(TitleOrigin(tvmaze: tvmaze("Scripted", "English", genres: ["Drama", "Crime", "Thriller"])))
        eq(ContentClassifier.classify(breakingBad), .movie, "Breaking Bad is live action")
        let lupin = origin(TitleOrigin(tvmaze: tvmaze("Scripted", "French", genres: ["Drama", "Crime"])))
        eq(ContentClassifier.originalLanguage(of: lupin)?.code, "fr", "Lupin VO is French")

        // A series TVMaze doesn't know: the directory's record built from Cinemeta (Dragon Ball).
        let record = TVMazeShowDirectory.record(fromCinemeta: ["id": "tt0088509", "name": "Dragon Ball",
                                                                "genres": ["Animation", "Action"], "country": "Japan"]) ?? [:]
        let dragonBall = origin(TitleOrigin(tvmaze: record))
        eq(ContentClassifier.classify(dragonBall), .anime, "Dragon Ball (Cinemeta's record) is anime")
        eq(ContentClassifier.originalLanguage(of: dragonBall)?.code, "ja", "Dragon Ball VO from its country")

        // A country with several languages says nothing of the VO: Automatic.
        for (countries, name) in [("Belgium, France", "a Belgian film"), ("Switzerland", "a Swiss film"),
                                  ("India", "an Indian film"), ("Canada", "a Québec film")] {
            let multilingual = origin(TitleOrigin(cinemeta: cinemeta(["Drama"], countries)))
            check(ContentClassifier.originalLanguage(of: multilingual) == nil, "\(name): VO unknown")
        }
        let belgianVO = TitleLanguagePlan(imdbID: "tt1", choices: ContentLanguageChoices([.movie: ContentLanguageChoice(audio: .original)]),
                                          origin: origin(TitleOrigin(cinemeta: cinemeta(["Drama"], "Belgium"))))
        eq(belgianVO.audioReason, .originalUnknown, "a Belgian film's VO falls back to Automatic")
        eq(ContentClassifier.unknownLanguageReason(of: origin(TitleOrigin(cinemeta: cinemeta(["Drama"], "Belgium")))),
           "first country BE has several languages, no source gave one", "and the log says why")
        // A source's language still wins (a Belgian film TMDB knows).
        let dardenne = origin(TitleOrigin(cinemeta: cinemeta(["Drama"], "Belgium, France")),
                              TitleOrigin(tmdb: ["original_language": "fr", "genre_ids": [18]]))
        eq(ContentClassifier.originalLanguage(of: dardenne)?.code, "fr", "TMDB's original language")
        eq(ContentClassifier.originalLanguage(of: dardenne)?.source, .tmdb, "from TMDB")

        // TMDB's answers (an optional key).
        let tmdb = origin(TitleOrigin(tmdb: ["original_language": "ja", "genre_ids": [16, 12], "origin_country": ["JP"]]))
        eq(ContentClassifier.classify(tmdb), .anime, "TMDB genre 16 + ja is anime")

        // Unknowns: no genres → live action; animation of unknown origin → cartoon.
        eq(ContentClassifier.classify(nil), .movie, "no information is live action")
        eq(ContentClassifier.classify(nil, fallbackGenres: ["Animation", "Family"]), .cartoon, "unknown origin animation is a cartoon")
        eq(ContentClassifier.classify(nil, fallbackGenres: ["Drama"]), .movie, "the model's genres when nothing else")
        eq(ContentClassifier.classify(inception, fallbackGenres: ["Animation"]), .movie, "the record wins over the model's genres")
        check(ContentClassifier.originalLanguage(of: nil) == nil, "no original language when nothing is known")

        // The recorded Cinemeta answer (Amélie: "France, Germany").
        let amelie = (try? JSONSerialization.jsonObject(with: Fixtures.data("Sources/cm_meta_movie_tt0211915.json"))) as? [String: Any]
        let ameliOrigin = origin(TitleOrigin(cinemeta: (amelie?["meta"] as? [String: Any]) ?? amelie ?? [:]))
        eq(ContentClassifier.classify(ameliOrigin), .movie, "Amélie is live action")
        eq(ContentClassifier.originalLanguage(of: ameliOrigin)?.code, "fr", "Amélie VO is French")

        let why = ContentClassifier.classification(spiritedAway).why
        eq(why, "Animation (Cinemeta) · ja (YTS) · first country JP", "the log says why")
    }

    func testLanguageAndCountryCodes() {
        eq(ContentClassifier.normalizedLanguageCode("xx"), nil, "TMDB's no language")
        eq(ContentClassifier.normalizedLanguageCode("cn"), "zh", "Cantonese")
        eq(ContentClassifier.normalizedLanguageCode("sh"), "sr", "Serbo-Croatian")
        eq(ContentClassifier.normalizedLanguageCode("nb"), "no", "Bokmål is the pickers' Norwegian")
        eq(ContentClassifier.normalizedLanguageCode("pt-BR"), "pt", "a region dropped")
        eq(ContentClassifier.normalizedLanguageCode(""), nil, "empty")
        eq(ContentClassifier.languageCode(ofEnglishName: "Japanese"), "ja", "TVMaze's Japanese")
        eq(ContentClassifier.languageCode(ofEnglishName: "Norwegian"), "no", "TVMaze's Norwegian")
        eq(ContentClassifier.languageCode(ofEnglishName: "Klingon"), nil, "unknown language name")
        eq(ContentClassifier.firstRegion(ofCountries: "Japan, United States"), "JP", "the first country")
        eq(ContentClassifier.regionCode(ofCountryName: "China"), "CN", "IMDb's China")
        eq(ContentClassifier.regionCode(ofCountryName: "Turkey"), "TR", "IMDb's Turkey")
        eq(ContentClassifier.regionCode(ofCountryName: "Czech Republic"), "CZ", "IMDb's Czech Republic")
        eq(ContentClassifier.regionCode(ofCountryName: "West Germany"), "DE", "a historical country")
        eq(ContentClassifier.regionCode(ofCountryName: "Soviet Union"), "RU", "the Soviet Union")
        eq(ContentClassifier.regionCode(ofCountryName: "Atlantis"), nil, "unknown country")
        for (region, language) in [("JP", "ja"), ("FR", "fr"), ("KR", "ko"), ("US", "en"), ("GB", "en"), ("BE", "nl"),
                                   ("CH", "de"), ("IN", "hi"), ("NO", "no"), ("LV", "lv")] {
            eq(ContentClassifier.language(ofRegion: region), language, "\(region)'s language")
        }
        for region in ["BE", "CH", "IN", "CA", "LU", "SG", "ZA", "UA"] {
            check(ContentClassifier.confidentLanguage(ofRegion: region) == nil, "\(region) has several languages")
        }
        for region in ContentClassifier.singleLanguageRegions {
            check(ContentClassifier.confidentLanguage(ofRegion: region) != nil, "\(region) has a language")
        }
        eq(ContentClassifier.confidentLanguage(ofRegion: "jp"), "ja", "Japan")
    }

    func testStorePersistsAndMerges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ContentLanguagesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("origins.json")
        let store = TitleOriginStore(fileURL: url)
        check(store.note(TitleOrigin(cinemeta: cinemeta(["Animation"], "Japan")), for: "tt0245429"), "a first note changes it")
        check(!store.note(TitleOrigin(cinemeta: cinemeta(["Animation"], "Japan")), for: "tt0245429"), "the same facts change nothing")
        check(store.note(TitleOrigin(yts: yts("ja")), for: "tt0245429"), "a language adds to it")
        check(!store.note(TitleOrigin(cinemeta: [:]), for: "tt0245429"), "an empty meta is nothing")
        check(!store.note(TitleOrigin(cinemeta: cinemeta(["Drama"], nil)), for: "nm0000001"), "not an IMDb title id")
        store.save()
        let reread = TitleOriginStore(fileURL: url)
        let origin = reread.origin(for: "tt0245429")
        eq(origin?.isAnimation, true, "animation kept on disk")
        eq(origin?.originalLanguage, "ja", "language kept on disk")
        eq(origin?.firstCountry, "JP", "country kept on disk")
        eq(ContentClassifier.classify(origin), .anime, "read back, still anime")
    }

    // MARK: - Titles and plans

    func testTitlesOfMedia() {
        let movie = Movie(title: "Spirited Away", id: "tt0245429")
        eq(ContentLanguages.Title(media: movie)?.imdbID, "tt0245429", "a movie's id")
        eq(ContentLanguages.Title(media: movie)?.isShow, false, "a movie")
        let show = Show(title: "Attack on Titan", id: "tt2560140")
        let episode = Episode(title: "To You", id: "tt2560140-s1e1", show: show, episode: 1, season: 1)
        eq(ContentLanguages.Title(media: episode)?.imdbID, "tt2560140", "an episode counts as its show")
        eq(ContentLanguages.Title(media: episode)?.isShow, true, "a show")
        let orphan = Episode(title: "To You", id: "tt2560140-s1e1", episode: 1, season: 1)
        eq(ContentLanguages.Title(media: orphan)?.imdbID, "tt2560140", "an episode without its show: from its id")
        check(ContentLanguages.Title(media: Movie(title: "x", id: "12345")) == nil, "no IMDb id, no title")
    }

    func testPlans() {
        let anime = TitleOrigin(isAnimation: true, animationSource: .cinemeta, originalLanguage: "ja", languageSource: .yts)
        let unknownCartoon = TitleOrigin(isAnimation: true, animationSource: .cinemeta)
        var chosen = ContentLanguageChoices.automatic

        let automatic = TitleLanguagePlan(imdbID: "tt1", choices: chosen, origin: anime)
        check(automatic.isAutomatic, "nothing chosen: automatic")
        eq(automatic.type, .anime, "the type is still known")
        eq(automatic.audioReason, .automatic, "audio automatic")

        chosen[.anime] = ContentLanguageChoice(audio: .original, subtitles: .language("fr"))
        chosen[.cartoon] = ContentLanguageChoice(audio: .original, subtitles: .off)
        chosen[.movie] = ContentLanguageChoice(audio: .language("en"))
        let vo = TitleLanguagePlan(imdbID: "tt1", choices: chosen, origin: anime)
        eq(vo.audio, "ja", "VO plays Japanese")
        eq(vo.audioReason, .original(.yts), "from YTS's language")
        eq(vo.subtitles, .language("fr"), "French subtitles")

        let cartoon = TitleLanguagePlan(imdbID: "tt2", choices: chosen, origin: unknownCartoon)
        eq(cartoon.type, .cartoon, "unknown-origin animation is a cartoon")
        eq(cartoon.audio, nil, "VO unknown falls back to Automatic")
        eq(cartoon.audioReason, .originalUnknown, "and says why")
        eq(cartoon.subtitles, .off, "subtitles off")

        let movie = TitleLanguagePlan(imdbID: "tt3", choices: chosen, origin: nil)
        eq(movie.type, .movie, "no information: live action")
        eq(movie.audio, "en", "a chosen language")
        eq(movie.audioReason, .chosen, "chosen")
        eq(movie.subtitles, .automatic, "subtitles automatic")

        let forced = TitleLanguagePlan(imdbID: "tt3", choices: chosen, origin: nil, forcedType: .anime)
        eq(forced.type, .anime, "-PTDebugContentType forces the type")
        eq(forced.typeReason, "forced by -PTDebugContentType", "and the log says so")
    }

    func testReleaseRankingAndPlayersFollowTheFocusedTitle() {
        // The profile's own language (Settings or learnt) stands in for Automatic.
        AudioLanguagePreference.override = nil
        let anime = "tt0245429", live = "tt1375666"
        origins.note(TitleOrigin(cinemeta: cinemeta(["Animation"], "Japan")), for: anime)
        origins.note(TitleOrigin(cinemeta: cinemeta(["Action", "Sci-Fi"], "United States")), for: live)
        eq(AudioLanguagePreference.current, nil, "no focus: the profile's own (none in the tests)")

        ContentLanguages.focus(on: ContentLanguages.Title(imdbID: anime, isShow: false, name: "Spirited Away"))
        eq(AudioLanguagePreference.current, nil, "Automatic: unchanged")
        choices[.anime] = ContentLanguageChoice(audio: .original, subtitles: .off)
        ContentLanguages.invalidate()
        eq(AudioLanguagePreference.current, "ja", "VO: the ranking favours Japanese releases")
        eq(AudioLanguagePreference.current(forTitle: live, isShow: false), nil, "another title keeps the profile's")
        eq(AudioLanguagePreference.current(forTitle: anime, isShow: false), "ja", "by id too")
        eq(PlaybackLanguagePreferences.preferredAudioLanguageCode, "ja", "the players pick the Japanese track")
        check(PlaybackLanguagePreferences.subtitleOverride(plan: ContentLanguages.focusedPlan) == .some(nil), "Off: no subtitles")
        eq(PlaybackLanguagePreferences.preferredSubtitleLanguageCode(whileHearing: "jpn"), nil, "Off while hearing Japanese")
        eq(PlaybackLanguagePreferences.preferredSubtitleLanguageCode, nil, "Off without knowing the audio")

        choices[.anime] = ContentLanguageChoice(audio: .language("fr"), subtitles: .language("fr"))
        ContentLanguages.invalidate()
        eq(AudioLanguagePreference.current, "fr", "a language chosen for anime")
        eq(PlaybackLanguagePreferences.preferredSubtitleLanguageCode(whileHearing: "fre"), "fr",
           "a chosen subtitle language shows even in the language heard")

        // The plan follows a late origin: unknown at first, then known.
        let late = "tt9999999"
        choices[.cartoon] = ContentLanguageChoice(audio: .original)
        ContentLanguages.focus(on: ContentLanguages.Title(imdbID: late, isShow: true, name: "Bluey", genres: ["Animation"]))
        eq(ContentLanguages.focusedPlan?.type, .cartoon, "the model's genres meanwhile")
        eq(ContentLanguages.focusedPlan?.audioReason, .originalUnknown, "VO unknown yet")
        origins.note(TitleOrigin(tvmaze: tvmaze("Animation", "English")), for: late)
        eq(ContentLanguages.focusedPlan?.audio, "en", "the origin arrived: VO English")

        // A player's title stays what the players read when another page opens (a second Mac
        // window); the page's ranking follows the page.
        choices[.movie] = ContentLanguageChoice(audio: .language("en"), subtitles: .language("fr"))
        ContentLanguages.invalidate()
        ContentLanguages.beginPlaying(ContentLanguages.Title(imdbID: anime, isShow: false, name: "Spirited Away"))
        ContentLanguages.focus(on: ContentLanguages.Title(imdbID: live, isShow: false, name: "Inception"))
        eq(ContentLanguages.playingPlan?.imdbID, anime, "the player keeps its title")
        eq(PlaybackLanguagePreferences.preferredAudioLanguageCode, "fr", "the player's audio is still anime's")
        eq(AudioLanguagePreference.playing, "fr", "a lighter release during playback: anime's language")
        eq(AudioLanguagePreference.current, "en", "the page's ranking: the page's title")
        ContentLanguages.beginPlaying(ContentLanguages.Title(imdbID: live, isShow: false, name: "Inception"))
        eq(PlaybackLanguagePreferences.preferredAudioLanguageCode, "en", "the next player: its own title")
        ContentLanguages.beginPlaying(nil)
        check(ContentLanguages.playingPlan == nil, "a title without an id plays Automatic")

        // The tests' override still wins.
        AudioLanguagePreference.override = .some("de")
        eq(AudioLanguagePreference.current, "de", "the override first")
        AudioLanguagePreference.override = nil
        ContentLanguages.clearFocus()
        eq(AudioLanguagePreference.current, nil, "no focus again")
    }

    func testUnknownOriginalIsLoggedOnceAndNothingIsAskedWhileAutomatic() {
        let unknown = "tt8888888"
        check(!ContentLanguages.isInUse, "all Automatic: not in use")
        let asked = expectation(description: "ensureOrigin answers")
        ContentLanguages.ensureOrigin(of: ContentLanguages.Title(imdbID: unknown, isShow: false, name: "x")) { changed in
            XCTAssertFalse(changed, "nothing asked while Automatic")
            asked.fulfill()
        }
        wait(for: [asked], timeout: 5)
        check(origins.origin(for: unknown) == nil, "nothing learnt either")

        choices[.movie] = ContentLanguageChoice(audio: .original)
        ContentLanguages.invalidate()
        check(ContentLanguages.isInUse, "a choice made: in use")
        eq(ContentLanguages.audioOverride(forTitle: unknown, isShow: false), nil, "VO unknown: the ranking stays Automatic")
        check(ContentLanguages.loggedUnknownOriginalIDs.contains(unknown), "and the log says why")
    }

    func testTMDBEntriesNoteTheOrigin() {
        let id = "tt7777777"
        _ = HomeParse.tmdbEntry(["imdb_id": id, "name": "Frieren", "original_language": "ja",
                                 "genre_ids": [16, 10759], "origin_country": ["JP"]], kind: .show)
        let noted = TitleOriginStore.shared.origin(for: id)
        eq(noted?.originalLanguage, "ja", "TMDB's original language")
        eq(noted?.languageSource, .tmdb, "from TMDB")
        eq(ContentClassifier.classify(noted), .anime, "TMDB's Animation + Japan is anime")
    }

    func testPlayerHelpersAndLogLine() {
        var chosen = ContentLanguageChoices.automatic
        let anime = TitleOrigin(isAnimation: true, animationSource: .tvmaze, originalLanguage: "ja", languageSource: .tvmaze)
        let automatic = TitleLanguagePlan(imdbID: "tt1", choices: chosen, origin: anime)
        eq(PlaybackLanguagePreferences.audioCode(plan: automatic, automatic: "fr"), "fr", "Automatic: the profile's language")
        eq(PlaybackLanguagePreferences.audioCode(plan: nil, automatic: nil), nil, "no title, no language")
        check(PlaybackLanguagePreferences.subtitleOverride(plan: automatic) == nil, "Automatic subtitles: no override")
        eq(PlaybackLanguagePreferences.planDescription(automatic, name: "Frieren", automaticAudio: "fr", automaticSubtitles: nil),
           "[Languages] Frieren: anime → audio fr (automatic), subtitles none (automatic)", "the automatic line")

        chosen[.anime] = ContentLanguageChoice(audio: .original, subtitles: .language("fr"))
        let vo = TitleLanguagePlan(imdbID: "tt1", choices: chosen, origin: anime)
        eq(PlaybackLanguagePreferences.audioCode(plan: vo, automatic: "fr"), "ja", "VO wins over the learnt language")
        check(PlaybackLanguagePreferences.subtitleOverride(plan: vo) == .some("fr"), "French subtitles")
        eq(PlaybackLanguagePreferences.planDescription(vo, name: "Frieren", automaticAudio: "fr", automaticSubtitles: nil),
           "[Languages] Frieren: anime → audio ja (original version, from tvmaze), subtitles fr (chosen)", "the VO line")

        chosen[.movie] = ContentLanguageChoice(audio: .original, subtitles: .off)
        let unknown = TitleLanguagePlan(imdbID: "tt2", choices: chosen, origin: nil)
        eq(PlaybackLanguagePreferences.planDescription(unknown, name: "Inception", automaticAudio: nil, automaticSubtitles: "fr"),
           "[Languages] Inception: movie → audio unchanged (original version unknown → automatic), subtitles off (chosen)",
           "the unknown VO line")
    }

    // MARK: - The launch screen

    func testGateRule() {
        typealias G = LanguagesScreenGate
        check(G.shouldPresent(asked: false, forced: false, launchedFromURL: false, harness: false), "a profile never asked")
        check(!G.shouldPresent(asked: true, forced: false, launchedFromURL: false, harness: false), "answered: never again")
        check(!G.shouldPresent(asked: false, forced: false, launchedFromURL: true, harness: false), "a link launch: not now")
        check(!G.shouldPresent(asked: false, forced: true, launchedFromURL: true, harness: false), "a link even when forced")
        check(!G.shouldPresent(asked: false, forced: false, launchedFromURL: false, harness: true), "never in the UI tests")
        check(G.shouldPresent(asked: true, forced: true, launchedFromURL: false, harness: true), "-PTDebugLanguagesScreen YES forces it")
    }

    @MainActor
    func testGateClaimsOncePerProfile() {
        let id = "claim-\(UUID().uuidString)"
        check(LanguagesScreenGate.claim(profileID: id), "the first window shows it")
        check(!LanguagesScreenGate.claim(profileID: id), "not a second window")
        check(LanguagesScreenGate.claim(profileID: id + "-other"), "another profile has its own")
    }

    func testLaunchQueue() {
        var queue = LanguagesLaunchQueue()
        queue.check(gateSays: true)
        check(!queue.update(blocked: true), "waits while What's New is up")
        check(queue.pending, "still due")
        check(queue.update(blocked: false), "shows once nothing else is up")
        check(queue.isPresented, "shown")
        check(!queue.update(blocked: false), "only once")
        queue.finished()
        check(!queue.isPresented && !queue.pending, "done")
        queue.check(gateSays: true)
        check(!queue.update(blocked: false), "one check per launch")

        var linked = LanguagesLaunchQueue()
        check(!linked.linkOpened(), "a link before: nothing to close")
        linked.check(gateSays: true)
        check(!linked.update(blocked: false), "a link launch never shows it")

        var late = LanguagesLaunchQueue()
        late.check(gateSays: true)
        _ = late.update(blocked: false)
        check(late.linkOpened(), "a link closes the screen")
        check(!late.isPresented, "closed")

        var skipped = LanguagesLaunchQueue()
        skipped.check(gateSays: false)
        check(!skipped.update(blocked: false), "nothing due")
    }

    @MainActor
    func testEditorModel() {
        let storage = MemoryLibraryStorage()
        let launch = LanguagesByTypeModel(storage: storage, profileID: "p1", mode: .launchScreen)
        eq(launch.types, [.movie, .cartoon, .anime], "three rows, in order")
        eq(launch.audioOptions.prefix(2).map(\.id), ["auto", "original"], "audio: Automatic, VO first")
        eq(launch.subtitleOptions.prefix(2).map(\.id), ["auto", "off"], "subtitles: Automatic, Off first")
        check(launch.audioOptions.contains { $0.id == "ja" } && launch.subtitleOptions.contains { $0.id == "fr" }, "the picker languages")
        eq(Set(launch.audioOptions.map(\.id)).count, launch.audioOptions.count, "no option twice")
        eq(launch.audioValue(for: .movie), "Automatic", "Automatic shown")
        eq(launch.settingsRowValue, "Automatic", "the Settings row says Automatic")

        launch.setAudioTag("original", for: .movie)
        launch.setSubtitleTag("off", for: .anime)
        launch.subtitleBinding(for: .cartoon).wrappedValue = "fr"
        eq(launch.audioValue(for: .movie), "Original", "VO shown")
        eq(launch.subtitleValue(for: .anime), "Off", "Off shown")
        check(ContentLanguageSettings.choices(in: storage).isAllAutomatic, "the launch screen saves nothing before Continue")
        launch.finish(saving: true)
        eq(ContentLanguageSettings.choices(in: storage)[.movie].audio, .original, "Continue saves")
        eq(ContentLanguageSettings.choices(in: storage)[.cartoon].subtitles, .language("fr"), "the binding's choice saved")
        check(ContentLanguageSettings.wasAsked(in: storage), "and marks the profile asked")

        let laterStorage = MemoryLibraryStorage()
        let later = LanguagesByTypeModel(storage: laterStorage, profileID: "p2", mode: .launchScreen)
        later.setAudioTag("ja", for: .anime)
        later.finish(saving: false)
        check(ContentLanguageSettings.choices(in: laterStorage).isAllAutomatic, "Later keeps everything Automatic")
        check(ContentLanguageSettings.wasAsked(in: laterStorage), "and marks the profile asked")

        let settingsStorage = MemoryLibraryStorage()
        let settings = LanguagesByTypeModel(storage: settingsStorage, profileID: "p3", mode: .settings)
        settings.setAudioTag("ja", for: .anime)
        eq(ContentLanguageSettings.choices(in: settingsStorage)[.anime].audio, .language("ja"), "Settings saves at once")
        check(!ContentLanguageSettings.wasAsked(in: settingsStorage), "Settings doesn't answer the launch screen")
        eq(settings.settingsRowValue, "Anime", "the Settings row names the types chosen")
        settings.setAudioTag("auto", for: .anime)
        check(settingsStorage.object(forKey: ContentLanguageSettings.storageKey) == nil, "back to Automatic: nothing stored")
    }
}
