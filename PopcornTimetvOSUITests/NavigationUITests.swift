import XCTest

/// The Siri Remote on the tvOS app: Menu (Back) goes one level back from every
/// screen (also while a screen still slides in), on a tab's first screen it
/// leaves the app, and a grid comes back exactly as it was left. A grid's
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
        launch(["-PTDebugTab", "0", "-PTDebugFilter", "top100"])
        try checkBackRestoresGrid(named: "MoviesViewController", shotsLabel: "top100")
    }

    /// The same on the Movies tab's default list (Trending, paginated).
    func testBackFromAMoviePageRestoresTheTrendingGrid() throws {
        launch(["-PTDebugTab", "0"])
        try checkBackRestoresGrid(named: "MoviesViewController", shotsLabel: "trending")
    }

    /// The same on the Shows tab (Top 100).
    func testBackFromAShowPageRestoresTheShowsGrid() throws {
        launch(["-PTDebugTab", "1", "-PTDebugFilter", "top100"])
        try checkBackRestoresGrid(named: "ShowsViewController", shotsLabel: "shows-top100")
    }

    /// Menu right after Select (the page still loading, the loading screen
    /// still sliding in) goes back to the grid, and the page does not open
    /// afterwards.
    func testMenuDuringTheLoadingScreenGoesBackToTheGrid() throws {
        launch(["-PTDebugTab", "0"])
        let grid = grid(named: "MoviesViewController")
        let cell = try focusPoster(in: grid)
        let label = cell.label
        // No screenshot between the two presses: Menu while the loading
        // screen still slides in.
        remoteControl.press(.select)
        pause(0.25)
        remoteControl.press(.menu)
        pause(6)
        XCTAssertEqual(app.state, .runningForeground, "Menu on the loading screen left the app")
        XCTAssertFalse(detailTitle.exists, "the page opened after Menu was pressed on the loading screen")
        XCTAssertFalse(loadingScreen.exists, "the loading screen stayed after Menu")
        XCTAssertEqual(focusedCell(in: grid)?.label, label, "the focus is not back on the poster")
    }

    /// Menu on a tab's grid leaves the app for the Home screen (tvOS 26
    /// does it at once; earlier tvOS first gives the focus to the tab bar).
    func testMenuOnAGridGoesToTheHomeScreen() throws {
        launch(["-PTDebugTab", "1"])
        _ = try focusPoster(in: grid(named: "ShowsViewController"))
        expectMenuLeavesTheApp("Shows grid")
    }

    // MARK: - The grid's header

    /// Movies (Top 100): the page title and Sort / Genre are part of the
    /// page, as on every tvOS screen. Two rows down they have scrolled away
    /// with the first row (they stayed and were drawn over the posters) and
    /// the tab bar is out of the way; back on the first row, the title,
    /// Sort / Genre and the tab bar are back where they were.
    func testTheGridHeaderScrollsWithThePosters() throws {
        launch(["-PTDebugTab", "0", "-PTDebugFilter", "top100"])
        try checkHeaderScrollsWithThePosters(of: "MoviesViewController", title: "Movies", shotsLabel: "header-movies")
    }

    /// The same on the Shows tab (its default list, paginated).
    func testTheShowsGridHeaderScrollsWithThePosters() throws {
        launch(["-PTDebugTab", "1"])
        try checkHeaderScrollsWithThePosters(of: "ShowsViewController", title: "Shows", shotsLabel: "header-shows")
    }

    /// Up from the first row reaches Sort / Genre, even from the first
    /// column (the farthest from them), then the tab bar on the tab that was
    /// selected; Down from the tab bar goes back into the page. A genre
    /// picked with Genre becomes the page title.
    func testUpFromTheFirstRowReachesSortGenreThenTheTabBar() throws {
        launch(["-PTDebugTab", "0"])
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

        // Genre: the genre picked becomes the title.
        for _ in 0..<3 where !genre.hasFocus {
            remote.press(sort.hasFocus ? .right : .up)
            pause(1)
        }
        guard genre.hasFocus else { return XCTFail("Genre never got the focus: \(focusedLabel)") }
        remote.press(.select)
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "the genres did not open")
        pause(1)
        remote.press(.down)
        pause(1)
        let picked = focusedLabel
        XCTAssertFalse(["none", "All", "Cancel"].contains(picked), "no genre has the focus: \(picked)")
        remote.press(.select)
        pause(2)
        XCTAssertFalse(cancel.exists, "the genres did not close")
        XCTAssertEqual(title.label, picked, "the title is not the genre picked")
    }

    // MARK: - Detail page

    /// The full summary: Menu closes it (the page stays), Menu again leaves
    /// the page.
    func testMenuClosesTheSummaryThenLeavesThePage() throws {
        // A show: its summary is long enough to be cut at three lines.
        launch(["-PTDebugTab", "1", "-PTDebugOpenShow", "tt0903747", "-PTDebugFocusContent", "YES"])
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
        launch(["-PTDebugTab", "0"])
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
        launch(["-PTDebugTab", "1"])
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
        launch(["-PTDebugTab", "0", "-PTDebugOpenItem", "0", "-PTDebugFocusContent", "YES",
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

    /// A page that takes long to load: its loading screen has nothing to
    /// focus but holds the focus (it fell into the tab bar, where Menu left
    /// the app), and Menu goes back to the grid; the page never opens later.
    func testMenuOnASlowLoadingScreenGoesBackToTheGrid() throws {
        launch(["-PTDebugTab", "0", "-PTDebugOpenMovie", "tt9999999999"])
        XCTAssertTrue(loadingScreen.waitForExistence(timeout: 20), "the loading screen never showed")
        pause(4)
        guard loadingScreen.exists else { throw XCTSkip("the title answered before the test could press Menu") }
        XCTAssertFalse(tabBarHasFocus, "the focus fell into the tab bar on the loading screen")
        remote.press(.menu)
        pause(2)
        XCTAssertEqual(app.state, .runningForeground, "Menu on the loading screen left the app")
        XCTAssertFalse(loadingScreen.exists, "Menu did not leave the loading screen")
        XCTAssertTrue(grid(named: "MoviesViewController").exists, "the grid is not back")
        pause(3)
        XCTAssertFalse(detailTitle.exists || element("ErrorPage").exists, "a page opened after Menu")
    }

    /// A title that cannot be loaded (a movie's id opened as a show): the
    /// error page has nothing to focus, and Menu still goes back to the grid.
    func testMenuOnAnErrorPageGoesBackToTheGrid() throws {
        launch(["-PTDebugTab", "1", "-PTDebugOpenShow", "tt0111161"])
        let errorPage = element("ErrorPage")
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline, !errorPage.exists, !detailTitle.exists { pause(1) }
        guard errorPage.exists else { throw XCTSkip("no error page: the title loaded or never answered") }
        pause(1.5)
        XCTAssertFalse(tabBarHasFocus, "the focus fell into the tab bar on the error page")
        remote.press(.menu)
        pause(2)
        XCTAssertEqual(app.state, .runningForeground, "Menu on the error page left the app")
        XCTAssertFalse(errorPage.exists, "Menu did not leave the error page")
        XCTAssertTrue(grid(named: "ShowsViewController").exists, "the grid is not back")
    }

    /// Holding Select on a poster opens its menu (Play, watchlist, watched);
    /// Menu closes it and the poster keeps the focus. Nothing in it is chosen.
    func testLongPressOnAPosterOpensItsMenuAndMenuClosesIt() throws {
        launch(["-PTDebugTab", "0"])
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
    /// the focus back on its row; Menu again leaves the app.
    func testMenuOnSettingsClosesThePickerThenLeavesTheApp() throws {
        launch(["-PTDebugTab", "5", "-PTDebugFocusContent", "YES"])
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
        expectMenuLeavesTheApp("Settings")
    }

    /// Search: from the keyboard, Menu leaves the app.
    func testMenuOnSearchLeavesTheApp() throws {
        launch(["-PTDebugTab", "3"])
        pause(3)
        remote.press(.down)
        pause(1.5)
        if tabBarHasFocus {
            remote.press(.down)
            pause(1.5)
        }
        XCTAssertFalse(tabBarHasFocus, "the focus never left the tab bar for the keyboard")
        expectMenuLeavesTheApp("Search")
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
        launch(["-PTDebugTab", "0"])
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
        expectMenuLeavesTheApp("the grid after Menu twice")
    }

    /// Select on a poster, then Menu three times in quick succession while
    /// the page comes in: the grid stays, with the poster focused, no page
    /// opens later, and the app stays (5.1.0 crashed here).
    func testSelectThenMenuThreeTimesQuicklyStaysOnTheGrid() throws {
        launch(["-PTDebugTab", "0", "-PTDebugFilter", "top100"])
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
        expectMenuLeavesTheApp("the grid after Select then Menu three times")
    }

    /// The focus on a tab in the tab bar, at a tab's root (Movies, Shows,
    /// Settings): Menu goes to the Home screen.
    func testMenuInTheTabBarAtATabsRootLeavesTheApp() throws {
        for tab in ["0", "1", "5"] {
            launch(["-PTDebugTab", tab])
            pause(4)
            for _ in 0..<4 where !tabBarHasFocus {
                remote.press(.up)
                pause(0.8)
            }
            XCTAssertTrue(tabBarHasFocus, "tab \(tab): the tab bar never got the focus")
            remote.press(.menu)
            XCTAssertTrue(waitUntilLeft(), "tab \(tab): Menu in the tab bar at the tab's root did not go to the Home screen")
            app.terminate()
            pause(1)
        }
    }

    /// Downloads (empty on a fresh simulator) and Watchlist: Menu leaves the app.
    func testMenuOnTheDownloadsAndWatchlistTabsLeavesTheApp() throws {
        for tab in ["4", "2"] {
            launch(["-PTDebugTab", tab])
            pause(3)
            remote.press(.down)
            pause(1)
            expectMenuLeavesTheApp("tab \(tab)")
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
    /// list): the error is shown and Menu still leaves the app.
    func testMenuOnTheTop100ErrorLeavesTheApp() throws {
        launch(["-PTDebugTab", "0", "-PTDebugFilter", "top100", "-PTDebugTop100Offline", "YES"])
        pause(8)
        remote.press(.down)
        pause(1)
        expectMenuLeavesTheApp("Top 100 error")
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
        for identifier in Self.headerIdentifiers {
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

    @discardableResult
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-tosAccepted", "YES",
            "-lastWhatsNewVersion", "99",
            "-themeSongVolume", "0",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ] + arguments
        app.launch()
        self.app = app
        return app
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

    /// The page title and Sort / Genre of a grid (`MainViewController`).
    private static let headerIdentifiers = ["GridHeader.Title", "GridHeader.Sort", "GridHeader.Genre"]

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
            if Self.headerIdentifiers.contains(node.identifier) { layout.header[node.identifier] = node.frame }
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

    /// On a tab's first screen, Menu leaves the app (at once, or after a
    /// first press that gives the focus to the tab bar).
    private func expectMenuLeavesTheApp(_ screen: String) {
        remote.press(.menu)
        if waitUntilLeft() { return }
        XCTAssertTrue(tabBarHasFocus, "\(screen): Menu neither left the app nor moved the focus to the tab bar")
        remote.press(.menu)
        XCTAssertTrue(waitUntilLeft(), "\(screen): Menu on the tab bar must go to the Home screen")
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
