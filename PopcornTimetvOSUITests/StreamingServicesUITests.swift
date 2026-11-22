import XCTest

/// Browsing by streaming service (TMDB) on the Apple TV. Without a key the
/// app is the one it was: no « Services » row on the Home, no Service
/// control on the grids. With a key: the row stands under Continue
/// Watching; a service picked shows its shelves with the focus kept on its
/// card; « All », or Menu at the top of the filtered page, brings the usual
/// page back; the Movies grid's Service control filters and pages, its Sort
/// and Genre offering only what the service's lists follow; Menu closes a
/// grid's menu, the key sheet and the country and services pickers, and
/// nothing more; the key sheet shows a QR code to TMDB's API page, and
/// « Check Again » once a key is stored.
///
/// Runs like `HomeUITests`: the tvOS 26.5 simulator, a DEBUG build. The key
/// is a made-up one (`-popcornkit.tmdb.apiKey`, the arguments domain, which
/// the app reads and never writes) and every TMDB answer is a hand-made
/// recorded file of PopcornTimeTests/Fixtures/Home (`-PTDebugHomeFixtures`:
/// the Home's hub and `TMDBStreamingClient.shared` both read them): no
/// request reaches TMDB. The Movies grid still reads the catalogue's own
/// hosts without a service, as in `GridUITests` (lists and artwork only).
/// Nothing is played (`-PTDebugHomeDryRunPlay`), the library lives in
/// memory (`-PTDebugLibraryInMemory`).
///
/// `PT_UITEST_SHOTS=<folder>` saves screenshots of the steps;
/// `PT_UITEST_LANGUAGE=fr` runs the app in French for them (the checks that
/// read English texts are skipped then).
final class StreamingServicesUITests: XCTestCase {

    private let remote = XCUIRemote.shared
    private var app: XCUIApplication!

    private static let focused = NSPredicate(format: "hasFocus == true")
    /// Not a TMDB key: any text makes the feature appear, and the recorded
    /// answers take any.
    private static let key = "fixture-key"
    /// A movie being watched: the Continue Watching shelf.
    private static let resume = "tt0816692|Interstellar|0.42|169"

    private var isEnglish: Bool { return language == "en" }
    private var language: String {
        return ProcessInfo.processInfo.environment["PT_UITEST_LANGUAGE"].flatMap { $0.isEmpty ? nil : $0 } ?? "en"
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    // MARK: - Without a key

    /// No key (every install the app ships to): the Home has no « Services »
    /// row, and the Movies grid's header is Sort and Genre only.
    func testWithoutAKeyTheHomeAndTheGridAreAsBefore() throws {
        launch(key: nil, ["-PTDebugHomeResume", Self.resume])
        XCTAssertTrue(element("Home.Section.continueWatching").waitForExistence(timeout: 30), "the Home never showed Continue Watching")
        pause(2)
        snap("no-key-home")
        XCTAssertFalse(element("Home.Section.services").exists, "a « Services » row without a key")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'Home.Card.service-'")).firstMatch.exists,
                       "a service's card without a key")
        app.terminate()

        launch(key: nil, ["-PTDebugTab", "movies"])
        let grid = self.grid("MoviesViewController")
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 60), "the grid never loaded")
        pause(2)
        snap("no-key-movies")
        XCTAssertTrue(element("GridHeader.Sort").exists && element("GridHeader.Genre").exists, "the header lost Sort / Genre")
        XCTAssertFalse(element("GridHeader.Service").exists, "a Service control without a key")
        app.terminate()

        // Settings: the section is there (its key « Not Set »), and its footer.
        launch(key: nil, ["-PTDebugTab", "settings", "-PTDebugFocusContent", "YES", "-PTDebugSettingsRow", "streamingServices"])
        let key = element("Settings.Row.tmdbKey")
        XCTAssertTrue(key.waitForExistence(timeout: 15), "no TMDB key row in Settings")
        pause(2.5)
        snap("no-key-settings")
        if isEnglish { XCTAssertTrue(key.label.contains("Not Set"), "the key row does not say there is none: \(key.label)") }
    }

    /// Netflix picked while its lists take a while (each answer 3 s late):
    /// placeholders under the row meanwhile — never the row alone — then
    /// its shelves, the focus on its card all along.
    func testAServiceWhoseListsTakeAWhileShowsPlaceholders() throws {
        launch(key: Self.key, ["-PTDebugHomeResume", Self.resume, "-PTDebugHomeFocus", "services:0", "-PTDebugHomeDelay", "3"])
        let netflix = element("Home.Card.service-8"), popular = element("Home.Section.streaming-8-movie-popular")
        XCTAssertTrue(waitForFocus(on: netflix, timeout: 40), "the focus never reached Netflix's card: \(focusedLabel)")
        pause(1.5)
        remote.press(.select)
        pause(1.2)
        snap("netflix-waiting")
        XCTAssertFalse(popular.exists, "Netflix's lists came at once: nothing waited")
        // The placeholders are hidden from accessibility: what shows instead
        // of them, when the page is wrong, is « No results ».
        XCTAssertFalse(element("Home.Services.Empty").exists, "« No results » while Netflix's lists are on their way")
        XCTAssertTrue(element("Home.Card.service-all").exists, "the page is not filtered yet")
        // Each answer 3 s late, after the refresh the launch started.
        XCTAssertTrue(popular.waitForExistence(timeout: 60), "Netflix's shelves never came")
        pause(2)
        snap("netflix-arrived")
        XCTAssertTrue(waitUntil(timeout: 5) { netflix.hasFocus || self.looksFocused(netflix, beside: self.element("Home.Card.service-119")) },
                      "the focus left Netflix's card while its shelves came: \(focusedLabel)")
    }

    /// A service that lists nothing (the recorded answers list nothing for
    /// TMDBRecorded.emptyService, Apple TV): « No results » under the
    /// row, « All » there, and no shelf of the service.
    func testAServiceThatListsNothingSaysSo() throws {
        launch(key: Self.key, ["-PTDebugHomeResume", Self.resume, "-PTDebugHomeFocus", "services:3"])
        let apple = element("Home.Card.service-350"), empty = element("Home.Services.Empty")
        XCTAssertTrue(waitForFocus(on: apple, timeout: 40), "the focus never reached Apple TV's card: \(focusedLabel)")
        pause(1.5)
        remote.press(.select)
        XCTAssertTrue(empty.waitForExistence(timeout: 30), "a service that lists nothing: no « No results »")
        pause(1.5)
        snap("apple-empty")
        XCTAssertTrue(element("Home.Card.service-all").exists, "no « All » to go back")
        XCTAssertFalse(element("Home.Unavailable").exists, "an empty list is not a failure")
        XCTAssertFalse(element("Home.Section.streaming-350-movie-popular").exists, "a shelf of a service that lists nothing")
    }

    /// A service none of whose lists came (TMDB refused the key, or did not
    /// answer; here no host answers and nothing is saved): the page says
    /// so, under the service's name, with Try Again, and the row stays under
    /// it, « All » included — never the row alone without a word.
    func testAServiceWhoseListsFailedSaysSo() throws {
        launch(key: Self.key, ["-PTDebugHomeOffline", "YES"])
        let unavailable = element("Home.Unavailable"), netflix = element("Home.Card.service-8")
        XCTAssertTrue(unavailable.waitForExistence(timeout: 30), "offline with nothing saved, the Home did not say it cannot load")
        XCTAssertTrue(netflix.waitForExistence(timeout: 10), "no « Services » row under the error")
        pause(1.5)
        // Down from Try Again into the row (under the middle of the screen),
        // then Left to its first card.
        for _ in 0..<6 where !netflix.hasFocus {
            remote.press(focusedIdentifier.hasPrefix("Home.Card.service-") ? .left : .down)
            pause(1.2)
        }
        XCTAssertTrue(netflix.hasFocus, "the row under Try Again cannot be reached: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(waitUntil(timeout: 30) { self.element("Home.Card.service-all").exists && !self.app.descendants(matching: .any)["Home.Loading"].exists && unavailable.exists },
                      "the filtered page does not say Netflix's lists could not load")
        pause(2)
        snap("service-unavailable")
        if isEnglish {
            XCTAssertTrue(app.staticTexts["The Netflix Catalog Can't Load"].exists, "the error does not name the service")
        }
        let retry = element("Home.Retry"), all = element("Home.Card.service-all")
        XCTAssertTrue(waitUntil(timeout: 5) { retry.hasFocus }, "Try Again does not have the focus: \(focusedLabel)")
        let screen = app.windows.firstMatch.frame
        XCTAssertTrue(screen.contains(retry.frame), "Try Again is not on the screen: the message scrolled away")
        XCTAssertTrue(all.exists && screen.intersects(all.frame), "the row, « All » included, is not under the message")
        // Down: the row; « All » brings the usual page back.
        for _ in 0..<6 where !all.hasFocus {
            remote.press(focusedIdentifier.hasPrefix("Home.Card.service-") ? .left : .down)
            pause(1.2)
        }
        XCTAssertTrue(all.hasFocus, "« All » cannot be reached under the message: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(waitUntil(timeout: 10) { !all.exists }, "« All » did not bring the usual page back")
    }

    // MARK: - The « Services » row

    /// With a key the row stands right under Continue Watching. Netflix
    /// picked: its shelves come, the focus stays on its card, where the row
    /// was under the band, and « All » is first in the row. « All » picked:
    /// the usual page again, the focus on Netflix's card.
    func testAServicePickedKeepsTheFocusAndAllBringsTheUsualPageBack() throws {
        launch(key: Self.key, ["-PTDebugHomeResume", Self.resume, "-PTDebugHomeFocus", "services:0"])
        let row = element("Home.Section.services"), resume = element("Home.Section.continueWatching")
        let netflix = element("Home.Card.service-8"), all = element("Home.Card.service-all")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no « Services » row with a key")
        XCTAssertTrue(waitForFocus(on: netflix), "the focus never reached Netflix's card: \(focusedLabel)")
        pause(1.5)
        snap("services-row")
        XCTAssertTrue(resume.exists, "no Continue Watching")
        XCTAssertGreaterThanOrEqual(row.frame.minY, resume.frame.maxY - 1, "the row is not under Continue Watching")
        let between = sections().filter { $0 != "Home.Section.services" && $0 != "Home.Section.continueWatching" }
            .map(element).filter { $0.frame.minY > resume.frame.minY && $0.frame.minY < row.frame.minY }
        XCTAssertTrue(between.isEmpty, "shelves between Continue Watching and the row: \(between.map(\.identifier))")
        XCTAssertFalse(all.exists, "« All » on the usual page")
        let cardBefore = netflix.frame

        remote.press(.select)
        let popular = element("Home.Section.streaming-8-movie-popular")
        XCTAssertTrue(popular.waitForExistence(timeout: 20), "Netflix's shelves never came")
        pause(2.5)
        snap("netflix-picked")
        XCTAssertTrue(netflix.hasFocus, "the focus left Netflix's card: \(focusedLabel)")
        XCTAssertTrue(all.exists, "no « All » card on the filtered page")
        XCTAssertLessThan(all.frame.minX, netflix.frame.minX, "« All » is not first in the row")
        XCTAssertEqual(netflix.frame.minY, cardBefore.minY, accuracy: 8, "the row is not where its band is: \(netflix.frame) / \(cardBefore)")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(netflix.frame), "Netflix's card is not whole on the screen")
        XCTAssertFalse(resume.exists, "Continue Watching on the filtered page")
        if isEnglish {
            XCTAssertTrue(netflix.label.hasPrefix("Netflix"), "not Netflix's card: \(netflix.label)")
        }

        // Down: the first shelf of the service.
        remote.press(.down)
        pause(1.5)
        XCTAssertTrue(focusedIdentifier.hasPrefix("Home.Card."), "Down from the row reached no card: \(focusedLabel)")
        XCTAssertTrue(popular.buttons.matching(Self.focused).firstMatch.exists, "Down from the row did not reach Netflix's popular movies")
        snap("netflix-first-shelf")
        remote.press(.up)
        pause(1.5)
        XCTAssertTrue(netflix.hasFocus, "Up did not come back to Netflix's card: \(focusedLabel)")

        // « All ».
        remote.press(.left)
        pause(1.2)
        XCTAssertTrue(all.hasFocus, "Left from Netflix did not reach « All »: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(resume.waitForExistence(timeout: 20), "« All » did not bring the usual page back")
        pause(2.5)
        snap("after-all")
        XCTAssertFalse(popular.exists, "Netflix's shelves stayed")
        XCTAssertFalse(all.exists, "« All » stayed on the usual page")
        // The card has the focus: XCUITest says so, or — the row drawn
        // again, its accessibility may not (seen in the tvOS 26.5 simulator)
        // — the card is lifted as only the focused card is, and Right goes
        // to its neighbour.
        let prime = element("Home.Card.service-119")
        XCTAssertTrue(waitUntil(timeout: 5) { netflix.hasFocus || looksFocused(netflix, beside: prime) },
                      "after « All » the focus is not on the service that was on: \(focusedLabel)")
        remote.press(.right)
        pause(1.2)
        XCTAssertTrue(prime.hasFocus || looksFocused(prime, beside: netflix), "Right from Netflix did not reach the next service: \(focusedLabel)")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Menu on a page filtered on a service: from its shelves to its top
    /// (Play), then to the usual page, and only then out of the app.
    func testMenuAtTheTopOfAFilteredPageBringsTheUsualPageBack() throws {
        launch(key: Self.key, ["-PTDebugHomeResume", Self.resume, "-PTDebugHomeFocus", "services:0"])
        let netflix = element("Home.Card.service-8"), resume = element("Home.Section.continueWatching")
        XCTAssertTrue(waitForFocus(on: netflix), "the focus never reached Netflix's card: \(focusedLabel)")
        pause(1.5)
        remote.press(.select)
        let popular = element("Home.Section.streaming-8-movie-popular")
        XCTAssertTrue(popular.waitForExistence(timeout: 20), "Netflix's shelves never came")
        pause(2.5)

        remote.press(.menu)
        pause(2)
        XCTAssertEqual(app.state, .runningForeground, "Menu from the shelves left the app")
        XCTAssertEqual(focusedIdentifier, "Home.Play", "Menu from the shelves did not go back to the top: \(focusedLabel)")
        // (The shelves far below the top are not drawn: Continue Watching,
        // at the top of the usual page, says which page this is.)
        XCTAssertTrue(element("Home.Card.service-all").exists && !resume.exists, "Menu from the shelves left the filtered page")
        snap("menu-top-of-filtered")

        remote.press(.menu)
        XCTAssertTrue(resume.waitForExistence(timeout: 20), "Menu at the top of the filtered page did not bring the usual page back")
        pause(2)
        snap("menu-usual-page")
        XCTAssertEqual(app.state, .runningForeground, "Menu at the top of a filtered page left the app")
        XCTAssertFalse(element("Home.Card.service-all").exists, "« All » stayed: the page is still filtered")
        XCTAssertEqual(focusedIdentifier, "Home.Play", "the usual page did not open at its top: \(focusedLabel)")

        remote.press(.menu)
        if !waitUntilLeft() {
            XCTAssertTrue(tabBarHasFocus, "Menu at the top of the usual page neither left the app nor moved the focus to the tab bar")
            remote.press(.menu)
            XCTAssertTrue(waitUntilLeft(), "Menu at the top of the usual page did not leave the app")
        }
    }

    // MARK: - The Movies grid

    /// With a key the Movies grid has a Service control after Sort and
    /// Genre. Netflix picked: the control says it, the list is Netflix's
    /// popular movies, Sort is back on Popular and offers only Popular, Top
    /// Rated and New, Genre only the genres TMDB knows; Menu closes a menu
    /// and nothing more; the list pages to its second page and ends there
    /// (the recorded page 3, past TMDB's last page, is never shown).
    func testTheMoviesGridsServiceControlFiltersAndPages() throws {
        launch(key: Self.key, ["-PTDebugTab", "movies"])
        let grid = self.grid("MoviesViewController")
        let sort = element("GridHeader.Sort"), genre = element("GridHeader.Genre"), service = element("GridHeader.Service")
        _ = try focusPoster(in: grid)
        XCTAssertTrue(service.exists, "no Service control with a key")
        XCTAssertEqual(service.frame.midY, sort.frame.midY, accuracy: 2, "Service is not on the header's line")
        XCTAssertGreaterThan(service.frame.minX, genre.frame.maxX, "Service is not after Genre")
        if isEnglish { XCTAssertEqual(service.label, "Service: All") }
        snap("movies-key")

        try focus(service, from: grid)
        remote.press(.select)
        let netflixEntry = menuEntry("Netflix")
        XCTAssertTrue(netflixEntry.waitForExistence(timeout: 5), "the services did not open")
        pause(1)
        snap("movies-service-menu")
        // The menu opens on its current entry, « All »: Netflix is next.
        remote.press(.down)
        pause(1)
        remote.press(.select)
        pause(1.5)
        XCTAssertFalse(netflixEntry.exists, "the services did not close")
        XCTAssertTrue(service.label.hasSuffix("Netflix"), "Service does not say Netflix: \(service.label)")
        if isEnglish { XCTAssertEqual(sort.label, "Sort: Popular", "Sort was not put back to an order Netflix's list follows") }
        XCTAssertTrue(waitUntil(timeout: 20) { grid.cells.firstMatch.label.hasPrefix("Heart of the Beast") },
                      "the grid is not Netflix's popular movies: \(grid.cells.firstMatch.label)")
        pause(2)
        snap("movies-netflix")

        // Sort: Popular, Top Rated, New; Menu closes the menu only.
        try focus(sort, from: grid)
        remote.press(.select)
        if isEnglish {
            XCTAssertTrue(menuEntry("Top Rated").waitForExistence(timeout: 5), "the sorts did not open")
            pause(1)
            snap("movies-netflix-sort-menu")
            XCTAssertTrue(menuEntry("Popular").exists && menuEntry("New").exists, "Popular / New are not offered")
            for absent in ["Trending", "Top 100", "Recently Added"] {
                XCTAssertFalse(menuEntry(absent).exists, "\(absent) is offered with a service")
            }
        } else {
            pause(2)
            snap("movies-netflix-sort-menu")
        }
        remote.press(.menu)
        pause(1.5)
        expectMenuClosedOnly(on: sort, grid: grid, what: "the sorts")

        // Genre: TMDB's genres only; Menu closes the menu only.
        remote.press(.right)
        pause(1)
        XCTAssertTrue(genre.hasFocus, "Genre never got the focus: \(focusedLabel)")
        remote.press(.select)
        if isEnglish {
            XCTAssertTrue(menuEntry("Action").waitForExistence(timeout: 5), "the genres did not open")
        } else {
            pause(2)
        }
        snap("movies-netflix-genre-menu")
        // The end of the list (the menu draws only the entries in view):
        // Music, which TMDB has for movies; no Sports between Science
        // Fiction and Thriller (nor Film Noir: HomeStreamingTests has the
        // whole list).
        for _ in 0..<22 {
            remote.press(.down)
            pause(0.3)
        }
        pause(1)
        snap("movies-netflix-genre-menu-end")
        if isEnglish {
            XCTAssertTrue(menuEntry("Western").exists && menuEntry("Science Fiction").exists && menuEntry("Thriller").exists,
                          "the end of the genres is not in view")
            XCTAssertTrue(menuEntry("Music").exists, "Music is not offered (TMDB has it for movies)")
            XCTAssertFalse(menuEntry("Sports").exists, "Sports is offered with a service (TMDB has no such genre)")
        }
        remote.press(.menu)
        pause(1.5)
        expectMenuClosedOnly(on: genre, grid: grid, what: "the genres")

        // The Service menu too.
        remote.press(.right)
        pause(1)
        XCTAssertTrue(service.hasFocus, "Service never got the focus: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(menuEntry("Netflix").waitForExistence(timeout: 5), "the services did not open again")
        pause(1)
        remote.press(.menu)
        pause(1.5)
        expectMenuClosedOnly(on: service, grid: grid, what: "the services")

        // The second page: page 2's titles in rows three and four, then the end.
        remote.press(.down)
        pause(1.2)
        for _ in 0..<3 {
            remote.press(.down)
            pause(1.5)
        }
        snap("movies-netflix-page-2")
        let secondPage = ["The Dog Stars", "Project Hail Mary", "Coraline", "Disclosure Day", "Love of Your Life"]
        XCTAssertTrue(waitUntil(timeout: 15) { grid.cells.allElementsBoundByIndex.contains { cell in secondPage.contains { cell.label.hasPrefix($0) } } },
                      "the grid never showed Netflix's second page")
        XCTAssertFalse(element("Grid.Retry").exists, "an error footer at the end of Netflix's list")

        // The end: page 2 says it is TMDB's last. A page 3 is recorded with
        // titles of its own, so a grid that asked past the end would show them.
        for _ in 0..<3 {
            remote.press(.down)
            pause(1.5)
        }
        pause(3)
        snap("movies-netflix-end")
        let pastTheEnd = ["MobLand", "Nocturne", "Black Doves", "Dexter: Resurrection", "VisionQuest", "Black Clover"]
        let asked = grid.cells.allElementsBoundByIndex.map(\.label).filter { label in pastTheEnd.contains { label.hasPrefix($0) } }
        XCTAssertEqual(asked, [], "the grid asked past TMDB's last page")
        XCTAssertFalse(element("Grid.Retry").exists, "an error footer at the end of Netflix's list")
    }

    // MARK: - Settings

    /// Settings › Streaming Services with a key: Menu in the key sheet, in
    /// the country picker and in the services picker closes it, the focus
    /// back on its row, Settings still on screen.
    func testMenuClosesTheKeySheetAndTheStreamingPickersOnly() throws {
        for (row, sheet) in [("tmdbKey", "Settings.TextSheet"), ("streamingRegion", "Settings.Picker"), ("streamingServices", "Settings.Picker")] {
            launch(key: Self.key, ["-PTDebugTab", "settings", "-PTDebugFocusContent", "YES", "-PTDebugSettingsRow", row])
            let rowElement = element("Settings.Row.\(row)")
            XCTAssertTrue(rowElement.waitForExistence(timeout: 15), "the \(row) row never showed")
            pause(2)
            if !rowElement.hasFocus {
                remote.press(.down)
                pause(1)
            }
            XCTAssertTrue(rowElement.hasFocus, "the \(row) row never got the focus: \(focusedLabel)")
            snap("settings-\(row)-row")
            remote.press(.select)
            XCTAssertTrue(element(sheet).waitForExistence(timeout: 5), "\(row): \(sheet) did not open")
            pause(1.5)
            snap("settings-\(row)-sheet")
            remote.press(.menu)
            pause(1.5)
            XCTAssertFalse(element(sheet).exists, "\(row): Menu did not close \(sheet)")
            XCTAssertEqual(app.state, .runningForeground, "\(row): Menu left the app")
            XCTAssertEqual(selectedTab, "settings", "\(row): Menu left Settings")
            XCTAssertTrue(rowElement.hasFocus, "\(row): the focus did not go back to the row: \(focusedLabel)")
            app.terminate()
        }
    }

    /// The key sheet shows a QR code (TMDB's API page, for a phone) with or
    /// without a key, and « Check Again » only with one. Check Again asks
    /// the recorded answers, which take any key: the sheet closes, the
    /// verdict says the saved key is accepted, the row still says « Set ».
    /// Menu on Check Again closes the sheet only, as on its other buttons.
    func testTheKeySheetShowsAQRCodeAndChecksAStoredKeyAgain() throws {
        for key in [nil, Self.key] {
            let name = key == nil ? "no-key" : "key"
            let (row, sheet) = openKeySheet(key: key)
            let qr = element("Settings.TMDBKey.QR"), check = element("Settings.TMDBKey.Check")
            snap("key-sheet-\(name)")
            XCTAssertTrue(qr.exists, "\(name): no QR code in the key sheet")
            XCTAssertGreaterThan(qr.frame.width, 200, "\(name): the QR code is too small to scan: \(qr.frame)")
            XCTAssertTrue(app.windows.firstMatch.frame.contains(qr.frame), "\(name): the QR code is not whole on the screen")
            XCTAssertTrue(element("Settings.TMDBKey.Field").hasFocus, "\(name): the field does not have the focus: \(focusedLabel)")
            guard key != nil else {
                XCTAssertFalse(check.exists, "« Check Again » without a key")
                app.terminate()
                continue
            }
            XCTAssertTrue(check.exists, "no « Check Again » with a key")
            XCTAssertTrue(focusOnButton(check), "« Check Again » never got the focus: \(focusedLabel)")
            pause(1)
            snap("key-sheet-check-focused")
            // Menu on the button: the sheet closes, the focus back on the row.
            remote.press(.menu)
            pause(1.5)
            XCTAssertFalse(sheet.exists, "Menu did not close the key sheet")
            XCTAssertEqual(selectedTab, "settings", "Menu left Settings")
            XCTAssertTrue(row.hasFocus, "Menu did not give the focus back to the row: \(focusedLabel)")

            // Again, and this time Check Again.
            remote.press(.select)
            XCTAssertTrue(sheet.waitForExistence(timeout: 5), "the key sheet did not open again")
            pause(1.5)
            XCTAssertTrue(focusOnButton(check), "« Check Again » never got the focus: \(focusedLabel)")
            remote.press(.select)
            let alert = app.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 10), "no verdict after Check Again")
            pause(1)
            snap("key-check-verdict")
            XCTAssertFalse(sheet.exists, "the sheet is still open behind the verdict")
            if isEnglish {
                XCTAssertTrue(alert.staticTexts["TMDB accepts the saved key."].exists, "not the accepted verdict: \(alert.debugDescription)")
            }
            remote.press(.select)
            XCTAssertTrue(waitUntil(timeout: 5) { !alert.exists }, "the verdict did not close")
            pause(1)
            if isEnglish { XCTAssertTrue(row.label.contains("Set"), "the key row does not say Set: \(row.label)") }
            XCTAssertEqual(selectedTab, "settings", "the verdict left Settings")
            app.terminate()
        }
    }

    // MARK: - Steps

    /// Settings with the focus on the key row, then its sheet open.
    private func openKeySheet(key: String?) -> (row: XCUIElement, sheet: XCUIElement) {
        launch(key: key, ["-PTDebugTab", "settings", "-PTDebugFocusContent", "YES", "-PTDebugSettingsRow", "tmdbKey"])
        let row = element("Settings.Row.tmdbKey"), sheet = element("Settings.TextSheet")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the key row never showed")
        pause(2)
        if !row.hasFocus {
            remote.press(.down)
            pause(1)
        }
        XCTAssertTrue(row.hasFocus, "the key row never got the focus: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "the key sheet did not open")
        pause(1.5)
        return (row, sheet)
    }

    /// Down from the field to the sheet's buttons, then sideways to `button`.
    private func focusOnButton(_ button: XCUIElement) -> Bool {
        for _ in 0..<6 where !button.hasFocus {
            remote.press(element("Settings.TMDBKey.Field").hasFocus ? .down : (button.frame.minX < focusedElement.frame.minX ? .left : .right))
            pause(1)
        }
        return button.hasFocus
    }

    /// `key`: nil runs without a key (an empty one in the arguments domain
    /// hides one a simulator may have saved).
    private func launch(key: String?, _ arguments: [String]) {
        let app = XCUIApplication()
        let locale = language == "fr" ? "fr_FR" : "en_US"
        app.launchArguments = [
            "-tosAccepted", "YES",
            "-lastWhatsNewVersion", "99",
            "-themeSongVolume", "0",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
            "-PTDebugLibraryInMemory", "YES",
            "-PTDebugHomeFixtures", Self.fixtures,
            "-PTDebugHomeDryRunPlay", "YES",
            "-PTDebugHomeHero", "0",
            "-popcornkit.tmdb.apiKey", key ?? "",
            "-popcornkit.home.streamingRegion", "FR",
        ] + arguments
        // `PT_UITEST_HOME_TRACE=<folder>`: the Home's focus trace of each launch.
        if let folder = ProcessInfo.processInfo.environment["PT_UITEST_HOME_TRACE"], !folder.isEmpty {
            let test = name.components(separatedBy: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "]")) ?? "test"
            app.launchArguments += ["-PTDebugHomeTrace", "\(folder)/\(test).txt"]
        }
        app.launch()
        self.app = app
    }

    /// The recorded answers, read by the app from the source tree (the
    /// simulator shares the Mac's disk).
    private static var fixtures: String {
        if let folder = ProcessInfo.processInfo.environment["PT_UITEST_HOME_FIXTURES"], !folder.isEmpty { return folder }
        return URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PopcornTimeTests/Fixtures/Home").path
    }

    /// A menu closed by Menu: the control it opened from has the focus, the
    /// grid and its tab are still there.
    private func expectMenuClosedOnly(on control: XCUIElement, grid: XCUIElement, what: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "Menu in \(what) left the app", file: file, line: line)
        XCTAssertEqual(selectedTab, "movies", "Menu in \(what) left the Movies tab", file: file, line: line)
        XCTAssertTrue(grid.exists, "Menu in \(what) left the grid", file: file, line: line)
        XCTAssertTrue(control.hasFocus, "Menu in \(what) did not give the focus back to its control: \(focusedLabel)", file: file, line: line)
        XCTAssertFalse(tabBarHasFocus, "Menu in \(what) went to the tab bar", file: file, line: line)
    }

    /// `card` is drawn as the focused card is: larger than `other`, a card
    /// of the same row at rest.
    private func looksFocused(_ card: XCUIElement, beside other: XCUIElement) -> Bool {
        return card.exists && other.exists && card.frame.width > other.frame.width + 10
    }

    private func waitForFocus(on element: XCUIElement, timeout: TimeInterval = 20) -> Bool {
        // A query, not the element: one drawn again between two reads is
        // not a failure.
        let focused = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND hasFocus == true", element.identifier)).firstMatch
        return waitUntil(timeout: timeout) { focused.exists }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pause(0.5)
        }
        return condition()
    }

    /// Presses down until one of `grid`'s posters has the focus.
    private func focusPoster(in grid: XCUIElement) throws -> XCUIElement {
        XCTAssertTrue(grid.waitForExistence(timeout: 20), "no grid")
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 60), "the grid never loaded")
        pause(1)
        for _ in 0..<5 {
            if let cell = focusedCell(in: grid) { return cell }
            remote.press(.down)
            pause(1)
        }
        if let cell = focusedCell(in: grid) { return cell }
        XCTFail("no poster ever got the focus")
        throw XCTSkip("unreachable")
    }

    /// Up from the posters to the header, then Right until `control` has the focus.
    private func focus(_ control: XCUIElement, from grid: XCUIElement) throws {
        for _ in 0..<8 where !control.hasFocus {
            if focusedCell(in: grid) != nil {
                remote.press(.up)
            } else if tabBarHasFocus {
                remote.press(.down)
            } else if element("GridHeader.Service").hasFocus, control.identifier != "GridHeader.Service" {
                remote.press(.left)
            } else if element("GridHeader.Genre").hasFocus, control.identifier == "GridHeader.Sort" {
                remote.press(.left)
            } else {
                remote.press(.right)
            }
            pause(1)
        }
        XCTAssertTrue(control.hasFocus, "\(control.identifier) never got the focus: \(focusedLabel)")
    }

    private func grid(_ name: String) -> XCUIElement {
        return app.collectionViews["MediaGrid.\(name)"]
    }

    private func element(_ identifier: String) -> XCUIElement {
        return app.descendants(matching: .any)[identifier]
    }

    /// The identifiers of the Home's shelves on the screen.
    private func sections() -> [String] {
        let query = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'Home.Section.'"))
        return query.allElementsBoundByIndex.map(\.identifier)
    }

    /// An entry of an open menu.
    private func menuEntry(_ title: String) -> XCUIElement {
        return app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    private func focusedCell(in grid: XCUIElement) -> XCUIElement? {
        let cell = grid.cells.matching(Self.focused).firstMatch
        return cell.exists ? cell : nil
    }

    private var focusedElement: XCUIElement {
        app.descendants(matching: .any).matching(Self.focused).firstMatch
    }

    private var focusedIdentifier: String {
        let focused = focusedElement
        return focused.exists ? focused.identifier : "none"
    }

    private var focusedLabel: String {
        let focused = focusedElement
        return focused.exists ? (focused.label.isEmpty ? focused.identifier : focused.label) : "none"
    }

    private var tabBarHasFocus: Bool {
        return app.tabBars.descendants(matching: .any).matching(Self.focused).firstMatch.exists
    }

    /// The selected tab's name ("movies", "settings"…): the tab bar's identifier says it.
    private var selectedTab: String {
        let bar = app.tabBars.firstMatch
        guard bar.exists else {
            let marker = app.descendants(matching: .any)["Debug.SelectedTab"]
            return marker.exists ? marker.label : "none (no tab bar)"
        }
        let identifier = bar.identifier
        return identifier.hasPrefix("TabBar.") ? String(identifier.dropFirst("TabBar.".count)) : "none (\(identifier))"
    }

    private func waitUntilLeft(timeout: TimeInterval = 8) -> Bool {
        if app.wait(for: .runningBackground, timeout: timeout) { return true }
        return [.runningBackgroundSuspended, .notRunning].contains(app.state)
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func snap(_ step: String) {
        guard let folder = ProcessInfo.processInfo.environment["PT_UITEST_SHOTS"], !folder.isEmpty else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(step).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
