import XCTest

/// The Continue Watching row at the top of the Movies and Shows grids.
///
/// - An episode in progress shows its card on the Shows tab. (5.0.0 to 5.2.0
///   crashed there 0.25 s after the tab appeared: the row converted the
///   episode's id — "tt…-s1e2" — with `Int(id)!`.)
/// - Holding Select on a card opens its menu; Menu closes it, "Remove from
///   on deck" takes the card out of the row.
///
/// Runs like `NavigationUITests`: the tvOS 26.5 simulator, a DEBUG build of
/// the app (`SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`). The watch state is
/// given as launch arguments and kept in memory (`-PTDebugLibraryInMemory`):
/// nothing is written to the app's defaults. The titles are IMDb ids that do
/// not exist, so nothing can ever be played: Select on a card would end on
/// the "could not load" page, and the tests never press it there.
final class ContinueWatchingUITests: XCTestCase {

    private let remote = XCUIRemote.shared
    private var app: XCUIApplication!

    private static let focused = NSPredicate(format: "hasFocus == true")

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    func testAnEpisodeInProgressShowsItsCardOnTheShowsTab() {
        launch(tab: "shows", ["-episodesProgress", #"{ "tt9999999999-s1e2" = "0.42"; }"#])
        let card = row.cells["ContinueWatching.Card.tt9999999999"]
        XCTAssertTrue(card.waitForExistence(timeout: 30), "the episode in progress has no card on the Shows tab")
        XCTAssertEqual(card.label, "S1 · E2", "the card names the episode")
        snap("shows-row")
        XCTAssertEqual(row.cells.count, 1, "one card")
        // The crash came a quarter of a second after the grid.
        pause(4)
        XCTAssertEqual(app.state, .runningForeground, "the app left the Shows tab")
        XCTAssertTrue(card.exists, "the card is gone")
    }

    func testHoldingSelectOnACardRemovesItFromTheRow() {
        launch(tab: "movies", ["-moviesProgress", #"{ tt9999999998 = "0.30"; tt9999999999 = "0.42"; }"#])
        XCTAssertTrue(row.cells.firstMatch.waitForExistence(timeout: 30), "no Continue Watching row on the Movies tab")
        XCTAssertEqual(row.cells.count, 2, "two movies in progress, two cards")

        // Down from the tab bar until a card has the focus.
        var card = row.cells.matching(Self.focused).firstMatch
        for _ in 0..<6 where !card.exists {
            remote.press(.down)
            pause(1)
            card = row.cells.matching(Self.focused).firstMatch
        }
        XCTAssertTrue(card.exists, "no card ever got the focus")
        let removed = card.identifier
        let kept = removed.hasSuffix("tt9999999999") ? "ContinueWatching.Card.tt9999999998" : "ContinueWatching.Card.tt9999999999"

        // Hold Select: the card's menu. Menu closes it and nothing changes.
        let remove = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Remove from on deck")).firstMatch
        remote.press(.select, forDuration: 1.6)
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "holding Select on a card did not open its menu")
        snap("card-menu")
        remote.press(.menu)
        pause(1.5)
        XCTAssertFalse(remove.exists, "Menu did not close the card's menu")
        XCTAssertEqual(row.cells.count, 2, "closing the menu removed a card")
        XCTAssertEqual(row.cells.matching(Self.focused).firstMatch.identifier, removed, "the focus is not back on the card")

        // Hold Select again, and choose Remove (the menu's only action).
        remote.press(.select, forDuration: 1.6)
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "the card's menu did not open the second time")
        pause(0.5)
        remote.press(.select)
        pause(2)

        XCTAssertFalse(remove.exists, "the menu stayed")
        XCTAssertFalse(row.cells[removed].exists, "the card is still in the row")
        XCTAssertTrue(row.cells[kept].exists, "the other card left too")
        XCTAssertEqual(row.cells.count, 1, "one card left")
        snap("card-removed")
        XCTAssertEqual(app.state, .runningForeground, "the app is not in front any more")
    }

    // MARK: - Helpers

    private var row: XCUIElement { app.collectionViews["ContinueWatching.Row"] }

    /// `tab`: a tab's name, never its place in the bar (Home is the first
    /// one), like `NavigationUITests`; Home's hub is fed from recorded
    /// answers, as there.
    private func launch(tab: String, _ arguments: [String]) {
        let app = XCUIApplication()
        let fixtures = ProcessInfo.processInfo.environment["PT_UITEST_HOME_FIXTURES"].flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("PopcornTimeTests/Fixtures/Home").path
        app.launchArguments = [
            "-PTDebugHomeFixtures", fixtures,
            "-tosAccepted", "YES",
            "-lastWhatsNewVersion", "99",
            "-themeSongVolume", "0",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-PTDebugLibraryInMemory", "YES",
            "-PTDebugTab", tab,
        ] + arguments
        app.launch()
        self.app = app
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Saves a screenshot when `PT_UITEST_SHOTS=<folder>` is set for the
    /// test runner (`TEST_RUNNER_PT_UITEST_SHOTS` on the xcodebuild command
    /// line), like `NavigationUITests`.
    private func snap(_ step: String) {
        guard let folder = ProcessInfo.processInfo.environment["PT_UITEST_SHOTS"], !folder.isEmpty else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("continue-watching-\(step).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
