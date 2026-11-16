import XCTest

/// The episode card of episode chaining (5.3.0) on the Apple TV: its three
/// buttons, where the focus goes, what Menu does.
///
/// The card is the app's own (`UpNextOverlayViewController`, the content
/// AVKit's proposal shows too: `UpNextCardContentView`), put over a black
/// stand-in for the player by the DEBUG fixture `-PTDebugUpNextCard`: no
/// stream, no session, nothing can play. The fixture's buttons only write
/// what they did into a label, `UpNext.Fixture.Log` (« accept », « cancel »,
/// « choose », « deadline » when its countdown ran out — 60 s, the setting's
/// default: the tests end well before). « Play Now » counts one second after
/// the card appeared (`UpNextPressGuard`: a press meant for the player as the
/// card slid in started the next episode on the device). Runs like `NavigationUITests`: tvOS 26.5 simulator, DEBUG
/// build of the app.
final class UpNextUITests: XCTestCase {

    private let remote = XCUIRemote.shared
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    /// The countdown card: three buttons, the focus on « Play Now », Down
    /// to « Back to the Video » then « Choose Version », Select answers.
    func testTheCountdownCardOffersThreeButtonsWithTheFocusOnPlayNow() {
        launch("countdown")
        XCTAssertTrue(playNow.waitForExistence(timeout: 30), "no card")
        XCTAssertEqual(playNow.label, "Play Now")
        XCTAssertEqual(back.label, "Back to the Video")
        XCTAssertEqual(choose.label, "Choose Version")
        XCTAssertTrue(app.staticTexts["UpNext.VersionLine"].exists, "no version line")
        XCTAssertEqual(app.staticTexts["UpNext.VersionLine"].label, "1080p HEVC · same pack")
        XCTAssertTrue(app.staticTexts["UpNext.Countdown"].label.hasPrefix("Plays automatically in"), "no countdown")
        XCTAssertTrue(waitForFocus(on: playNow), "« Play Now » does not have the focus")
        snap("countdown")

        remote.press(.down)
        XCTAssertTrue(waitForFocus(on: back), "Down did not move the focus to « Back to the Video »")
        remote.press(.down)
        XCTAssertTrue(waitForFocus(on: choose), "Down did not move the focus to « Choose Version »")
        snap("countdown-choose-focused")
        remote.press(.select)
        XCTAssertTrue(waitForLog("choose"), "Select on « Choose Version » did not answer « choose »: \(log.label)")
    }

    func testSelectOnPlayNowAccepts() {
        launch("countdown")
        XCTAssertTrue(playNow.waitForExistence(timeout: 30), "no card")
        XCTAssertTrue(waitForFocus(on: playNow), "« Play Now » does not have the focus")
        // Past the card's first second on screen.
        pause(1.5)
        remote.press(.select)
        XCTAssertTrue(waitForLog("accept"), "Select on « Play Now » did not accept: \(log.label)")
    }

    /// A Select as the card appears (the viewer was pressing for the player)
    /// is not « Play Now »; one past the guard is. A runner's press takes
    /// about a second to arrive: the guard is stretched to 6 s here
    /// (`-PTDebugUpNextPressGuard`), the rule is the same.
    func testASelectAsTheCardAppearsIsIgnored() {
        launch("countdown", extra: ["-PTDebugUpNextPressGuard", "6"])
        XCTAssertTrue(playNow.waitForExistence(timeout: 30), "no card")
        let shown = Date()
        remote.press(.select)
        pause(1)
        XCTAssertLessThan(Date().timeIntervalSince(shown), 5, "the press came too late to test the guard")
        XCTAssertEqual(log.label, "-", "a press within the guard answered the card")
        pause(max(0, 7 - Date().timeIntervalSince(shown)))
        XCTAssertEqual(log.label, "-", "the ignored press answered later")
        XCTAssertTrue(waitForFocus(on: playNow), "« Play Now » does not have the focus")
        remote.press(.select)
        XCTAssertTrue(waitForLog("accept"), "Select past the guard did not accept: \(log.label)")
    }

    /// Menu on the card is « Back to the Video » (the player under it stays).
    func testMenuOnTheCardCancels() {
        launch("countdown")
        XCTAssertTrue(playNow.waitForExistence(timeout: 30), "no card")
        pause(1)
        remote.press(.menu)
        XCTAssertTrue(waitForLog("cancel"), "Menu did not cancel the card: \(log.label)")
        XCTAssertEqual(app.state, .runningForeground, "Menu left the app")
    }

    /// After the file (length unknown): « Episode finished », « Cancel ».
    func testTheAfterPlayCardSaysCancel() {
        launch("postPlay")
        XCTAssertTrue(playNow.waitForExistence(timeout: 30), "no card")
        XCTAssertTrue(app.staticTexts[Self.endedHeadline].exists, "no « \(Self.endedHeadline) » headline")
        XCTAssertEqual(back.label, "Cancel")
        XCTAssertTrue(choose.exists, "no « Choose Version »")
        XCTAssertTrue(waitForFocus(on: playNow), "« Play Now » does not have the focus")
        snap("post-play")
    }

    /// « Still watching? » (decision D6): « Keep Watching » / « Stop », no countdown.
    func testStillWatchingHasNoCountdown() {
        launch("stillWatching")
        XCTAssertTrue(playNow.waitForExistence(timeout: 30), "no card")
        XCTAssertEqual(playNow.label, "Keep Watching")
        XCTAssertEqual(back.label, "Stop")
        XCTAssertFalse(app.staticTexts["UpNext.Countdown"].exists, "« Still watching? » counts down")
        XCTAssertTrue(waitForFocus(on: playNow), "« Keep Watching » does not have the focus")
        snap("still-watching")
        remote.press(.down)
        XCTAssertTrue(waitForFocus(on: back), "Down did not move the focus to « Stop »")
        remote.press(.select)
        XCTAssertTrue(waitForLog("cancel"), "« Stop » did not answer: \(log.label)")
    }

    // MARK: - Helpers

    /// `UpNext.Ended` in English.
    private static let endedHeadline = "Episode finished"

    private var playNow: XCUIElement { app.buttons["UpNext.Button.PlayNow"] }
    private var back: XCUIElement { app.buttons["UpNext.Button.Back"] }
    private var choose: XCUIElement { app.buttons["UpNext.Button.ChooseVersion"] }
    private var log: XCUIElement { app.staticTexts["UpNext.Fixture.Log"] }

    private func launch(_ card: String, extra: [String] = []) {
        let app = XCUIApplication()
        app.launchArguments = [
            "-tosAccepted", "YES",
            "-lastWhatsNewVersion", "99",
            "-themeSongVolume", "0",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-PTDebugLibraryInMemory", "YES",
            "-PTDebugUpNextCard", card,
        ] + extra
        app.launch()
        self.app = app
    }

    private func waitForFocus(on element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForLog(_ answer: String, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", answer), object: log)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Saves a screenshot when `PT_UITEST_SHOTS=<folder>` is set for the
    /// test runner, like the other suites.
    private func snap(_ step: String) {
        guard let folder = ProcessInfo.processInfo.environment["PT_UITEST_SHOTS"], !folder.isEmpty else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("up-next-\(step).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
