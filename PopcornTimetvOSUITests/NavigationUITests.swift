import XCTest

/// The Siri Remote on the tvOS app: Menu (Back) goes one level back from every
/// screen (also while a screen still slides in), on another tab's first
/// screen it goes to Home, on Home it leaves the app, and a grid comes back exactly as it was left. A grid's
/// title and Sort / Genre scroll with its posters, the tab bar follows the
/// scroll, and Up goes from the first row to Sort / Genre, then the tab bar.
///
/// Runs on the tvOS 26.5 simulator against a DEBUG build of the app (its
/// launch hooks: build with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`).
/// The grids and pages read the public catalog APIs, so the simulator needs
/// the network. Nothing is ever played: the quality chooser is opened by the
/// `-PTDebugQualityPicker` hook, whose pick only logs, and Select is never
/// pressed on Play. Preferences come from launch arguments (the argument
/// domain): nothing is written to the app's own defaults by the tests.
///
/// A tab is asked for by its name (`-PTDebugTab movies`), never by its place
/// in the bar: Home is the first tab and the one the app opens on. Its hub
/// is fed from recorded answers (`-PTDebugHomeFixtures`, like
/// `HomeUITests`): these tests are about the other screens, and Home's own
/// requests would only add to what the simulator loads.
///
/// `PT_UITEST_SHOTS=<folder>` in the environment of the test runner
/// (`TEST_RUNNER_PT_UITEST_SHOTS` on the xcodebuild command line) saves a
/// screenshot before every remote press, at the end of each test, and while
/// a grid comes back.
final class NavigationUITests: XCTestCase {

    private let remoteControl = XCUIRemote.shared
    private var app: XCUIApplication!
    /// Screenshots of this test (`PT_UITEST_SHOTS`): numbered in order.
    private var shotIndex = 0

    /// The remote, with a screenshot saved before each press (`PT_UITEST_SHOTS`).
    private var remote: Remote { Remote(test: self) }

    private struct Remote {
        let test: NavigationUITests
        func press(_ button: XCUIRemote.Button) {
            test.snap("before-\(Remote.name(button))")
            test.remoteControl.press(button)
        }
        static func name(_ button: XCUIRemote.Button) -> String {
            switch button {
            case .up: return "up"
            case .down: return "down"
            case .left: return "left"
            case .right: return "right"
            case .select: return "select"
            case .menu: return "menu"
            case .playPause: return "playpause"
            case .home: return "home"
            default: return "other"
            }
        }
    }

    /// Saves a screenshot named after the test and the step.
    fileprivate func snap(_ step: String) {
        guard ProcessInfo.processInfo.environment["PT_UITEST_SHOTS"]?.isEmpty == false else { return }
        let test = name.components(separatedBy: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "]")) ?? "test"
        shotIndex += 1
        save(XCUIScreen.main.screenshot(), "\(test)/\(String(format: "%02d", shotIndex))-\(step)")
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        snap("end")
        app?.terminate()
        app = nil
        super.tearDown()
    }

    // MARK: - Grids

    /// Top 100 → a movie's page → Menu: the grid is back with the focus on
    /// the poster that was opened, at the same place, and does not move once
    /// it is back (it used to jump and then settle).
    func testBackFromAMoviePageRestoresTheTop100Grid() throws {
        launch(["-PTDebugTab", "movies", "-PTDebugFilter", "top100"])
        try checkBackRestoresGrid(named: "MoviesViewController", shotsLabel: "top100")
    }

    /// The same on the Movies tab's default list (Trending, paginated).
    func testBackFromAMoviePageRestoresTheTrendingGrid() throws {
        launch(["-PTDebugTab", "movies"])
        try checkBackRestoresGrid(named: "MoviesViewController", shotsLabel: "trending")
    }

    /// The same on the Shows tab (Top 100).
    func testBackFromAShowPageRestoresTheShowsGrid() throws {
        launch(["-PTDebugTab", "shows", "-PTDebugFilter", "top100"])
        try checkBackRestoresGrid(named: "ShowsViewController", shotsLabel: "shows-top100")
    }

    /// Menu right after Select (the page still sliding in, its sources still
    /// loading) goes back to the grid, and the page does not come back
    /// afterwards.
    func testMenuWhileThePageSlidesInGoesBackToTheGrid() throws {
        launch(["-PTDebugTab", "movies"])
        let grid = grid(named: "MoviesViewController")
        let cell = try focusPoster(in: grid)
        let label = cell.label
        // No screenshot between the two presses: Menu while the page still
        // slides in.
        remoteControl.press(.select)
        pause(0.25)
        remoteControl.press(.menu)
        pause(6)
        XCTAssertEqual(app.state, .runningForeground, "Menu on the page sliding in left the app")
        XCTAssertFalse(detailTitle.exists, "the page stayed, or came back, after Menu was pressed while it slid in")
        XCTAssertEqual(focusedCell(in: grid)?.label, label, "the focus is not back on the poster")
    }

    /// Menu on a tab's grid goes to Home, then leaves the app for the Home
    /// screen.
    func testMenuOnAGridGoesHomeThenToTheHomeScreen() throws {
        launch(["-PTDebugTab", "shows"])
        _ = try focusPoster(in: grid(named: "ShowsViewController"))
        expectMenuGoesHomeThenLeavesTheApp("Shows grid")
    }

    // MARK: - The grid's header

    /// Movies (Top 100): the page title and Sort / Genre are part of the
    /// page, as on every tvOS screen. Two rows down they have scrolled away
    /// with the first row (they stayed and were drawn over the posters) and
    /// the tab bar is out of the way; back on the first row, the title,
    /// Sort / Genre and the tab bar are back where they were.
    func testTheGridHeaderScrollsWithThePosters() throws {
        launch(["-PTDebugTab", "movies", "-PTDebugFilter", "top100"])
        try checkHeaderScrollsWithThePosters(of: "MoviesViewController", title: "Movies", shotsLabel: "header-movies")
    }

    /// The same on the Shows tab (its default list, paginated).
    func testTheShowsGridHeaderScrollsWithThePosters() throws {
        launch(["-PTDebugTab", "shows"])
        try checkHeaderScrollsWithThePosters(of: "ShowsViewController", title: "Shows", shotsLabel: "header-shows")
    }

    /// Up from the first row reaches Sort / Genre, even from the first
    /// column (the farthest from them), then the tab bar on the tab that was
    /// selected; Down from the tab bar goes back into the page. A genre
    /// picked with Genre is what the Genre control says; the page keeps
    /// its title.
    func testUpFromTheFirstRowReachesSortGenreThenTheTabBar() throws {
        launch(["-PTDebugTab", "movies"])
        let grid = grid(named: "MoviesViewController")
        let sort = element("GridHeader.Sort"), genre = element("GridHeader.Genre"), title = element("GridHeader.Title")
        _ = try focusPoster(in: grid)
        for _ in 0..<6 {
            guard let cell = focusedCell(in: grid), cell.frame.minX > 200 else { break }
            remote.press(.left)
            pause(0.6)
        }
        guard let first = focusedCell(in: grid), first.frame.minX < 200 else { return XCTFail("the first column never got the focus") }
        let firstRowMinY = first.frame.minY
        XCTAssertFalse(element("GridHeader.Service").exists, "a Service control without a TMDB key")
        remote.press(.up)
        pause(1.2)
        XCTAssertTrue(sort.hasFocus || genre.hasFocus, "Up from the first row did not reach Sort / Genre: \(focusedLabel)")
        remote.press(.up)
        pause(1.2)
        XCTAssertTrue(tabBarHasFocus, "Up from Sort / Genre did not reach the tab bar: \(focusedLabel)")
        XCTAssertEqual(focusedLabel, "Movies", "Up from Sort / Genre went to another tab")
        XCTAssertTrue(grid.exists, "the Movies grid is gone")
        remote.press(.down)
        pause(1.5)
        XCTAssertFalse(tabBarHasFocus, "Down from the tab bar did not go back into the page")
        XCTAssertTrue(sort.hasFocus || genre.hasFocus || focusedCell(in: grid) != nil,
                      "Down from the tab bar went outside the page: \(focusedLabel)")
        if let cell = focusedCell(in: grid) {
            XCTAssertEqual(cell.frame.minY, firstRowMinY, accuracy: 2, "Down from the tab bar did not land on the first row")
        }

        // Genre: the control says the genre picked, the title stays.
        for _ in 0..<3 where !genre.hasFocus {
            remote.press(sort.hasFocus ? .right : .up)
            pause(1)
        }
        guard genre.hasFocus else { return XCTFail("Genre never got the focus: \(focusedLabel)") }
        let genreBefore = genre.label
        remote.press(.select)
        // A menu anchored to the control: its current entry ("All") shows.
        let current = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "All")).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 5), "the genres did not open")
        pause(1)
        XCTAssertFalse(genre.hasFocus, "the focus stayed on Genre")
        remote.press(.down)
        pause(1)
        let picked = focusedLabel
        remote.press(.select)
        pause(2)
        XCTAssertFalse(current.exists, "the genres did not close")
        XCTAssertNotEqual(genre.label, genreBefore, "Genre still says the genre before")
        XCTAssertTrue(genre.label.hasPrefix("Genre: "), "Genre does not say a genre: \(genre.label)")
        if !["none", "", "All"].contains(picked) {
            XCTAssertEqual(genre.label, "Genre: \(picked)", "Genre does not say the genre picked")
        }
        XCTAssertEqual(title.label, "Movies", "the page title changed with the genre")
    }

    // MARK: - Detail page

    /// The full summary: Menu closes it (the page stays), Menu again leaves
    /// the page.
    func testMenuClosesTheSummaryThenLeavesThePage() throws {
        // A show: its summary is long enough to be cut at three lines.
        launch(["-PTDebugTab", "shows", "-PTDebugOpenShow", "tt0903747", "-PTDebugFocusContent", "YES"])
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 60), "the page never opened")
        pause(3)
        // Play (or Watchlist) has the focus; the summary card is above it.
        remote.press(.up)
        pause(1)
        let summary = element("Detail.Summary")
        guard summary.exists, summary.hasFocus else {
            throw XCTSkip("this title's summary fits: no full summary to open")
        }
        remote.press(.select)
        let sheet = element("Detail.TextSheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 3), "the full summary did not open")
        remote.press(.menu)
        pause(1)
        XCTAssertFalse(sheet.exists, "Menu did not close the full summary")
        XCTAssertTrue(detailTitle.exists, "Menu on the full summary left the page")
        XCTAssertTrue(summary.hasFocus, "the focus did not go back to the summary")
        remote.press(.menu)
        pause(2)
        XCTAssertFalse(detailTitle.exists, "Menu did not leave the page")
        XCTAssertEqual(app.state, .runningForeground, "Menu on the page left the app")
        XCTAssertTrue(grid(named: "ShowsViewController").exists, "the grid is not back")
    }

    /// From the lowest shelves of a page (related titles, cast, information),
    /// Menu leaves the page in one press.
    func testMenuLeavesThePageFromItsShelves() throws {
        launch(["-PTDebugTab", "movies"])
        let grid = grid(named: "MoviesViewController")
        let label = try openPoster(in: grid)
        pause(4) // related titles and cast arrive after the page
        for _ in 0..<4 {
            remote.press(.down)
            pause(0.8)
        }
        remote.press(.menu)
        try expectGridBack(grid, focusedOn: label)
    }

    /// A show's page: from the episodes (season pills, episode cards) Menu
    /// leaves the page in one press.
    func testMenuLeavesAShowPageFromTheEpisodes() throws {
        launch(["-PTDebugTab", "shows"])
        let grid = grid(named: "ShowsViewController")
        let label = try openPoster(in: grid)
        pause(2)
        remote.press(.down)
        pause(1)
        remote.press(.down)
        pause(1)
        remote.press(.menu)
        try expectGridBack(grid, focusedOn: label)
    }

    /// The quality chooser: Menu closes it and the page stays; Menu again
    /// leaves the page. (The chooser comes from the DEBUG hook: a pick would
    /// only log.)
    func testMenuClosesTheQualityChooserThenLeavesThePage() throws {
        launch(["-PTDebugTab", "movies", "-PTDebugOpenItem", "0", "-PTDebugFocusContent", "YES",
                "-PTDebugQualityPicker", "YES"])
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 60), "the page never opened")
        let chooser = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Choose Quality'")).firstMatch
        XCTAssertTrue(chooser.waitForExistence(timeout: 30), "the quality chooser never showed")
        pause(1.5)
        remote.press(.menu)
        pause(1.5)
        XCTAssertFalse(chooser.exists, "Menu did not close the quality chooser")
        XCTAssertTrue(detailTitle.exists, "Menu on the quality chooser left the page")
        remote.press(.menu)
        pause(1.5)
        XCTAssertFalse(detailTitle.exists, "Menu did not leave the page after the chooser")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// A title whose record and sources take long: its page is there at once
    /// (no loading screen any more), Play holds the focus (it fell into the
    /// tab bar on the loading screen of 5.2, where Menu left the app), and
    /// Menu goes back to the grid; nothing opens later.
    func testMenuOnAPageStillLoadingGoesBackToTheGrid() throws {
        launch(["-PTDebugTab", "movies", "-PTDebugOpenMovie", "tt15239678", "-PTDebugFocusContent", "YES",
                "-PTDebugDetailMetadataDelay", "40", "-PTDebugDetailSourcesDelay", "40"])
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 20), "the page did not open before its record")
        XCTAssertFalse(loadingScreen.exists, "a loading screen showed")
        let play = element("Detail.Play")
        XCTAssertTrue(play.waitForExistence(timeout: 5), "no Play button on a page still loading")
        pause(3)
        XCTAssertFalse(tabBarHasFocus, "the focus fell into the tab bar on a page still loading: \(focusedLabel)")
        XCTAssertTrue(labelled("Looking for sources…").exists, "the page does not say its sources are searched")
        remote.press(.menu)
        pause(2)
        XCTAssertEqual(app.state, .runningForeground, "Menu on a page still loading left the app")
        XCTAssertFalse(detailTitle.exists, "Menu did not leave the page")
        XCTAssertTrue(grid(named: "MoviesViewController").exists, "the grid is not back")
        pause(3)
        XCTAssertFalse(detailTitle.exists, "a page opened after Menu")
    }

    /// A title that cannot be loaded (a movie's id opened as a show): the
    /// page says why and offers "Try Again", which holds the focus, and Menu
    /// still goes back to the grid.
    func testMenuOnAPageThatFailedGoesBackToTheGrid() throws {
        launch(["-PTDebugTab", "shows", "-PTDebugOpenShow", "tt0111161", "-PTDebugFocusContent", "YES"])
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 20), "the page did not open at once")
        let failure = element("Detail.LoadError")
        guard failure.waitForExistence(timeout: 45) else { throw XCTSkip("no failure: the title loaded or never answered") }
        let retry = element("Detail.Retry")
        XCTAssertTrue(retry.exists, "no Try Again on a page that failed")
        XCTAssertFalse(element("Detail.Play").exists, "Play is offered on a page with nothing to play")
        pause(2.5)
        XCTAssertFalse(tabBarHasFocus, "the focus fell into the tab bar on the page that failed: \(focusedLabel)")
        remote.press(.menu)
        pause(2)
        XCTAssertEqual(app.state, .runningForeground, "Menu on the page that failed left the app")
        XCTAssertFalse(detailTitle.exists, "Menu did not leave the page that failed")
        XCTAssertTrue(grid(named: "ShowsViewController").exists, "the grid is not back")
    }

    /// Play pressed before the sources are in (a dry run: `-PTDebugPressPlay`,
    /// whose chooser only logs a pick): the press is kept, « Looking for
    /// sources… » comes over the page and takes the remote; Menu cancels it —
    /// the card goes, the page stays, nothing starts.
    func testMenuCancelsAPressThatWaitsForTheSources() throws {
        launch(["-PTDebugTab", "movies", "-PTDebugOpenMovie", "tt15239678", "-PTDebugFocusContent", "YES",
                "-PTDebugDetailSourcesDelay", "40", "-PTDebugPressPlay", "4"])
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 20), "the page never opened")
        // The page's own quiet line has the same words as the card: the
        // card is one more element saying them.
        let saying = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Looking for sources…"))
        pause(1.5)
        let onThePage = saying.count
        XCTAssertGreaterThan(onThePage, 0, "the page does not say its sources are searched")
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, saying.count <= onThePage { pause(0.5) }
        XCTAssertGreaterThan(saying.count, onThePage, "the card of a press that waits for the sources did not come")
        remote.press(.menu)
        pause(2)
        XCTAssertEqual(saying.count, onThePage, "Menu did not close the card")
        XCTAssertTrue(detailTitle.exists, "Menu on the card left the page")
        XCTAssertFalse(labelled("Choose Quality").exists, "a chooser came after the press was cancelled")
        remote.press(.menu)
        pause(2)
        XCTAssertFalse(detailTitle.exists, "Menu did not leave the page after the card")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Holding Select on a poster opens its menu (Play, watchlist, watched);
    /// Menu closes it and the poster keeps the focus. Nothing in it is chosen.
    func testLongPressOnAPosterOpensItsMenuAndMenuClosesIt() throws {
        launch(["-PTDebugTab", "movies"])
        let grid = grid(named: "MoviesViewController")
        let cell = try focusPoster(in: grid)
        let label = cell.label
        snap("before-long-select")
        remoteControl.press(.select, forDuration: 1.6)
        let watchlist = labelled("Add to Watchlist")
        XCTAssertTrue(watchlist.waitForExistence(timeout: 5), "the poster's menu did not open")
        XCTAssertTrue(labelled("Mark as Watched").exists || labelled("Mark as Unwatched").exists)
        remote.press(.menu)
        pause(1.5)
        XCTAssertFalse(watchlist.exists, "Menu did not close the poster's menu")
        XCTAssertFalse(detailTitle.exists, "the long press opened the page")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertEqual(focusedCell(in: grid)?.label, label, "the focus is not back on the poster")
    }

    // MARK: - Other tabs and screens

    /// Settings: Menu closes a choice sheet without changing anything, with
    /// the focus back on its row; Menu again goes to Home, then leaves the app.
    func testMenuOnSettingsClosesThePickerThenGoesHome() throws {
        launch(["-PTDebugTab", "settings", "-PTDebugFocusContent", "YES"])
        let picker = element("Settings.Picker")
        let row = element("Settings.Row.quality")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the Settings page never showed")
        pause(2)
        if !row.hasFocus {
            remote.press(.down)
            pause(1)
        }
        XCTAssertTrue(row.hasFocus, "the first Settings row never got the focus")
        remote.press(.select)
        XCTAssertTrue(picker.waitForExistence(timeout: 3), "the quality choices did not open")
        remote.press(.menu)
        pause(1)
        XCTAssertFalse(picker.exists, "Menu did not close the choices")
        XCTAssertTrue(row.hasFocus, "the focus did not go back to the row")
        expectMenuGoesHomeThenLeavesTheApp("Settings")
    }

    /// Search: from the keyboard, Menu goes to Home, then leaves the app.
    func testMenuOnSearchGoesHome() throws {
        launch(["-PTDebugTab", "search"])
        pause(3)
        remote.press(.down)
        pause(1.5)
        if tabBarHasFocus {
            remote.press(.down)
            pause(1.5)
        }
        XCTAssertFalse(tabBarHasFocus, "the focus never left the tab bar for the keyboard")
        expectMenuGoesHomeThenLeavesTheApp("Search")
    }

    /// Search with results: Up from a result goes back to the scope bar, the
    /// keyboard and the tab bar (a focus guide above the keyboard sent it
    /// back to the first result, so the tab bar could not be reached and Menu
    /// left the app); also once the results have scrolled down.
    func testUpFromSearchResultsReachesTheTabBar() throws {
        launch(["-PTDebugSearch", "star"])
        let results = grid(named: "SearchViewController")
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline, !(results.exists && results.cells.count > 3) { pause(1) }
        guard results.exists, results.cells.count > 3 else { throw XCTSkip("the search found too few results") }
        var downs: [String] = []
        for _ in 0..<6 where focusedCell(in: results) == nil {
            remote.press(.down)
            pause(1)
            downs.append(focusedLabel)
        }
        XCTAssertNotNil(focusedCell(in: results), "Down never reached the results: \(downs)")
        var ups: [String] = []
        for _ in 0..<4 where !tabBarHasFocus {
            remote.press(.up)
            pause(1)
            ups.append(focusedLabel)
        }
        XCTAssertTrue(tabBarHasFocus, "Up from a result never reached the tab bar: \(ups)")
        XCTAssertEqual(app.state, .runningForeground)

        // Two rows further down (the results scroll), then Up again.
        downs = []
        for _ in 0..<8 where focusedCell(in: results) == nil {
            remote.press(.down)
            pause(1)
            downs.append(focusedLabel)
        }
        guard focusedCell(in: results) != nil else { return XCTFail("Down never went back to the results: \(downs)") }
        for _ in 0..<2 {
            remote.press(.down)
            pause(1)
        }
        ups = []
        for _ in 0..<8 where !tabBarHasFocus {
            remote.press(.up)
            pause(1)
            ups.append(focusedLabel)
        }
        XCTAssertTrue(tabBarHasFocus, "Up from the third row of results never reached the tab bar: \(ups)")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Two pages deep (a page, then one of its related titles), Menu twice
    /// in quick succession: both pages close, the grid is back with the
    /// poster focused, and the app stays; Menu at the grid then leaves.
    func testMenuTwiceQuicklyFromTwoPagesGoesBackToTheGrid() throws {
        launch(["-PTDebugTab", "movies"])
        let grid = grid(named: "MoviesViewController")
        let label = try openPoster(in: grid)
        let firstTitle = detailTitle.label
        pause(2.5) // related titles arrive after the page
        var found = false
        for _ in 0..<5 {
            remote.press(.down)
            pause(1.2)
            let focused = focusedElement
            // A related title's poster: taller than wide, poster-sized.
            if focused.exists, focused.frame.height > focused.frame.width * 1.3, focused.frame.width > 150, focused.frame.width < 400 {
                found = true
                break
            }
        }
        guard found else { throw XCTSkip("no related title on this page") }
        remote.press(.select)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !(detailTitle.exists && detailTitle.label != firstTitle) { pause(0.5) }
        guard detailTitle.exists, detailTitle.label != firstTitle else { throw XCTSkip("the related title's page never opened") }
        pause(3)
        remoteControl.press(.menu)
        pause(0.15)
        remoteControl.press(.menu)
        pause(3)
        XCTAssertEqual(app.state, .runningForeground, "Menu twice from two pages left the app")
        XCTAssertFalse(detailTitle.exists, "Menu twice from two pages did not reach the grid")
        XCTAssertEqual(focusedCell(in: grid)?.label, label, "the focus is not back on the poster")
        pause(1.5)
        expectMenuGoesHomeThenLeavesTheApp("the grid after Menu twice")
    }

    /// Select on a poster, then Menu three times in quick succession while
    /// the page comes in: the grid stays, with the poster focused, no page
    /// opens later, and the app stays (5.1.0 crashed here).
    func testSelectThenMenuThreeTimesQuicklyStaysOnTheGrid() throws {
        launch(["-PTDebugTab", "movies", "-PTDebugFilter", "top100"])
        let grid = grid(named: "MoviesViewController")
        let label = try focusPoster(in: grid).label
        remoteControl.press(.select)
        for _ in 0..<3 {
            pause(0.1)
            remoteControl.press(.menu)
        }
        pause(5)
        XCTAssertEqual(app.state, .runningForeground, "Select then Menu three times left the app")
        XCTAssertFalse(detailTitle.exists || loadingScreen.exists, "a page or the loading screen is up after Menu")
        XCTAssertEqual(focusedCell(in: grid)?.label, label, "the focus is not back on the poster")
        expectMenuGoesHomeThenLeavesTheApp("the grid after Select then Menu three times")
    }

    /// The focus on a tab in the tab bar, at a tab's root (Movies, Shows,
    /// Settings, Home): Menu goes to Home, and from Home to the Home screen.
    func testMenuInTheTabBarAtATabsRootGoesHome() throws {
        for tab in ["movies", "shows", "settings", "home"] {
            launch(["-PTDebugTab", tab])
            pause(4)
            for _ in 0..<4 where !tabBarHasFocus {
                remote.press(.up)
                pause(0.8)
            }
            XCTAssertTrue(tabBarHasFocus, "tab \(tab): the tab bar never got the focus")
            if tab == "home" {
                remote.press(.menu)
                XCTAssertTrue(waitUntilLeft(), "Home: Menu in the tab bar did not go to the Home screen")
            } else {
                expectMenuGoesHomeThenLeavesTheApp("tab \(tab), in the tab bar")
            }
            app.terminate()
            pause(1)
        }
    }

    /// Downloads (empty on a fresh simulator) and Watchlist: Menu goes to
    /// Home, then leaves the app.
    func testMenuOnTheDownloadsAndWatchlistTabsGoesHome() throws {
        for tab in ["downloads", "watchlist"] {
            launch(["-PTDebugTab", tab])
            pause(3)
            remote.press(.down)
            pause(1)
            expectMenuGoesHomeThenLeavesTheApp("tab \(tab)")
            app.terminate()
        }
    }

    /// The release notes: Menu does what Continue does, and the app stays.
    func testMenuClosesWhatsNew() throws {
        launch(["-WhatsNewForce", "YES"])
        let continueButton = app.buttons["Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10), "What's New never showed")
        pause(1)
        remote.press(.menu)
        pause(1.5)
        XCTAssertFalse(continueButton.exists, "Menu did not close What's New")
        XCTAssertEqual(app.state, .runningForeground, "Menu on What's New left the app")
    }

    /// The Top 100 that cannot be reached (The Pirate Bay off, no cached
    /// list): the error is shown and Menu still goes to Home, then leaves
    /// the app.
    func testMenuOnTheTop100ErrorGoesHome() throws {
        launch(["-PTDebugTab", "movies", "-PTDebugFilter", "top100", "-PTDebugTop100Offline", "YES"])
        pause(8)
        remote.press(.down)
        pause(1)
        expectMenuGoesHomeThenLeavesTheApp("Top 100 error")
    }

    // MARK: - Links into the app

    /// A link to a show's page that comes while Settings is on screen: a tab
    /// that cannot show a page (the link did nothing there), the Shows tab
    /// never shown yet. The page opens on the Shows tab with the focus in it
    /// (not on a tab: the focus on another tab selects it), and Menu goes
    /// back to the Shows grid.
    func testALinkOpensAShowPageFromSettings() throws {
        launch(["-PTDebugTab", "settings", "-PTDebugOpenURL", "popcorntime://show/tt0903747"])
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 60), "the page never opened")
        pause(3)
        XCTAssertEqual(selectedTab, "shows", "the page is not on the Shows tab")
        XCTAssertFalse(tabBarHasFocus, "the focus stayed in the tab bar: \(focusedLabel)")
        remote.press(.menu)
        pause(2)
        XCTAssertFalse(detailTitle.exists, "Menu did not leave the page")
        XCTAssertEqual(app.state, .runningForeground, "Menu on the page left the app")
        XCTAssertTrue(grid(named: "ShowsViewController").exists, "the Shows grid is not there")
        XCTAssertEqual(selectedTab, "shows", "the app left the Shows tab")
    }

    /// A show link with a season opens the page on that season (Breaking
    /// Bad, nothing watched: the page would open on season 1).
    func testASeasonLinkOpensThePageOnThatSeason() throws {
        launch(["-PTDebugTab", "shows", "-PTDebugOpenURL", "popcorntime://show/tt0903747?season=3&episode=5"])
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 60), "the page never opened")
        let seasonThree = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "S3 · E")).firstMatch
        XCTAssertTrue(seasonThree.waitForExistence(timeout: 30), "no episode of season 3 on the page")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "S1 · E")).firstMatch.exists,
                       "the page shows season 1")
    }

    /// A link to the page already on top (the Top Shelf picked twice, a
    /// link to another episode of the show on screen) does not push a second
    /// page: the one shown takes the link's season, and one Menu goes back
    /// to the grid.
    func testALinkToThePageOnTopDoesNotOpenItTwice() throws {
        launch(["-PTDebugTab", "shows", "-PTDebugOpenURL", "popcorntime://show/tt0903747",
                "-PTDebugOpenURL2", "popcorntime://show/tt0903747?season=3&episode=5", "-PTDebugOpenURL2After", "8",
                "-PTDebugFocusContent", "YES"])
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 60), "the page never opened")
        let seasonOne = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "S1 · E")).firstMatch
        XCTAssertTrue(seasonOne.waitForExistence(timeout: 30), "the page did not open on season 1")
        let second = NSPredicate(format: "label == %@", "opened twice")
        expectation(for: second, evaluatedWith: linkResult)
        waitForExpectations(timeout: 40)
        let seasonThree = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "S3 · E")).firstMatch
        XCTAssertTrue(seasonThree.waitForExistence(timeout: 10), "the second link did not select its season on the page shown")
        XCTAssertFalse(seasonOne.exists, "the page still shows season 1")
        pause(2)
        remote.press(.menu)
        pause(2.5)
        XCTAssertFalse(detailTitle.exists, "a second copy of the page was under the first")
        XCTAssertTrue(grid(named: "ShowsViewController").exists, "the grid is not back")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// A link that comes while a Settings choice is open (a SwiftUI sheet
    /// the link must not close) waits for it: Menu closes the choice, then
    /// the page opens on the Shows tab.
    func testALinkWaitsForASettingsChoiceToClose() throws {
        launch(["-PTDebugTab", "settings", "-PTDebugOpenURL", "popcorntime://show/tt0903747",
                "-PTDebugOpenURLAfter", "12"])
        let picker = element("Settings.Picker")
        let row = element("Settings.Row.quality")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the Settings page never showed")
        pause(2)
        // Down from the Settings tab lands on the right column (Version):
        // then left, and up to the first row.
        for direction: XCUIRemote.Button in [.down, .left, .up, .up, .up, .up] where !row.hasFocus {
            remote.press(direction)
            pause(1)
        }
        XCTAssertTrue(row.hasFocus, "the first Settings row never got the focus")
        remote.press(.select)
        XCTAssertTrue(picker.waitForExistence(timeout: 3), "the quality choices did not open")
        XCTAssertTrue(linkResult.waitForExistence(timeout: 40), "the link never reached the link handler")
        XCTAssertEqual(linkResult.label, "refused", "the link was opened under the choices")
        pause(2)
        XCTAssertTrue(picker.exists, "the link closed the choices")
        XCTAssertFalse(detailTitle.exists || loadingScreen.exists, "a page opened under the choices")
        remote.press(.menu)
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 60), "the page never opened once the choices closed")
        pause(2)
        XCTAssertEqual(selectedTab, "shows", "the page is not on the Shows tab")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The same once the Shows tab has been shown and left for Downloads
    /// with the remote: the link comes 25 s after the launch.
    func testALinkOpensAShowPageOnATabShownBefore() throws {
        launch(["-PTDebugTab", "shows", "-PTDebugOpenURL", "PopcornTime://show/tt0903747?title=Breaking%20Bad",
                "-PTDebugOpenURLAfter", "24"])
        XCTAssertTrue(grid(named: "ShowsViewController").waitForExistence(timeout: 10), "no Shows grid")
        pause(2)
        for _ in 0..<4 where !tabBarHasFocus {
            remote.press(.up)
            pause(0.8)
        }
        XCTAssertTrue(tabBarHasFocus, "the tab bar never got the focus")
        for _ in 0..<6 where selectedTab != "downloads" {
            remote.press(.right)
            pause(0.8)
        }
        XCTAssertEqual(selectedTab, "downloads", "the remote never reached the Downloads tab")
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 60), "the page never opened")
        pause(3)
        XCTAssertEqual(selectedTab, "shows", "the page is not on the Shows tab")
        XCTAssertFalse(tabBarHasFocus, "the focus stayed in the tab bar: \(focusedLabel)")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// A link picked while the app is in the background (the Top Shelf),
    /// the app left on Settings with the focus on that tab: back in the
    /// foreground, the app shows the page on the Shows tab. (tvOS gives the
    /// focus back to the Settings tab then, and selects a tab 0.3 s after
    /// the focus lands on it.) The remote's TV button leaves the app: Menu
    /// there would go to Home first, and the app would not be left on
    /// Settings.
    func testALinkPickedInTheBackgroundOpensItsPage() throws {
        launch(["-PTDebugTab", "settings", "-PTDebugActivationURL", "popcorntime://show/tt0903747"])
        XCTAssertTrue(element("Settings.Row.quality").waitForExistence(timeout: 10), "the Settings page never showed")
        pause(2)
        XCTAssertTrue(tabBarHasFocus, "the focus is not on the Settings tab")
        remote.press(.home)
        XCTAssertTrue(waitUntilLeft(), "the TV button on the Settings tab did not go to the Home screen")
        pause(2)
        app.activate()
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 60), "the page never opened")
        pause(3)
        XCTAssertEqual(selectedTab, "shows", "the page is not on the Shows tab")
        XCTAssertFalse(tabBarHasFocus, "the focus stayed in the tab bar: \(focusedLabel)")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The Top Shelf link of 5.2.0 (`PopcornTime:?action=showMovie»{json}`,
    /// here with « » in its title) still opens the movie's page, on the tab
    /// that is shown (the Watchlist).
    func testATopShelfLinkOf520OpensTheMoviePage() throws {
        let json = "{\"imdb_id\":\"tt0816692\",\"title\":\"Interstellar « IMAX »\",\"year\":\"2014\"}"
        let action = try XCTUnwrap(("showMovie»" + json).addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        launch(["-PTDebugTab", "watchlist", "-PTDebugOpenURL", "PopcornTime:?action=" + action])
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 60), "the page never opened")
        pause(2)
        XCTAssertEqual(selectedTab, "watchlist", "the page is not on the tab that was shown")
        remote.press(.menu)
        pause(2)
        XCTAssertFalse(detailTitle.exists, "Menu did not leave the page")
        XCTAssertEqual(app.state, .runningForeground, "Menu on the page left the app")
    }

    /// Links that are not links: a Top Shelf link whose JSON does not map
    /// (5.2.0 crashed on it), an id that is not an IMDb id, an unknown tab.
    /// The app stays where it was.
    func testBrokenLinksDoNothing() throws {
        for url in ["PopcornTime:?action=showMovie%C2%BB%7B%7D",
                    "PopcornTime:?action=showShow%C2%BBnot-json",
                    "popcorntime://movie/..%2F..%2Fetc",
                    "popcorntime://tab/nowhere"] {
            launch(["-PTDebugTab", "watchlist", "-PTDebugOpenURL", url])
            XCTAssertTrue(linkResult.waitForExistence(timeout: 40), "\(url) never reached the link handler")
            XCTAssertEqual(linkResult.label, "refused", "\(url) was not refused")
            pause(2)
            XCTAssertEqual(app.state, .runningForeground, "\(url) closed the app")
            XCTAssertFalse(detailTitle.exists || loadingScreen.exists, "\(url) opened a page")
            XCTAssertEqual(selectedTab, "watchlist", "\(url) changed the tab")
            app.terminate()
            pause(1)
        }
    }

    /// `popcorntime://search?q=` searches on the Search tab,
    /// `popcorntime://tab/` selects a tab.
    func testSearchAndTabLinks() throws {
        launch(["-PTDebugTab", "settings", "-PTDebugOpenURL", "popcorntime://search?q=star"])
        let results = grid(named: "SearchViewController")
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline, !(results.exists && results.cells.count > 3) { pause(1) }
        XCTAssertEqual(selectedTab, "search", "the search link did not select the Search tab")
        guard results.exists, results.cells.count > 3 else { throw XCTSkip("the search found too few results") }
        app.terminate()
        pause(1)

        launch(["-PTDebugTab", "movies", "-PTDebugOpenURL", "PopcornTime://Tab/Watchlist"])
        pause(4)
        XCTAssertEqual(selectedTab, "watchlist", "the tab link did not select the Watchlist")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - The first launch and the first tab

    /// A fresh install: the Terms of Service come first, and a link opens
    /// nothing behind them. (Nothing is accepted: the test writes no
    /// preference.)
    func testTheTermsOfServiceComeFirstOnAFreshInstall() throws {
        launch(["-PTDebugOpenURL", "popcorntime://show/tt0903747"], termsAccepted: false)
        XCTAssertTrue(app.buttons["Accept"].waitForExistence(timeout: 15), "the Terms of Service never showed")
        XCTAssertTrue(app.buttons["Leave"].exists, "no Leave button")
        XCTAssertTrue(linkResult.waitForExistence(timeout: 40), "the link never reached the link handler")
        XCTAssertEqual(linkResult.label, "refused", "the link was not refused")
        pause(2)
        XCTAssertTrue(app.buttons["Accept"].exists, "the Terms of Service went away")
        XCTAssertFalse(detailTitle.exists || loadingScreen.exists, "the link opened a page behind the Terms of Service")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The first tab is Home, not a grid (SwiftUI in a hosting controller):
    /// the Terms of Service still show on a fresh install (they were
    /// presented from the first tab's grid).
    func testTheTermsOfServiceShowOverHome() throws {
        launch([], termsAccepted: false)
        XCTAssertTrue(app.buttons["Accept"].waitForExistence(timeout: 15), "the Terms of Service never showed")
        XCTAssertTrue(app.buttons["Leave"].exists, "no Leave button")
        // (Nothing of the tab behind them is reachable: not even its name.)
        XCTAssertFalse(element("Home.Play").exists, "the Home's buttons are reachable behind the Terms of Service")
    }

    /// The Home asks nothing of the network before the Terms of Service are accepted
    /// (`[Home] the lists wait for the Terms of Service to be accepted` in the console): once
    /// they are, its lists start and the page fills (recorded answers, their cache emptied at
    /// launch: nothing is painted from disk).
    func testTheHomeStartsOnceTheTermsOfServiceAreAccepted() throws {
        launch([], termsAccepted: false)
        let accept = app.buttons["Accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 15), "the Terms of Service never showed")
        // Accept sits right of Leave, under the text (the text may have the focus first).
        for button in [XCUIRemote.Button.right, .down, .right, .down, .right] where !accept.hasFocus {
            remote.press(button)
            pause(0.5)
        }
        XCTAssertTrue(accept.hasFocus, "Accept never had the focus")
        remote.press(.select)
        XCTAssertTrue(element("Home.Hero.Title").waitForExistence(timeout: 30), "the Home did not fill once the terms were accepted")
        XCTAssertFalse(accept.exists, "the Terms of Service are still up")
    }

    /// Home first: the other tabs are still found by their name, a link
    /// opens its page on Home, and Menu goes back to it.
    func testHomeFirstKeepsTheTabNamesAndLinks() throws {
        launch([])
        let billboard = element("Home.Hero")
        XCTAssertTrue(billboard.waitForExistence(timeout: 20), "the first tab is not Home")
        XCTAssertEqual(selectedTab, "home", "Home is not the selected tab")
        app.terminate()
        pause(1)

        launch(["-PTDebugTab", "shows"])
        XCTAssertTrue(grid(named: "ShowsViewController").waitForExistence(timeout: 10), "-PTDebugTab shows did not show the Shows grid")
        XCTAssertEqual(selectedTab, "shows")
        app.terminate()
        pause(1)

        launch(["-PTDebugOpenURL", "popcorntime://movie/tt0816692"])
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 60), "the page never opened")
        pause(3)
        XCTAssertEqual(selectedTab, "home", "the page is not on the first tab")
        XCTAssertFalse(tabBarHasFocus, "the focus stayed in the tab bar: \(focusedLabel)")
        remote.press(.menu)
        pause(2)
        XCTAssertFalse(detailTitle.exists, "Menu did not leave the page")
        XCTAssertEqual(app.state, .runningForeground, "Menu on the page left the app")
        XCTAssertTrue(billboard.exists, "Home is not back")
    }

    // MARK: - Steps

    /// Opens a poster two columns to the right and one row down, goes back,
    /// and checks the grid: same poster focused, same place, no movement.
    private func checkBackRestoresGrid(named name: String, shotsLabel: String) throws {
        let grid = grid(named: name)
        _ = try focusPoster(in: grid)
        remote.press(.right)
        pause(0.6)
        remote.press(.right)
        pause(0.6)
        remote.press(.down)
        pause(1.5)
        guard let before = focusedCell(in: grid) else { return XCTFail("no poster has the focus") }
        let label = before.label
        let frame = before.frame
        let gridShot = XCUIScreen.main.screenshot()
        save(gridShot, "\(shotsLabel)-0-before")

        remote.press(.select)
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 60), "the page never opened")
        pause(2.5)
        save(XCUIScreen.main.screenshot(), "\(shotsLabel)-1-page")

        remote.press(.menu)
        // While the grid comes back and settles: where the focused poster is.
        var frames: [CGRect] = []
        let start = Date()
        var index = 0
        while Date().timeIntervalSince(start) < 3 {
            save(XCUIScreen.main.screenshot(), "\(shotsLabel)-2-back-\(String(format: "%02d", index))")
            index += 1
            if let cell = focusedCell(in: grid), cell.label == label { frames.append(cell.frame) }
        }
        pause(1)
        save(XCUIScreen.main.screenshot(), "\(shotsLabel)-3-after")

        guard let after = focusedCell(in: grid) else { return XCTFail("no poster has the focus after Menu") }
        XCTAssertEqual(after.label, label, "the focus is not back on the poster that was opened")
        XCTAssertEqual(after.frame.minX, frame.minX, accuracy: 2, "the poster is not back at its place")
        XCTAssertEqual(after.frame.minY, frame.minY, accuracy: 2, "the poster is not back at its place")
        for sample in frames {
            XCTAssertEqual(sample.minY, frame.minY, accuracy: 2, "the grid moved while it came back: \(frames.map { Int($0.minY) })")
        }
        XCTAssertFalse(detailTitle.exists)
    }

    /// The grid's header at the top, two rows down and back at the top (see
    /// `testTheGridHeaderScrollsWithThePosters`).
    private func checkHeaderScrollsWithThePosters(of name: String, title text: String, shotsLabel: String) throws {
        let grid = grid(named: name)
        _ = try focusPoster(in: grid)
        pause(1.5)
        let top = try screenLayout(of: name)
        save(XCUIScreen.main.screenshot(), "\(shotsLabel)-0-top")
        XCTAssertEqual(element("GridHeader.Title").label, text, "not the page title")
        for identifier in Self.headerIdentifiers {
            guard let frame = top.header[identifier] else { return XCTFail("\(identifier) is not on the screen") }
            XCTAssertTrue(top.screen.contains(frame), "\(identifier) is not on the screen at the top: \(frame)")
        }
        expectHeaderClear(of: top, "at the top")
        XCTAssertFalse(top.tabs.isEmpty, "the tab bar is not shown at the top of the grid: \(top)")

        // Two rows down.
        remote.press(.down)
        pause(1)
        remote.press(.down)
        pause(2)
        let down = try screenLayout(of: name)
        save(XCUIScreen.main.screenshot(), "\(shotsLabel)-1-two-rows-down")
        guard down.focusedPoster != nil, down.focused != top.focused else {
            return XCTFail("the focus did not go two rows down: \(top.focused) → \(down.focused)")
        }
        expectHeaderClear(of: down, "two rows down")
        for (identifier, frame) in down.header {
            XCTAssertLessThanOrEqual(frame.maxY, down.screen.minY + 1, "\(identifier) did not scroll away with the first row: \(frame)")
        }
        for tab in down.tabs {
            for poster in down.posters where overlap(tab, poster) {
                XCTFail("the tab bar is over a poster two rows down: tab \(tab), poster \(poster)")
            }
        }

        // Back to the first row.
        remote.press(.up)
        pause(1)
        remote.press(.up)
        pause(2)
        let back = try screenLayout(of: name)
        save(XCUIScreen.main.screenshot(), "\(shotsLabel)-2-back-at-top")
        if let poster = back.focusedPoster, let focusedTop = top.focusedPoster {
            XCTAssertEqual(poster.minY, focusedTop.minY, accuracy: 2, "the first row is not back at its place")
        } else {
            XCTFail("no poster has the focus back at the top: \(back)")
        }
        for identifier in Self.headerIdentifiers + Self.optionalHeaderIdentifiers.filter({ top.header[$0] != nil }) {
            guard let frame = back.header[identifier], let before = top.header[identifier] else {
                XCTFail("\(identifier) is not back at the top")
                continue
            }
            XCTAssertEqual(frame.minY, before.minY, accuracy: 2, "\(identifier) is not back at its place")
            XCTAssertEqual(frame.minX, before.minX, accuracy: 2, "\(identifier) is not back at its place")
        }
        expectHeaderClear(of: back, "back at the top")
        XCTAssertFalse(back.tabs.isEmpty, "the tab bar is not back at the top of the grid: \(back)")
    }

    /// Fails when the title or Sort / Genre is drawn over a poster.
    private func expectHeaderClear(of layout: ScreenLayout, _ when: String) {
        for (identifier, frame) in layout.header {
            for poster in layout.posters where overlap(frame, poster) {
                XCTFail("\(identifier) is over a poster \(when): \(frame) over \(poster)")
            }
        }
    }

    /// Two frames share more than a sliver.
    private func overlap(_ a: CGRect, _ b: CGRect) -> Bool {
        let shared = a.intersection(b)
        return !shared.isNull && shared.width > 2 && shared.height > 2
    }

    /// Focuses a poster of `grid` and opens its page; returns the poster's title.
    private func openPoster(in grid: XCUIElement) throws -> String {
        let cell = try focusPoster(in: grid)
        let label = cell.label
        remote.press(.select)
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 60), "the page never opened")
        pause(2.5)
        return label
    }

    /// After Menu on a page: the grid, with the focus on `label`'s poster.
    private func expectGridBack(_ grid: XCUIElement, focusedOn label: String) throws {
        pause(2)
        XCTAssertFalse(detailTitle.exists, "Menu did not leave the page")
        XCTAssertEqual(focusedCell(in: grid)?.label, label, "the focus is not back on the poster that was opened")
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

    // MARK: - Queries

    /// - Parameter termsAccepted: false launches as a fresh install does
    ///   (the Terms of Service not accepted yet).
    @discardableResult
    private func launch(_ arguments: [String], termsAccepted: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-tosAccepted", termsAccepted ? "YES" : "NO",
            "-lastWhatsNewVersion", "99",
            "-themeSongVolume", "0",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-PTDebugHomeFixtures", Self.homeFixtures,
            // No TMDB key, whatever the simulator saved: the grids' header
            // is Sort and Genre (StreamingServicesUITests has the key's).
            "-popcornkit.tmdb.apiKey", "",
        ] + arguments
        app.launch()
        self.app = app
        return app
    }

    /// The recorded answers Home is fed from, read by the app from the
    /// source tree (the simulator shares the Mac's disk).
    private static var homeFixtures: String {
        if let folder = ProcessInfo.processInfo.environment["PT_UITEST_HOME_FIXTURES"], !folder.isEmpty { return folder }
        return URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PopcornTimeTests/Fixtures/Home").path
    }

    private func grid(named name: String) -> XCUIElement {
        app.collectionViews["MediaGrid.\(name)"]
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func labelled(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private var detailTitle: XCUIElement { element("Detail.Title") }
    private var loadingScreen: XCUIElement { element("LoadingScreen") }
    /// `-PTDebugOpenURL`'s answer: "opened" or "refused" (SceneDelegate).
    private var linkResult: XCUIElement { element("Debug.LinkResult") }

    private static let focusedPredicate = NSPredicate(format: "hasFocus == true")

    private func focusedCell(in grid: XCUIElement) -> XCUIElement? {
        let cell = grid.cells.matching(Self.focusedPredicate).firstMatch
        return cell.exists ? cell : nil
    }

    /// The element with the focus (any kind), and its label for a trail.
    private var focusedElement: XCUIElement {
        app.descendants(matching: .any).matching(Self.focusedPredicate).firstMatch
    }

    private var focusedLabel: String {
        let focused = focusedElement
        return focused.exists ? focused.label : "none"
    }

    private var tabBarHasFocus: Bool {
        app.tabBars.descendants(matching: .any).matching(Self.focusedPredicate).firstMatch.exists
    }

    /// The selected tab's name: "movies", "settings"… (`DeepLink.Tab`). The
    /// tab bar carries it in its identifier ("TabBar.shows"): the tvOS 26
    /// tab bar does not say which of its buttons is selected.
    private var selectedTab: String {
        // The detail page hides the tab bar: the app's DEBUG marker says it then.
        let bar = app.tabBars.firstMatch
        guard bar.exists else {
            let marker = app.descendants(matching: .any)["Debug.SelectedTab"]
            return marker.exists ? marker.label : "none (no tab bar)"
        }
        let identifier = bar.identifier
        return identifier.hasPrefix("TabBar.") ? String(identifier.dropFirst("TabBar.".count)) : "none (\(identifier))"
    }

    /// The page title and Sort / Genre of a grid (`MainViewController`).
    private static let headerIdentifiers = ["GridHeader.Title", "GridHeader.Sort", "GridHeader.Genre"]
    /// The Service control: only with a TMDB key and services chosen
    /// (`MediaViewController`). These tests run without a key (it is not
    /// there); when it is, it is checked like the others.
    private static let optionalHeaderIdentifiers = ["GridHeader.Service"]

    /// What is on the screen, from one snapshot of the app: the grid's
    /// header, its posters and the tab bar's tabs (only those on the screen).
    private struct ScreenLayout: CustomStringConvertible {
        var screen: CGRect = .zero
        var header: [String: CGRect] = [:]
        var posters: [CGRect] = []
        var focusedPoster: CGRect?
        var tabs: [CGRect] = []
        var focused = "none"

        var description: String {
            let r = { (frame: CGRect) in "(\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)))" }
            return "focused=\(focused) focusedPoster=\(focusedPoster.map(r) ?? "none") "
                + "header=\(header.keys.sorted().map { "\($0)=\(r(header[$0]!))" }) "
                + "tabs=\(tabs.map(r)) posters=\(posters.count) firstPosters=\(posters.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }.prefix(3).map(r))"
        }
    }

    private func screenLayout(of gridName: String) throws -> ScreenLayout {
        let root = try app.snapshot()
        var layout = ScreenLayout()
        layout.screen = root.frame
        func walk(_ node: XCUIElementSnapshot, inGrid: Bool, inTabBar: Bool) {
            let inGrid = inGrid || node.identifier == "MediaGrid.\(gridName)"
            let inTabBar = inTabBar || node.elementType == .tabBar
            let onScreen = node.frame.intersects(layout.screen) && !node.frame.isEmpty
            if (Self.headerIdentifiers + Self.optionalHeaderIdentifiers).contains(node.identifier) { layout.header[node.identifier] = node.frame }
            if inGrid, node.elementType == .cell, onScreen {
                layout.posters.append(node.frame)
                if node.hasFocus { layout.focusedPoster = node.frame }
            }
            if inTabBar, node.elementType == .button, onScreen { layout.tabs.append(node.frame) }
            if node.hasFocus { layout.focused = node.label.isEmpty ? node.identifier : node.label }
            node.children.forEach { walk($0, inGrid: inGrid, inTabBar: inTabBar) }
        }
        walk(root, inGrid: false, inTabBar: false)
        return layout
    }

    /// On the first screen of a tab other than Home, Menu goes to Home (at
    /// once, or after a first press that gives the focus to the tab bar)
    /// with the focus in Home, not in the tab bar, and the app stays; Menu
    /// on Home then leaves the app.
    private func expectMenuGoesHomeThenLeavesTheApp(_ screen: String) {
        remote.press(.menu)
        pause(1.5)
        XCTAssertEqual(app.state, .runningForeground, "\(screen): Menu left the app instead of going to Home")
        if selectedTab != "home" {
            XCTAssertTrue(tabBarHasFocus, "\(screen): Menu neither went to Home nor moved the focus to the tab bar")
            remote.press(.menu)
            pause(1.5)
            XCTAssertEqual(app.state, .runningForeground, "\(screen): Menu on the tab bar left the app instead of going to Home")
        }
        XCTAssertEqual(selectedTab, "home", "\(screen): Menu did not go to Home")
        XCTAssertFalse(tabBarHasFocus, "\(screen): the focus stayed in the tab bar after going to Home: \(focusedLabel)")
        remote.press(.menu)
        XCTAssertTrue(waitUntilLeft(), "\(screen): Menu on Home must go to the Home screen")
    }

    /// The app left the foreground (Menu at the root: the Home screen). The
    /// state changes a second or two after the Home screen shows.
    private func waitUntilLeft(timeout: TimeInterval = 8) -> Bool {
        if app.wait(for: .runningBackground, timeout: timeout) { return true }
        return [.runningBackgroundSuspended, .notRunning].contains(app.state)
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func save(_ screenshot: XCUIScreenshot, _ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["PT_UITEST_SHOTS"], !folder.isEmpty else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: url)
    }
}
