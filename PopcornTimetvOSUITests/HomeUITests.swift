import XCTest

/// The Home tab with the Siri Remote: the app opens on it, with the billboard
/// on the hero items; Down reaches the shelves and the billboard then
/// follows the focused card; the Watchlist button adds the title in view;
/// Right scrolls a shelf; a card opens its page
/// and Menu comes back to that card; See All opens the grid on the shelf's
/// sort and the focus comes back to it; Menu from the shelves goes back to
/// the top, and leaves the app from there; the tab bar reaches every tab.
///
/// Runs like `NavigationUITests`: the tvOS 26.5 simulator, a DEBUG build of
/// the app. The hub is fed from the recorded answers of
/// PopcornTimeTests/Fixtures/Home (`-PTDebugHomeFixtures`, at the instant
/// they were recorded): the page does not depend on what the hosts answer
/// that day. Two things still read the network: the artwork (never checked)
/// and the title's page of `testACardOpensItsPageAndMenuReturnsToTheCard`,
/// which loads like any page of the app. Nothing is ever played: Play,
/// Play/Pause and the resume cards run with `-PTDebugHomeDryRunPlay`, which
/// opens the page and only says what would have played. The watch state
/// lives in memory (`-PTDebugLibraryInMemory`): nothing is written to the
/// app's defaults.
///
/// `PT_UITEST_SHOTS=<folder>` (`TEST_RUNNER_PT_UITEST_SHOTS` on the
/// xcodebuild command line) saves a screenshot before every remote press
/// and at the end of each test.
final class HomeUITests: XCTestCase {

    private let remoteControl = XCUIRemote.shared
    private var app: XCUIApplication!
    private var shotIndex = 0

    private static let focused = NSPredicate(format: "hasFocus == true")

    /// The recorded answers, read by the app from the source tree (the
    /// simulator shares the Mac's disk); `PT_UITEST_HOME_FIXTURES` names
    /// another folder.
    private static var fixtures: String {
        if let folder = ProcessInfo.processInfo.environment["PT_UITEST_HOME_FIXTURES"], !folder.isEmpty { return folder }
        return URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PopcornTimeTests/Fixtures/Home").path
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

    // MARK: - The first screen

    /// The app opens on Home: the tab is selected, the billboard shows a
    /// hero item with its buttons, the first shelf shows under it. Down from
    /// the tab bar lands on Play, and Up goes back to the tab bar.
    func testLaunchLandsOnHomeWithTheBillboard() throws {
        launch()
        XCTAssertTrue(element("Home.Hero").waitForExistence(timeout: 20), "the billboard never showed")
        XCTAssertEqual(selectedTab, "home", "Home is not the selected tab")
        XCTAssertTrue(element("Home.Play").exists && element("Home.Info").exists && element("Home.Watchlist").exists,
                      "the billboard has not its three buttons")
        XCTAssertFalse(element("Home.Hero.Title").label.isEmpty, "the billboard names no title")
        XCTAssertTrue(element("Home.Section.trendingMovies").exists, "the first shelf is not on the first screen")
        XCTAssertEqual(element("Home.HeroPage").value as? String, "0", "the billboard does not start on its first item")

        pause(2)
        XCTAssertTrue(tabBarHasFocus, "the focus does not start in the tab bar: \(focusedLabel)")
        press(.down)
        pause(1)
        XCTAssertEqual(focusedIdentifier, "Home.Play", "Down from the tab bar did not land on Play")
        press(.up)
        pause(1)
        XCTAssertTrue(tabBarHasFocus, "Up from the billboard did not reach the tab bar: \(focusedLabel)")
        XCTAssertEqual(selectedTab, "home")
    }

    /// Right on the last button and Left on the first turn the billboard's
    /// pages; between the buttons they only move the focus.
    func testLeftAndRightTurnTheBillboardsPages() throws {
        launch()
        try focusPlay()
        let page = element("Home.HeroPage")
        let first = element("Home.Hero.Title").label
        press(.right)
        pause(0.8)
        press(.right)
        pause(0.8)
        XCTAssertEqual(focusedIdentifier, "Home.Watchlist", "Right twice did not reach the last button")
        XCTAssertEqual(page.value as? String, "0", "moving between the buttons turned the page")
        press(.right)
        pause(1.2)
        XCTAssertEqual(page.value as? String, "1", "Right on the last button did not show the next item")
        XCTAssertNotEqual(element("Home.Hero.Title").label, first, "the billboard still names the first item")
        XCTAssertEqual(focusedIdentifier, "Home.Watchlist", "the focus left the button")
        press(.left)
        pause(0.8)
        press(.left)
        pause(0.8)
        XCTAssertEqual(focusedIdentifier, "Home.Play")
        XCTAssertEqual(page.value as? String, "1", "moving between the buttons turned the page")
        press(.left)
        pause(1.2)
        XCTAssertEqual(page.value as? String, "0", "Left on the first button did not show the item before")
        XCTAssertEqual(element("Home.Hero.Title").label, first)
    }

    /// The billboard's Watchlist button adds the title in view to the
    /// watchlist and takes it out again (in memory: nothing is stored).
    func testTheWatchlistButtonAddsAndRemovesTheBillboardsTitle() throws {
        launch()
        try focusPlay()
        press(.right)
        pause(0.8)
        press(.right)
        pause(0.8)
        let button = element("Home.Watchlist")
        XCTAssertEqual(focusedIdentifier, "Home.Watchlist")
        XCTAssertEqual(button.label, "Add to Watchlist", "the title is in the watchlist of an empty library")
        press(.select)
        pause(1.5)
        XCTAssertEqual(button.label, "Remove from Watchlist", "Select on Watchlist did not add the title")
        XCTAssertEqual(focusedIdentifier, "Home.Watchlist", "the focus left the button")
        XCTAssertEqual(element("Home.HeroPage").value as? String, "0", "the billboard turned its page")
        press(.select)
        pause(1.5)
        XCTAssertEqual(button.label, "Add to Watchlist", "Select again did not take the title out")
    }

    // MARK: - The shelves

    /// Down from Play reaches the first shelf; the billboard, now compact,
    /// names the focused card, and follows the focus along the shelf.
    func testDownReachesTheFirstShelfAndTheBillboardFollowsTheFocus() throws {
        launch()
        try focusPlay()
        press(.down)
        pause(1.5)
        // (An element is a query: what it says is read now, before the next press.)
        let card = try XCTUnwrap(focusedCard(in: "trendingMovies"), "Down from Play did not reach the first shelf: \(focusedLabel)")
        let first = card.identifier, firstTitle = title(of: card)
        let billboard = element("Home.Billboard")
        XCTAssertTrue(billboard.waitForExistence(timeout: 5), "no billboard over the shelves")
        XCTAssertTrue(billboard.label.hasPrefix(firstTitle), "the billboard (\(billboard.label)) does not show the focused card (\(firstTitle))")

        press(.right)
        pause(1.5)
        let next = try XCTUnwrap(focusedCard(in: "trendingMovies"), "Right left the shelf: \(focusedLabel)")
        let second = next.identifier, secondTitle = title(of: next)
        XCTAssertNotEqual(second, first, "Right did not move the focus")
        XCTAssertNotEqual(secondTitle, firstTitle)
        XCTAssertTrue(billboard.label.hasPrefix(secondTitle), "the billboard (\(billboard.label)) did not follow the focus to \(secondTitle)")

        // The next shelf, then back up to the buttons: the hero again.
        press(.down)
        pause(1.5)
        XCTAssertNotNil(focusedCard(in: "newMovies"), "Down did not reach the second shelf: \(focusedLabel)")
        press(.up)
        pause(1.2)
        XCTAssertNotNil(focusedCard(in: "trendingMovies"), "Up did not go back to the first shelf: \(focusedLabel)")
        press(.up)
        pause(1.5)
        XCTAssertTrue(["Home.Play", "Home.Info", "Home.Watchlist"].contains(focusedIdentifier), "Up from the first shelf did not reach the buttons: \(focusedLabel)")
        XCTAssertFalse(billboard.exists, "the compact billboard stayed at the top of the page")
    }

    /// Right moves along a shelf, one card a press, and the shelf scrolls:
    /// its first card leaves the screen, the focused one stays on it.
    func testRightScrollsAShelf() throws {
        launch()
        try focusPlay()
        press(.down)
        pause(1.5)
        let first = try XCTUnwrap(focusedCard(in: "trendingMovies"), "no card focused: \(focusedLabel)")
        let firstIdentifier = first.identifier
        let screen = app.windows.firstMatch.frame
        var seen = [firstIdentifier]
        for _ in 0..<8 {
            press(.right)
            pause(0.7)
            let card = try XCTUnwrap(focusedCard(in: "trendingMovies"), "the focus left the shelf: \(focusedLabel)")
            XCTAssertFalse(seen.contains(card.identifier), "Right did not move to a new card: \(card.identifier)")
            seen.append(card.identifier)
            XCTAssertTrue(screen.contains(card.frame), "the focused card is not whole on the screen: \(card.frame)")
        }
        let start = element("Home.Section.trendingMovies").buttons[firstIdentifier]
        XCTAssertFalse(start.exists && screen.intersects(start.frame), "the shelf did not scroll: its first card is still on screen")
    }

    /// Select on a card opens the title's page; Menu comes back to Home
    /// with the focus on that card, the page where it was.
    func testACardOpensItsPageAndMenuReturnsToTheCard() throws {
        launch()
        try focusPlay()
        press(.down)
        pause(1.2)
        press(.right)
        pause(1.2)
        let card = try XCTUnwrap(focusedCard(in: "trendingMovies"), "no card focused: \(focusedLabel)")
        let identifier = card.identifier, frame = card.frame
        press(.select)
        XCTAssertTrue(element("Detail.Title").waitForExistence(timeout: 60), "the title's page never opened")
        XCTAssertFalse(element("Debug.HomePlay").exists, "Select on a card asked to play")
        pause(2)
        press(.menu)
        pause(2.5)
        XCTAssertFalse(element("Detail.Title").exists, "Menu did not leave the page")
        XCTAssertEqual(app.state, .runningForeground, "Menu on the page left the app")
        XCTAssertEqual(selectedTab, "home")
        XCTAssertEqual(focusedIdentifier, identifier, "the focus is not back on the card it left")
        let back = try XCTUnwrap(focusedCard(in: "trendingMovies"))
        XCTAssertEqual(back.frame.minY, frame.minY, accuracy: 4, "the page moved while the title's page was open")
        XCTAssertEqual(back.frame.minX, frame.minX, accuracy: 4, "the shelf moved while the title's page was open")
    }

    /// Play/Pause on a card plays it, Play on the billboard plays the hero
    /// item (the dry run only says so and opens the page).
    func testPlayPauseOnACardAndPlayOnTheBillboardAskToPlay() throws {
        launch()
        try focusPlay()
        let hero = element("Home.Hero.Title").label
        press(.select)
        let played = element("Debug.HomePlay")
        XCTAssertTrue(played.waitForExistence(timeout: 10), "Play on the billboard asked for nothing")
        XCTAssertTrue(played.label.hasPrefix("tt"), "Play did not name a title: \(played.label)")
        XCTAssertFalse(hero.isEmpty)
        app.terminate()
        pause(1)

        launch()
        try focusPlay()
        press(.down)
        pause(1.5)
        let card = try XCTUnwrap(focusedCard(in: "trendingMovies"), "no card focused: \(focusedLabel)")
        let identifier = card.identifier
        press(.playPause)
        XCTAssertTrue(played.waitForExistence(timeout: 10), "Play/Pause on a card asked for nothing")
        XCTAssertEqual("Home.Card." + played.label, identifier, "Play/Pause played another title")
    }

    /// Holding Select on a card opens its menu (the watchlist, watched);
    /// Menu closes it and the focus is back on the card.
    func testHoldingSelectOnACardOpensItsMenu() throws {
        launch()
        try focusPlay()
        press(.down)
        pause(1.5)
        let card = try XCTUnwrap(focusedCard(in: "trendingMovies"), "no card focused: \(focusedLabel)")
        let identifier = card.identifier
        // (The billboard's Watchlist button is read "Add to Watchlist" too:
        // the menu is known by its second action.)
        let watched = labelled("Mark as Watched")
        XCTAssertFalse(watched.exists)
        snap("before-hold")
        remoteControl.press(.select, forDuration: 1.6)
        XCTAssertTrue(watched.waitForExistence(timeout: 5), "holding Select on a card did not open its menu")
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Add to Watchlist")).count, 2,
                                    "the menu does not offer the watchlist")
        XCTAssertFalse(labelled("Remove from Continue Watching").exists, "a catalogue card offers to leave Continue Watching")
        press(.menu)
        let closed = Date().addingTimeInterval(6)
        while watched.exists, Date() < closed { pause(0.5) }
        XCTAssertFalse(watched.exists, "Menu did not close the card's menu")
        pause(1)
        XCTAssertEqual(app.state, .runningForeground, "Menu on the card's menu left the app")
        XCTAssertEqual(focusedIdentifier, identifier, "the focus is not back on the card")
    }

    /// A title being watched has its card in Continue Watching, the first
    /// shelf; Select on it resumes (the dry run says so), and its menu takes
    /// it out of the shelf.
    func testAResumeCardResumesAndItsMenuRemovesIt() throws {
        launch(["-PTDebugHomeResume", "tt0816692|Interstellar|0.42|169;tt0903747|Breaking Bad|0.30|47|1|5|Gray Matter"])
        let shelf = element("Home.Section.continueWatching")
        XCTAssertTrue(shelf.waitForExistence(timeout: 20), "no Continue Watching shelf")
        let movie = shelf.buttons["Home.Card.tt0816692"], episode = shelf.buttons["Home.Card.tt0903747:1:5"]
        XCTAssertTrue(movie.exists && episode.exists, "the two titles in progress have not their cards")
        XCTAssertTrue(episode.label.contains("S1 · E5") && episode.label.contains("Gray Matter"), "the episode's card does not name it: \(episode.label)")

        try focusPlay()
        press(.down)
        pause(1.5)
        let card = try XCTUnwrap(focusedCard(in: "continueWatching"), "Down from Play did not reach Continue Watching: \(focusedLabel)")
        let identifier = card.identifier
        let remove = labelled("Remove from Continue Watching")
        snap("before-hold")
        remoteControl.press(.select, forDuration: 1.6)
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "holding Select on a resume card did not open its menu")
        // The last of the menu's four actions (Play, Watchlist, Watched, Remove).
        press(.down)
        pause(0.6)
        press(.down)
        pause(0.6)
        press(.down)
        pause(0.6)
        press(.select)
        pause(2.5)
        XCTAssertFalse(remove.exists, "the menu stayed")
        XCTAssertFalse(shelf.buttons[identifier].exists, "the card is still in the shelf")
        XCTAssertEqual(shelf.buttons.count, 1, "one card left")

        // The focus is on the card that is left: Select resumes it.
        let left = try XCTUnwrap(focusedCard(in: "continueWatching"), "the focus is not on the card that is left: \(focusedLabel)")
        let leftIdentifier = left.identifier
        press(.select)
        let played = element("Debug.HomePlay")
        XCTAssertTrue(played.waitForExistence(timeout: 10), "Select on a resume card asked for nothing")
        XCTAssertEqual("Home.Card." + played.label, leftIdentifier, "Select resumed another title")
    }

    // MARK: - See All

    /// The last card of a shelf opens the shelf's own grid, on the Home's
    /// stack: its titles in its order, under its name. Menu comes back to
    /// the See All card, where it was.
    func testSeeAllOpensTheShelfsOwnGrid() throws {
        launch(["-PTDebugHomeShelfLimit", "3"])
        try focusPlay()
        press(.down)
        pause(1.2)
        press(.down)
        pause(1.5)
        XCTAssertNotNil(focusedCard(in: "newMovies"), "Down twice did not reach New Movies: \(focusedLabel)")
        let shelfCards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'Home.Card.'"))
        let shelf = element("Home.Section.newMovies")
        let shelfIDs = shelf.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'Home.Card.'"))
            .allElementsBoundByIndex.map { $0.identifier.replacingOccurrences(of: "Home.Card.", with: "") }
        XCTAssertGreaterThan(shelfCards.count, 0)
        for _ in 0..<5 where focusedIdentifier != "Home.SeeAll.newMovies" {
            press(.right)
            pause(0.8)
        }
        XCTAssertEqual(focusedIdentifier, "Home.SeeAll.newMovies", "Right did not reach See All: \(focusedLabel)")
        let place = element("Home.SeeAll.newMovies").frame
        press(.select)
        let grid = element("SeeAll.newMovies")
        XCTAssertTrue(grid.waitForExistence(timeout: 10), "See All opened nothing")
        pause(2)
        XCTAssertEqual(selectedTab, "home", "See All left the Home tab")
        XCTAssertFalse(app.collectionViews["MediaGrid.MoviesViewController"].exists, "See All opened the Movies tab's grid")
        let gridIDs = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'SeeAll.Card.'"))
            .allElementsBoundByIndex.map { $0.identifier.replacingOccurrences(of: "SeeAll.Card.", with: "") }
        XCTAssertEqual(Array(gridIDs.prefix(shelfIDs.count)), shelfIDs, "the grid is not the shelf's titles in its order")
        XCTAssertTrue(focusedIdentifier.hasPrefix("SeeAll.Card."), "the focus is not on the grid: \(focusedLabel)")
        XCTAssertFalse(tabBarHasFocus, "the focus fell in the tab bar: \(focusedLabel)")

        press(.menu)
        pause(2)
        XCTAssertFalse(grid.exists, "Menu did not close the grid")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertEqual(focusedIdentifier, "Home.SeeAll.newMovies", "the focus did not come back to the card it left: \(focusedLabel)")
        let back = element("Home.SeeAll.newMovies").frame
        XCTAssertEqual(back.minY, place.minY, accuracy: 4, "the shelf is not back under the billboard")
        XCTAssertEqual(back.minX, place.minX, accuracy: 4, "the shelf is not where it was left")
    }

    /// Back on Home from another tab, the page gives the focus back to the
    /// card it left, which takes a moment (the shelf is scrolled under the
    /// band first). A move of the user's meanwhile wins: Right at once,
    /// from Play where Down landed, leaves the focus on More Info, and the
    /// page does not pull it back to the card.
    func testAMoveDuringTheReturnToACardIsTheUsers() throws {
        launch(["-PTDebugHomeShelfLimit", "3"])
        try focusPlay()
        press(.down)
        pause(1.2)
        press(.down)
        pause(1.5)
        for _ in 0..<5 where focusedIdentifier != "Home.SeeAll.newMovies" {
            press(.right)
            pause(0.8)
        }
        XCTAssertEqual(focusedIdentifier, "Home.SeeAll.newMovies", "Right did not reach See All: \(focusedLabel)")
        for _ in 0..<6 where !tabBarHasFocus {
            press(.up)
            pause(0.8)
        }
        XCTAssertTrue(tabBarHasFocus, "the tab bar never got the focus")
        for _ in 0..<3 where selectedTab != "movies" {
            press(.right)
            pause(1)
        }
        XCTAssertEqual(selectedTab, "movies", "Right did not reach the Movies tab")
        pause(2)
        for _ in 0..<3 where selectedTab != "home" {
            press(.left)
            pause(1)
        }
        XCTAssertEqual(selectedTab, "home", "Left did not reach the Home tab")
        // Down, then at once Right: no pause between the presses.
        snap("before-down-right")
        remoteControl.press(.down)
        remoteControl.press(.right)
        pause(3)
        XCTAssertEqual(focusedIdentifier, "Home.Info", "the focus did not stay where the user moved it: \(focusedLabel)")
        pause(1)
        XCTAssertEqual(focusedIdentifier, "Home.Info", "the focus was pulled away from where the user moved it: \(focusedLabel)")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(element("Home.Info").frame), "the page did not go back to its top with the focus")
    }

    // MARK: - Menu

    /// Menu from the shelves goes back to the top of the page, on Play;
    /// Menu there leaves the app, as on the other tabs.
    func testMenuFromAShelfReturnsToTheTopThenLeavesTheApp() throws {
        launch()
        try focusPlay()
        for _ in 0..<3 {
            press(.down)
            pause(1.2)
        }
        XCTAssertNotNil(focusedCard(in: "uhd"), "Down three times did not reach the third shelf: \(focusedLabel)")
        XCTAssertFalse(tabBarIsOnScreen, "the tab bar is still on screen over the shelves")
        press(.menu)
        pause(2)
        XCTAssertEqual(app.state, .runningForeground, "Menu from a shelf left the app")
        XCTAssertEqual(focusedIdentifier, "Home.Play", "Menu from a shelf did not go back to Play: \(focusedLabel)")
        XCTAssertFalse(element("Home.Billboard").exists, "the compact billboard stayed at the top of the page")
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(element("Home.Play").frame), "Play is not on the screen")
        XCTAssertTrue(tabBarIsOnScreen, "the tab bar did not come back at the top of the page")

        press(.menu)
        if !waitUntilLeft() {
            XCTAssertTrue(tabBarHasFocus, "Menu at the top neither left the app nor moved the focus to the tab bar")
            press(.menu)
            XCTAssertTrue(waitUntilLeft(), "Menu on the tab bar must go to the Home screen")
        }
    }

    // MARK: - The tab bar

    /// From Home the tab bar reaches every other tab, and comes back.
    func testTheTabBarReachesEveryOtherTab() throws {
        launch()
        XCTAssertTrue(element("Home.Hero").waitForExistence(timeout: 20), "the billboard never showed")
        pause(2)
        for _ in 0..<3 where !tabBarHasFocus {
            press(.up)
            pause(0.8)
        }
        XCTAssertTrue(tabBarHasFocus, "the tab bar never got the focus")
        for tab in ["movies", "shows", "watchlist", "search", "downloads", "settings"] {
            press(.right)
            pause(1.2)
            XCTAssertEqual(selectedTab, tab, "Right did not select the \(tab) tab")
        }
        for tab in ["downloads", "search", "watchlist", "shows", "movies", "home"] {
            press(.left)
            pause(1.2)
            XCTAssertEqual(selectedTab, tab, "Left did not select the \(tab) tab")
        }
        XCTAssertTrue(element("Home.Hero").exists, "Home is not back")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - Helpers

    private func launch(_ arguments: [String] = []) {
        let app = XCUIApplication()
        // The tests read English labels. `PT_UITEST_HOME_FRENCH=1` runs the
        // app in French instead, for screenshots (`PT_UITEST_SHOTS`) of what
        // only the remote can show (a card's menu): the tests that read a
        // label then fail after their screenshots are saved.
        let french = ProcessInfo.processInfo.environment["PT_UITEST_HOME_FRENCH"]?.isEmpty == false
        app.launchArguments = [
            "-tosAccepted", "YES",
            "-lastWhatsNewVersion", "99",
            "-themeSongVolume", "0",
            "-AppleLanguages", french ? "(fr)" : "(en)",
            "-AppleLocale", french ? "fr_FR" : "en_US",
            "-PTDebugLibraryInMemory", "YES",
            "-PTDebugHomeFixtures", Self.fixtures,
            "-PTDebugHomeDryRunPlay", "YES",
            // The hero stays on its first item: a page turned by itself in
            // the middle of a test would change what it reads.
            "-PTDebugHomeHero", "0",
        ] + arguments
        // `PT_UITEST_HOME_TRACE=<folder>`: the page's focus trace of each launch.
        if let folder = ProcessInfo.processInfo.environment["PT_UITEST_HOME_TRACE"], !folder.isEmpty {
            let test = name.components(separatedBy: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "]")) ?? "test"
            app.launchArguments += ["-PTDebugHomeTrace", "\(folder)/\(test).txt"]
        }
        app.launch()
        self.app = app
    }

    /// The billboard is up; the focus goes from the tab bar to Play.
    private func focusPlay() throws {
        XCTAssertTrue(element("Home.Play").waitForExistence(timeout: 20), "the billboard never showed")
        pause(2)
        for _ in 0..<3 where focusedIdentifier != "Home.Play" {
            press(.down)
            pause(1)
        }
        XCTAssertEqual(focusedIdentifier, "Home.Play", "Play never got the focus: \(focusedLabel)")
    }

    private func press(_ button: XCUIRemote.Button) {
        snap("before-\(Self.name(button))")
        remoteControl.press(button)
    }

    private static func name(_ button: XCUIRemote.Button) -> String {
        switch button {
        case .up: return "up"
        case .down: return "down"
        case .left: return "left"
        case .right: return "right"
        case .select: return "select"
        case .menu: return "menu"
        case .playPause: return "playpause"
        default: return "other"
        }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func labelled(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
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
        return focused.exists ? "\(focused.identifier) \(focused.label)" : "none"
    }

    /// The focused card of a shelf, nil when the focus is elsewhere.
    private func focusedCard(in shelf: String) -> XCUIElement? {
        let card = element("Home.Section.\(shelf)").buttons.matching(Self.focused).firstMatch
        return card.exists && card.identifier.hasPrefix("Home.Card.") ? card : nil
    }

    /// The title a card names first ("Title, 2026, IMDb 7.8, New").
    private func title(of card: XCUIElement) -> String {
        return card.label.components(separatedBy: ", ").first ?? card.label
    }

    private var tabBarHasFocus: Bool {
        app.tabBars.descendants(matching: .any).matching(Self.focused).firstMatch.exists
    }

    /// The tabs are on the screen (the bar goes off its top when the page scrolls down).
    private var tabBarIsOnScreen: Bool {
        let screen = app.windows.firstMatch.frame
        let tabs = app.tabBars.buttons.allElementsBoundByIndex.map(\.frame).filter { !$0.isEmpty }
        return !tabs.isEmpty && tabs.allSatisfy { screen.contains($0) }
    }

    /// The selected tab's name ("home", "movies"…): the tab bar's identifier says it.
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

    private func waitUntilLeft(timeout: TimeInterval = 8) -> Bool {
        if app.wait(for: .runningBackground, timeout: timeout) { return true }
        return [.runningBackgroundSuspended, .notRunning].contains(app.state)
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func snap(_ step: String) {
        guard let folder = ProcessInfo.processInfo.environment["PT_UITEST_SHOTS"], !folder.isEmpty, app != nil else { return }
        let test = name.components(separatedBy: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "]")) ?? "test"
        shotIndex += 1
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(test)/\(String(format: "%02d", shotIndex))-\(step).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
