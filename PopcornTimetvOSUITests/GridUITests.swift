import XCTest

/// The poster grids of the tvOS app (Movies, Shows, Watchlist, Search): the
/// one-line header whose controls say the sort and the genre, two rows and
/// the top of a third at rest, the caption that follows the focus, the marks
/// a poster's menu changes in place, Retry on a list that failed, and the
/// focus kept when the list changes under it (a page added, the saved first
/// page replaced by the network's).
///
/// Runs like `NavigationUITests`: the tvOS 26.5 simulator, a DEBUG build of
/// the app (`SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`), the public catalog
/// APIs. Nothing is ever played: Select is pressed on the header's controls,
/// on Retry and in a poster's menu on the watchlist / watched actions only.
/// The watch state is given as launch arguments and kept in memory
/// (`-PTDebugLibraryInMemory`): nothing is written to the app's defaults.
///
/// `PT_UITEST_SHOTS=<folder>` (`TEST_RUNNER_PT_UITEST_SHOTS` on the
/// xcodebuild command line) saves screenshots of the steps;
/// `PT_UITEST_LANGUAGE=fr` runs the app in French for them (the checks that
/// read English texts are skipped then); `PT_UITEST_HITCHES=1` runs the
/// scrolling measure (`testScrollingReportsItsLateFrames`).
final class GridUITests: XCTestCase {

    private let remote = XCUIRemote.shared
    private var app: XCUIApplication!

    private static let focused = NSPredicate(format: "hasFocus == true")

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

    // MARK: - Layout

    /// Movies at rest: the title and Sort / Genre on one line, the controls
    /// saying what they are set to; two full rows of six posters and the
    /// rows clear of each other (their lines); the title on the posters' left edge.
    func testTheHeaderIsOneLineAndTwoRowsShowAtRest() throws {
        launch(["-PTDebugTab", "movies"])
        let grid = self.grid("MoviesViewController")
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 60), "the grid never loaded")
        pause(2)
        snap("movies-at-rest")

        let title = element("GridHeader.Title"), sort = element("GridHeader.Sort"), genre = element("GridHeader.Genre")
        XCTAssertTrue(title.exists && sort.exists && genre.exists, "the header is not complete")
        XCTAssertEqual(title.frame.midY, sort.frame.midY, accuracy: 6, "the title and Sort are not on one line")
        XCTAssertEqual(sort.frame.midY, genre.frame.midY, accuracy: 2, "Sort and Genre are not on one line")
        if isEnglish {
            XCTAssertEqual(title.label, "Movies")
            XCTAssertEqual(sort.label, "Sort: Trending", "Sort does not say the sort")
            XCTAssertEqual(genre.label, "Genre: All", "Genre does not say the genre")
        }

        let screen = app.windows.firstMatch.frame
        let rows = self.rows(of: grid)
        // The Home's poster card (240 × 360) with its line of facts: six
        // columns, two rows on the screen.
        XCTAssertGreaterThanOrEqual(rows.count, 2, "fewer than two rows of posters on the screen: \(rows)")
        guard rows.count >= 2 else { return }
        XCTAssertEqual(rows[0].count, 6, "not six posters in the first row")
        XCTAssertGreaterThan(rows[0].minY, max(title.frame.maxY, sort.frame.maxY), "the first row is under the header")
        XCTAssertLessThanOrEqual(rows[1].maxY, screen.maxY, "the second row is not whole on the screen")
        XCTAssertGreaterThanOrEqual(rows[1].minY - rows[0].maxY, 70, "the rows have no room for their lines")
        XCTAssertEqual(title.frame.minX, rows[0].minX, accuracy: 2, "the title is not on the posters' left edge")
        // (A button's frame includes a few points of its platter's outset.)
        XCTAssertEqual(genre.frame.maxX, rows[0].maxX, accuracy: 6, "Genre does not end on the posters' right edge")
    }

    /// The same on Shows; a show's poster reads its seasons when the list
    /// knows them.
    func testTheShowsGridHasTheSameLayout() throws {
        launch(["-PTDebugTab", "shows"])
        let grid = self.grid("ShowsViewController")
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 60), "the grid never loaded")
        pause(2)
        snap("shows-at-rest")
        let rows = self.rows(of: grid)
        XCTAssertGreaterThanOrEqual(rows.count, 2, "fewer than two rows of posters on the screen")
        XCTAssertEqual(rows.first?.count, 6, "not six posters in the first row")
        if isEnglish {
            XCTAssertEqual(element("GridHeader.Title").label, "Shows")
            XCTAssertEqual(element("GridHeader.Sort").label, "Sort: Trending")
            let labels = grid.cells.allElementsBoundByIndex.prefix(21).map { $0.label }
            XCTAssertTrue(labels.contains { $0.contains("Season") }, "no poster of the first rows says its seasons: \(labels.prefix(5))")
        }
        _ = try focusPoster(in: grid)
        pause(1)
        snap("shows-first-row-focused")
    }

    // MARK: - The caption follows the focus

    /// The focused poster says what it is in one line under it, clear of the
    /// posters; the line goes with the focus, in the first row and in the
    /// third, and leaves when the focus leaves the posters.
    func testTheCaptionFollowsTheFocus() throws {
        launch(["-PTDebugTab", "movies"])
        let grid = self.grid("MoviesViewController")
        let caption = element("Grid.Caption")
        XCTAssertFalse(caption.exists, "a caption shows while no poster has the focus")

        let first = try focusPoster(in: grid)
        pause(1)
        snap("movies-first-row-focused")
        try expectCaption(caption, under: first, in: grid)
        // What VoiceOver reads on a poster: its title, then what is known.
        // (`first` is the focused poster, whichever it is: its texts are
        // read now.)
        let firstLabel = first.label
        let parts = firstLabel.components(separatedBy: ", ")
        XCTAssertGreaterThanOrEqual(parts.count, 2, "the poster reads its title only: \(firstLabel)")
        XCTAssertTrue(first.identifier.hasPrefix("Grid.Card.tt"), "the poster has no card identifier: \(first.identifier)")

        // To the right: the caption goes with it.
        remote.press(.right)
        pause(1)
        guard let second = focusedCell(in: grid) else { return XCTFail("no poster has the focus after Right") }
        XCTAssertNotEqual(second.label, firstLabel, "Right did not move the focus")
        try expectCaption(caption, under: second, in: grid)

        // The last column: the caption ends at the poster's right edge.
        for _ in 0..<6 {
            remote.press(.right)
            pause(0.5)
        }
        pause(0.8)
        guard let last = focusedCell(in: grid) else { return XCTFail("no poster has the focus in the last column") }
        snap("movies-last-column-focused")
        try expectCaption(caption, under: last, in: grid)
        XCTAssertLessThanOrEqual(caption.frame.maxX, last.frame.maxX + 20, "the caption runs past the last column")

        // Third row.
        remote.press(.down)
        pause(1)
        remote.press(.down)
        pause(1.5)
        guard let third = focusedCell(in: grid) else { return XCTFail("no poster has the focus in the third row") }
        snap("movies-third-row-focused")
        try expectCaption(caption, under: third, in: grid)

        // Up to the header: no caption.
        for _ in 0..<4 where focusedCell(in: grid) != nil {
            remote.press(.up)
            pause(1)
        }
        XCTAssertTrue(element("GridHeader.Sort").hasFocus || element("GridHeader.Genre").hasFocus, "Up from the first row did not reach Sort / Genre")
        pause(0.5)
        XCTAssertFalse(caption.exists, "the caption stayed after the focus left the posters")
    }

    // MARK: - Sort and Genre

    /// A sort and a genre picked: the controls say them, the page keeps its
    /// title, the grid shows the new list from its first poster.
    func testSortAndGenreSayWhatWasPicked() throws {
        launch(["-PTDebugTab", "movies"])
        let grid = self.grid("MoviesViewController")
        let title = element("GridHeader.Title"), sort = element("GridHeader.Sort"), genre = element("GridHeader.Genre")
        _ = try focusPoster(in: grid)
        let titleBefore = title.label, sortBefore = sort.label, genreBefore = genre.label
        let firstBefore = grid.cells.firstMatch.label

        try focus(sort, from: grid)
        remote.press(.select)
        // A menu anchored to the control: the current choice is one of its
        // entries (the control itself reads "Sort: Trending").
        let currentSort = menuEntry(currentValue(of: sortBefore))
        XCTAssertTrue(currentSort.waitForExistence(timeout: 5), "the sorts did not open")
        pause(1)
        snap("movies-sort-menu")
        // The sort after the one selected.
        remote.press(.down)
        pause(1)
        let pickedSort = focusedLabel
        remote.press(.select)
        pause(1.5)
        XCTAssertFalse(currentSort.exists, "the sorts did not close")
        XCTAssertNotEqual(sort.label, sortBefore, "Sort still says the sort before")
        if !pickedSort.isEmpty, pickedSort != "none" {
            XCTAssertTrue(sort.label.hasSuffix(pickedSort), "Sort does not say the sort picked: \(sort.label) / \(pickedSort)")
        }
        XCTAssertEqual(title.label, titleBefore, "the page title changed with the sort")
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 60), "the sorted list never loaded")
        pause(3)
        snap("movies-sort-applied")
        XCTAssertNotEqual(grid.cells.firstMatch.label, firstBefore, "the sorted list starts with the same poster")

        // Genre.
        for _ in 0..<3 where !genre.hasFocus {
            remote.press(sort.hasFocus ? .right : .up)
            pause(1)
        }
        XCTAssertTrue(genre.hasFocus, "Genre never got the focus: \(focusedLabel)")
        remote.press(.select)
        let currentGenre = menuEntry(currentValue(of: genreBefore))
        XCTAssertTrue(currentGenre.waitForExistence(timeout: 5), "the genres did not open")
        pause(1)
        remote.press(.down)
        pause(0.6)
        remote.press(.down)
        pause(1)
        let pickedGenre = focusedLabel
        remote.press(.select)
        pause(1.5)
        XCTAssertFalse(currentGenre.exists, "the genres did not close")
        XCTAssertNotEqual(genre.label, genreBefore, "Genre still says the genre before")
        if !pickedGenre.isEmpty, pickedGenre != "none" {
            XCTAssertTrue(genre.label.hasSuffix(pickedGenre), "Genre does not say the genre picked: \(genre.label) / \(pickedGenre)")
        }
        XCTAssertEqual(title.label, titleBefore, "the page title changed with the genre")
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 60), "the genre's list never loaded")
        pause(3)
        snap("movies-genre-applied")
        // Down from the header lands on the first row of the new list.
        remote.press(.down)
        pause(1.2)
        guard let cell = focusedCell(in: grid), let row = rows(of: grid).first else { return XCTFail("Down from the header did not reach a poster") }
        XCTAssertEqual(cell.frame.minY, row.minY, accuracy: 30, "Down from the header did not land on the first row of the new list")
    }

    // MARK: - A poster's menu

    /// Holding Select on a movie: marked watched, its poster says so in
    /// place (the tick, the caption, what VoiceOver reads) with the focus
    /// still on it; marked unwatched, it no longer does. Added to the
    /// watchlist, the caption says so.
    func testAPostersMenuChangesItInPlace() throws {
        launch(["-PTDebugTab", "movies", "-PTDebugLibraryInMemory", "YES", "-PTDebugPosterPlayDryRun", "YES"])
        let grid = self.grid("MoviesViewController")
        let cell = try focusPoster(in: grid)
        let identifier = cell.identifier, before = cell.label
        let watchedWord = isEnglish ? "Watched" : "Vu", listWord = isEnglish ? "In Watchlist" : "Dans ma liste"
        XCTAssertFalse(before.contains(watchedWord), "the movie is already watched: \(before)")

        remote.press(.select, forDuration: 1.6)
        let markWatched = labelled(isEnglish ? "Mark as Watched" : "Marquer comme vu")
        XCTAssertTrue(markWatched.waitForExistence(timeout: 5), "the poster's menu did not open")
        XCTAssertTrue(labelled(isEnglish ? "Add to Watchlist" : "Ajouter à ma liste").exists, "no watchlist action in the menu")
        pause(0.8)
        snap("movies-context-menu")
        try choose(markWatched, at: 2)
        pause(1.5)
        XCTAssertFalse(element("Detail.Title").exists, "the menu opened the page")
        guard let watched = focusedCell(in: grid) else { return XCTFail("no poster has the focus after the menu") }
        XCTAssertEqual(watched.identifier, identifier, "the focus is not back on the poster")
        XCTAssertTrue(watched.label.contains(watchedWord), "the poster does not say it is watched: \(watched.label)")
        snap("movies-marked-watched")

        remote.press(.select, forDuration: 1.6)
        let markUnwatched = labelled(isEnglish ? "Mark as Unwatched" : "Marquer comme non vu")
        XCTAssertTrue(markUnwatched.waitForExistence(timeout: 5), "the menu does not offer to unmark a watched movie")
        pause(0.8)
        try choose(markUnwatched, at: 2)
        pause(1.5)
        XCTAssertEqual(focusedCell(in: grid)?.label, before, "the poster is not back as it was")

        remote.press(.select, forDuration: 1.6)
        let add = labelled(isEnglish ? "Add to Watchlist" : "Ajouter à ma liste")
        XCTAssertTrue(add.waitForExistence(timeout: 5), "the menu did not open the third time")
        pause(0.8)
        try choose(add, at: 1)
        pause(1.5)
        guard let listed = focusedCell(in: grid) else { return XCTFail("no poster has the focus after adding to the watchlist") }
        XCTAssertEqual(listed.identifier, identifier, "the focus is not back on the poster")
        XCTAssertTrue(listed.label.contains(listWord), "the poster does not say it is in the watchlist: \(listed.label)")
        snap("movies-added-to-watchlist")
    }

    // MARK: - Watchlist

    /// The Watchlist with movies and shows: two titled sections of posters,
    /// the title added last first; a poster removed by its menu leaves the
    /// grid and the focus stays on a poster.
    func testTheWatchlistShowsItsPostersAndLosesTheOneRemoved() throws {
        launch(["-PTDebugTab", "watchlist", "-PTDebugLibraryInMemory", "YES", "-PTDebugPosterPlayDryRun", "YES",
                "-PTDebugWatchlist", (Self.watchlistMovies + Self.watchlistShows).map { $0.argument }.joined(separator: ";"),
                "-moviesWatchedlist", "(tt0816692)", "-moviesProgress", #"{ tt1375666 = "0.35"; }"#])
        let grid = self.grid("WatchlistViewController")
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 30), "the watchlist is empty")
        pause(2)
        XCTAssertEqual(grid.cells.count, Self.watchlistMovies.count + Self.watchlistShows.count, "not every title of the watchlist has a poster")
        // The last one added comes first.
        XCTAssertEqual(grid.cells.firstMatch.identifier, "Grid.Card.\(Self.watchlistMovies.last!.id)", "the movie added last is not first")
        let first = try focusPoster(in: grid)
        pause(1)
        snap("watchlist")
        try expectCaption(element("Grid.Caption"), under: first, in: grid)
        let removed = first.identifier
        // The posters of the section, in order: the one after the poster
        // removed takes its place and the focus, or the one before it for
        // the last of the section.
        let movies = grid.cells.allElementsBoundByIndex.prefix(Self.watchlistMovies.count).map { $0.identifier }
        guard let index = movies.firstIndex(of: removed) else { return XCTFail("the focus is not on a movie of the watchlist: \(removed)") }
        let heir = index + 1 < movies.count ? movies[index + 1] : movies[index - 1]

        remote.press(.select, forDuration: 1.6)
        let remove = labelled(isEnglish ? "Remove from Watchlist" : "Retirer de ma liste")
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "the menu of a watchlist poster does not offer to remove it")
        pause(0.8)
        try choose(remove, at: 1)
        pause(2)
        XCTAssertFalse(grid.cells[removed].exists, "the poster removed is still in the grid")
        XCTAssertEqual(grid.cells.count, Self.watchlistMovies.count + Self.watchlistShows.count - 1, "one poster less")
        guard let next = focusedCell(in: grid) else { return XCTFail("the focus left the posters when one was removed: \(focusedLabel)") }
        XCTAssertEqual(next.identifier, heir, "the focus is not on the poster next to the one removed")
        snap("watchlist-one-removed")
    }

    // MARK: - Menu

    /// Menu from the rows below goes back to the top of the grid, in the
    /// same column, with the header and the tab bar; from the top it goes to
    /// the tab bar; from the tab bar it leaves the app.
    func testMenuGoesToTheTopThenToTheTabBar() throws {
        launch(["-PTDebugTab", "movies"])
        let grid = self.grid("MoviesViewController")
        let top = try focusPoster(in: grid)
        let firstRowY = top.frame.minY
        remote.press(.right)
        pause(0.6)
        remote.press(.right)
        pause(0.6)
        guard let column = focusedCell(in: grid)?.frame.minX else { return XCTFail("no poster has the focus") }
        for _ in 0..<4 {
            remote.press(.down)
            pause(0.9)
        }
        guard let below = focusedCell(in: grid) else { return XCTFail("no poster has the focus four rows down") }
        XCTAssertFalse(element("GridHeader.Sort").isOnScreen(app), "the header did not scroll away four rows down")
        snap("movies-four-rows-down")
        _ = below

        remote.press(.menu)
        pause(2)
        XCTAssertEqual(app.state, .runningForeground, "Menu four rows down left the app")
        guard let back = focusedCell(in: grid) else { return XCTFail("Menu did not put the focus on a poster: \(focusedLabel)") }
        XCTAssertEqual(back.frame.minY, firstRowY, accuracy: 2, "Menu did not go back to the first row")
        XCTAssertEqual(back.frame.minX, column, accuracy: 2, "Menu did not keep the column")
        XCTAssertTrue(element("GridHeader.Sort").isOnScreen(app), "the header is not back")
        snap("movies-menu-back-to-top")

        remote.press(.menu)
        pause(1.5)
        XCTAssertEqual(app.state, .runningForeground, "Menu at the top of the grid left the app at once")
        XCTAssertTrue(tabBarHasFocus, "Menu at the top of the grid did not go to the tab bar: \(focusedLabel)")
        XCTAssertEqual(app.tabBars.firstMatch.identifier, "TabBar.movies", "the tab changed")

        remote.press(.menu)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 8) || app.state != .runningForeground, "Menu in the tab bar did not leave the app")
    }

    /// A person's page pushed on a tab (a detail page's cast, Search's
    /// people): one Menu goes back to the tab's grid. Menu on a tab's first
    /// screen goes to the tab bar; on a pushed page it took the focus to the
    /// tab bar too, and going back needed a second press.
    func testMenuOnAPushedPersonPageGoesBack() throws {
        launch(["-PTDebugTab", "movies", "-PTDebugOpenPerson", "nm0000138|Leonardo DiCaprio", "-PTDebugFocusContent", "YES"])
        let person = grid("PersonViewController")
        XCTAssertTrue(person.waitForExistence(timeout: 20), "the person's page did not open")
        pause(4)
        XCTAssertFalse(tabBarHasFocus, "the focus is not in the person's page: \(focusedLabel)")
        snap("person-page")

        remote.press(.menu)
        pause(2)
        XCTAssertEqual(app.state, .runningForeground, "Menu on the person's page left the app")
        XCTAssertFalse(person.exists, "Menu on the person's page did not go back: \(focusedLabel)")
        XCTAssertTrue(grid("MoviesViewController").exists, "Menu on the person's page did not go back to Movies")
        snap("person-page-menu-back")
    }

    // MARK: - The list changes under the focus

    /// Down through the list while its next pages arrive: the focus is
    /// always on a poster, in the same column, and the list grows.
    func testNewPagesKeepTheFocusInItsColumn() throws {
        launch(["-PTDebugTab", "movies"])
        let grid = self.grid("MoviesViewController")
        _ = try focusPoster(in: grid)
        for _ in 0..<3 {
            remote.press(.right)
            pause(0.5)
        }
        pause(0.5)
        guard let start = focusedCell(in: grid) else { return XCTFail("no poster has the focus") }
        let column = start.frame.minX
        var seen: Set<String> = [start.identifier]
        var trail: [String] = []
        let retry = element("Grid.RetryMore")
        var retries = 0
        for step in 0..<16 {
            remote.press(.down)
            pause(1.1)
            // A page that really failed (the catalog's host answers an
            // error now and then): Down from the last row is on Retry, the
            // row above still whole. Retry, and the focus is back on the
            // poster it left.
            if hasFocus(retry), retries < 3 {
                retries += 1
                remote.press(.select)
                pause(5)
            }
            guard let cell = focusedCell(in: grid) else {
                return XCTFail("step \(step): the focus left the posters (\(focusedLabel)); trail \(trail)")
            }
            XCTAssertEqual(cell.frame.minX, column, accuracy: 2, "step \(step): the focus changed column")
            trail.append(cell.identifier)
            seen.insert(cell.identifier)
        }
        snap("movies-pages-down")
        // 17 rows of six: past the first page (49 or 50 titles).
        XCTAssertGreaterThanOrEqual(seen.count, 12, "the focus did not go down the list: \(trail)")
        XCTAssertFalse(tabBarHasFocus)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The list saved by an earlier launch is painted first; the network's,
    /// which differs, replaces it while the focus is on a poster of the
    /// second row: the focus stays on that place of the grid.
    func testTheSavedListReplacedKeepsTheFocus() throws {
        // A first launch saves the list.
        launch(["-PTDebugTab", "movies"])
        XCTAssertTrue(grid("MoviesViewController").cells.firstMatch.waitForExistence(timeout: 60), "the grid never loaded")
        pause(3)
        app.terminate()
        pause(1)

        launch(["-PTDebugTab", "movies", "-PTDebugStaleSnapshot", "YES", "-PTDebugFirstPageDelay", "14"])
        let grid = self.grid("MoviesViewController")
        _ = try focusPoster(in: grid)
        let savedFirst = grid.cells.firstMatch.identifier
        // In the first row: the grid stays at its top, where the network's
        // list takes the saved one's place as soon as it arrives. (Scrolled
        // down, it waits until the grid is back at its top.)
        remote.press(.right)
        pause(0.6)
        remote.press(.right)
        pause(1)
        guard let before = focusedCell(in: grid) else { return XCTFail("no poster has the focus") }
        let frame = before.frame, savedFocused = before.identifier
        snap("snapshot-before")

        // The network's list replaces the saved one.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, grid.cells.firstMatch.identifier == savedFirst { pause(0.5) }
        XCTAssertNotEqual(grid.cells.firstMatch.identifier, savedFirst, "the network's list never replaced the saved one")
        pause(1.5)
        snap("snapshot-replaced")
        XCTAssertFalse(tabBarHasFocus, "the focus went to the tab bar when the list was replaced")
        guard let after = focusedCell(in: grid) else { return XCTFail("the focus left the posters when the list was replaced: \(focusedLabel)") }
        XCTAssertNotEqual(after.identifier, savedFocused, "the poster under the focus is still the saved list's")
        XCTAssertEqual(after.frame.minX, frame.minX, accuracy: 2, "the focus changed column")
        XCTAssertEqual(after.frame.minY, frame.minY, accuracy: 2, "the focus changed row")
        try expectCaption(element("Grid.Caption"), under: after, in: grid)
    }

    // MARK: - Errors and Retry

    /// A list that cannot load: the message and Retry, which loads it.
    func testAnEmptyGridThatFailedOffersRetry() throws {
        launch(["-PTDebugTab", "movies", "-PTDebugFailPages", "1"])
        let retry = element("Grid.Retry")
        XCTAssertTrue(retry.waitForExistence(timeout: 20), "no Retry on a grid that could not load")
        XCTAssertTrue(element("Grid.Message").exists, "no message on a grid that could not load")
        if isEnglish { XCTAssertEqual(element("Grid.Message").label, "You're Offline") }
        XCTAssertTrue(element("GridHeader.Sort").exists, "the header is gone with the error")
        for _ in 0..<4 where !hasFocus(retry) {
            remote.press(.down)
            pause(1)
        }
        XCTAssertTrue(hasFocus(retry), "Down never reached Retry: \(focusedLabel)")
        snap("movies-error")
        remote.press(.select)
        let grid = self.grid("MoviesViewController")
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 60), "Retry did not load the list")
        pause(2)
        XCTAssertFalse(retry.exists, "the error stayed over the list")
        snap("movies-error-retried")
        // The focus does not stay on a button that is gone, nor in the tab bar for good.
        remote.press(.down)
        pause(1.2)
        XCTAssertNotNil(focusedCell(in: grid), "Down after Retry did not reach a poster: \(focusedLabel)")
    }

    /// The next page fails: the grid keeps its posters, its last row offers
    /// Retry, and Retry adds the page.
    func testAPageThatFailedKeepsTheGridAndOffersRetry() throws {
        launch(["-PTDebugTab", "movies", "-PTDebugFailPages", "2"])
        let grid = self.grid("MoviesViewController")
        _ = try focusPoster(in: grid)
        let retry = element("Grid.RetryMore")
        var before = 0
        // Down to the end of the first page.
        for _ in 0..<12 where !hasFocus(retry) {
            before = max(before, lastIndex(in: grid))
            remote.press(.down)
            pause(1.1)
        }
        XCTAssertTrue(hasFocus(retry), "Down from the last row never reached Retry: \(focusedLabel)")
        XCTAssertGreaterThan(grid.cells.count, 0, "the grid lost its posters")
        snap("movies-page-error")
        remote.press(.select)
        pause(6)
        XCTAssertFalse(retry.exists && retry.isOnScreen(app), "Retry stayed after the page loaded")
        guard let cell = focusedCell(in: grid) else { return XCTFail("the focus is not back on a poster after Retry: \(focusedLabel)") }
        _ = cell
        // Further down: posters of the page that had failed.
        for _ in 0..<3 {
            remote.press(.down)
            pause(1.1)
        }
        XCTAssertNotNil(focusedCell(in: grid), "no poster below the row that offered Retry")
        snap("movies-page-retried")
    }

    // MARK: - Search

    /// Search results are posters of the same grid: they start close under
    /// the scope bar, and the focused one has its caption.
    func testSearchResultsArePostersWithACaption() throws {
        launch(["-PTDebugSearch", "dune"])
        let results = grid("SearchViewController")
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline, !(results.exists && results.cells.count > 3) { pause(1) }
        guard results.exists, results.cells.count > 3 else { throw XCTSkip("the search found too few results") }
        pause(2)
        snap("search-results")
        let screen = app.windows.firstMatch.frame
        let rows = self.rows(of: results)
        XCTAssertFalse(rows.isEmpty)
        if let first = rows.first {
            XCTAssertEqual(first.count, 6, "not six results in the first row")
            XCTAssertLessThanOrEqual(first.maxY, screen.maxY, "the first row of results is not whole on the screen")
        }
        var cell = focusedCell(in: results)
        for _ in 0..<6 where cell == nil {
            remote.press(.down)
            pause(1)
            cell = focusedCell(in: results)
        }
        guard let focusedResult = cell else { return XCTFail("Down never reached the results") }
        pause(1)
        snap("search-result-focused")
        try expectCaption(element("Grid.Caption"), under: focusedResult, in: results)
    }

    // MARK: - Scrolling

    /// Not a check: scrolls the Movies grid down through its pages and
    /// prints what `-PTDebugHitches` counted meanwhile (run with
    /// `PT_UITEST_HITCHES=1`; the numbers are the simulator's).
    func testScrollingReportsItsLateFrames() throws {
        guard ProcessInfo.processInfo.environment["PT_UITEST_HITCHES"]?.isEmpty == false else {
            throw XCTSkip("PT_UITEST_HITCHES is not set")
        }
        launch(["-PTDebugTab", "movies", "-PTDebugHitches", "25"])
        let grid = self.grid("MoviesViewController")
        _ = try focusPoster(in: grid)
        let hitches = element("Debug.Hitches")
        XCTAssertTrue(hitches.waitForExistence(timeout: 40), "the hitch count never started")
        pause(1)
        let start = hitches.label
        for _ in 0..<30 {
            remote.press(.down)
            pause(0.7)
        }
        for _ in 0..<30 {
            remote.press(.up)
            pause(0.35)
        }
        pause(1.2)
        print("PT_HITCHES start: \(start)")
        print("PT_HITCHES end: \(hitches.label) posters: \(lastIndex(in: grid))")
    }

    // MARK: - Fixtures

    private struct Title {
        let kind: String, id: String, title: String, year: String, rating: String, minutes: String
        /// One title of `-PTDebugWatchlist`.
        var argument: String { return [kind, id, title, year, rating, minutes].joined(separator: "|") }
    }

    /// Added in this order: the grid shows the last one first.
    private static let watchlistMovies = [
        Title(kind: "movie", id: "tt0816692", title: "Interstellar", year: "2014", rating: "8.7", minutes: "169"),
        Title(kind: "movie", id: "tt1375666", title: "Inception", year: "2010", rating: "8.8", minutes: "148"),
        Title(kind: "movie", id: "tt15239678", title: "Dune: Part Two", year: "2024", rating: "8.5", minutes: "166"),
        Title(kind: "movie", id: "tt0468569", title: "The Dark Knight", year: "2008", rating: "9.1", minutes: "152"),
    ]
    private static let watchlistShows = [
        Title(kind: "show", id: "tt0903747", title: "Breaking Bad", year: "2008", rating: "9.5", minutes: "47"),
        Title(kind: "show", id: "tt0944947", title: "Game of Thrones", year: "2011", rating: "9.2", minutes: "57"),
        Title(kind: "show", id: "tt5875444", title: "Slow Horses", year: "2022", rating: "8.3", minutes: "45"),
    ]

    // MARK: - Steps

    private func launch(_ arguments: [String]) {
        let app = XCUIApplication()
        // Home is the first tab: its hub is fed from recorded answers, as in
        // NavigationUITests, so its own requests stay out of these tests.
        let arguments = arguments + ["-PTDebugHomeFixtures", Self.homeFixtures]
        let locale = language == "fr" ? "fr_FR" : "en_US"
        app.launchArguments = [
            "-tosAccepted", "YES",
            "-lastWhatsNewVersion", "99",
            "-themeSongVolume", "0",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
        ] + arguments
        app.launch()
        self.app = app
    }

    /// The recorded answers Home is fed from, read by the app from the
    /// source tree (the simulator shares the Mac's disk).
    private static var homeFixtures: String {
        if let folder = ProcessInfo.processInfo.environment["PT_UITEST_HOME_FIXTURES"], !folder.isEmpty { return folder }
        return URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PopcornTimeTests/Fixtures/Home").path
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

    /// Up from the posters until `control` (Sort / Genre) has the focus.
    private func focus(_ control: XCUIElement, from grid: XCUIElement) throws {
        for _ in 0..<6 where !control.hasFocus {
            if focusedCell(in: grid) != nil {
                remote.press(.up)
            } else if tabBarHasFocus {
                remote.press(.down)
            } else {
                remote.press(.left)
            }
            pause(1)
        }
        XCTAssertTrue(control.hasFocus, "\(control.identifier) never got the focus: \(focusedLabel)")
    }

    /// Selects the action at `position` of an open poster menu (0: Play, 1:
    /// the watchlist, 2: the watched mark of a movie). The menu opens on
    /// Play and does not tell XCUITest which of its rows has the focus: the
    /// row is reached by counting, and the test then checks what the action
    /// did. The app runs with `-PTDebugPosterPlayDryRun`: a Select that
    /// stayed on Play only logs.
    private func choose(_ action: XCUIElement, at position: Int) throws {
        XCTAssertTrue(action.exists, "the menu does not have the action")
        for _ in 0..<position {
            remote.press(.down)
            pause(0.7)
        }
        remote.press(.select)
    }

    /// `element` is there and has the focus (asking an element that is not
    /// there fails the test).
    private func hasFocus(_ element: XCUIElement) -> Bool {
        return element.exists && element.hasFocus
    }

    /// The caption is on the screen, just under `cell`, over no poster, and
    /// starts with the title the poster reads.
    private func expectCaption(_ caption: XCUIElement, under cell: XCUIElement, in grid: XCUIElement,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(caption.waitForExistence(timeout: 3), "no caption under the focused poster", file: file, line: line)
        pause(0.4)
        let frame = caption.frame, poster = cell.frame
        let screen = app.windows.firstMatch.frame
        XCTAssertTrue(screen.contains(frame), "the caption is not whole on the screen: \(frame)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, poster.maxY, "the caption is over its poster: \(frame) / \(poster)", file: file, line: line)
        XCTAssertLessThan(frame.minY - poster.maxY, 70, "the caption is far from its poster: \(frame) / \(poster)", file: file, line: line)
        // It starts on the poster's left edge (the focused poster is
        // lifted: 13 pt wider on each side than at rest), or ends on the
        // rows' right edge when it would run past it.
        let rowsRight = rows(of: grid).map { $0.maxX }.max() ?? screen.maxX
        XCTAssertTrue(abs(frame.minX - poster.minX) <= 16 || (abs(frame.maxX - rowsRight) <= 16 && frame.minX < poster.minX),
                      "the caption is not under its poster: \(frame) / \(poster)", file: file, line: line)
        // The posters of the rows above and below (not the focused one, which is lifted).
        for other in grid.cells.allElementsBoundByIndex where other.exists && !other.hasFocus {
            let shared = other.frame.intersection(frame)
            XCTAssertTrue(shared.isNull || shared.height < 2 || shared.width < 2,
                          "the caption is over a poster: \(frame) over \(other.frame)", file: file, line: line)
        }
        let title = cell.label.components(separatedBy: ", ").first ?? cell.label
        XCTAssertTrue(caption.label.hasPrefix(String(title.prefix(12))), "the caption is not the focused poster's: \(caption.label) / \(cell.label)",
                      file: file, line: line)
    }

    // MARK: - Queries

    /// A row of posters on the screen.
    private struct Row: CustomStringConvertible {
        var minY: CGFloat, maxY: CGFloat, minX: CGFloat, maxX: CGFloat, count: Int
        var description: String { return "(\(Int(minY))–\(Int(maxY)) ×\(count))" }
    }

    /// The rows of `grid`'s posters that are on the screen, top first.
    private func rows(of grid: XCUIElement) -> [Row] {
        let screen = app.windows.firstMatch.frame
        var rows: [Row] = []
        let frames = grid.cells.allElementsBoundByIndex.map { $0.frame }.filter { !$0.isEmpty && $0.intersects(screen) }
        for frame in frames.sorted(by: { ($0.minY, $0.minX) < ($1.minY, $1.minX) }) {
            if let index = rows.firstIndex(where: { abs($0.minY - frame.minY) < 30 }) {
                rows[index].minX = min(rows[index].minX, frame.minX)
                rows[index].maxX = max(rows[index].maxX, frame.maxX)
                rows[index].count += 1
            } else {
                rows.append(Row(minY: frame.minY, maxY: frame.maxY, minX: frame.minX, maxX: frame.maxX, count: 1))
            }
        }
        return rows
    }

    /// How many posters the grid has made so far (the cells on and near the screen are what XCUITest sees).
    private func lastIndex(in grid: XCUIElement) -> Int {
        return grid.cells.count
    }

    private func grid(_ name: String) -> XCUIElement {
        return app.collectionViews["MediaGrid.\(name)"]
    }

    private func element(_ identifier: String) -> XCUIElement {
        return app.descendants(matching: .any)[identifier]
    }

    private func labelled(_ label: String) -> XCUIElement {
        return app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func focusedCell(in grid: XCUIElement) -> XCUIElement? {
        let cell = grid.cells.matching(Self.focused).firstMatch
        return cell.exists ? cell : nil
    }

    /// "Trending" of "Sort: Trending".
    private func currentValue(of control: String) -> String {
        return control.components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespaces) ?? control
    }

    /// An entry of an open Sort / Genre menu.
    private func menuEntry(_ title: String) -> XCUIElement {
        return app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    private var focusedLabel: String {
        let focused = app.descendants(matching: .any).matching(Self.focused).firstMatch
        return focused.exists ? (focused.label.isEmpty ? focused.identifier : focused.label) : "none"
    }

    private var tabBarHasFocus: Bool {
        return app.tabBars.descendants(matching: .any).matching(Self.focused).firstMatch.exists
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

private extension XCUIElement {
    /// Exists and is at least partly on the screen.
    func isOnScreen(_ app: XCUIApplication) -> Bool {
        return exists && !frame.isEmpty && frame.intersects(app.windows.firstMatch.frame)
    }
}
