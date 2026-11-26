import XCTest

/// Profiles on the Apple TV: « Who's Watching? » at launch when the device
/// has more than one profile, a pick opening the Home of that profile, and
/// Settings › Switch Profile changing it — each profile with its own
/// Continue Watching.
///
/// Runs like `HomeUITests`: a DEBUG build, the Home fed from recorded
/// answers (`-PTDebugHomeFixtures`), the library and the profiles in memory
/// (`-PTDebugLibraryInMemory`; `-PTDebugProfiles Alex` adds a second
/// profile to the primary one, « Me »). `-PTDebugHomeResume` puts a movie
/// in progress into the profile picked first. `PT_UITEST_SHOTS=<folder>`
/// saves screenshots of the steps.
final class ProfilesUITests: XCTestCase {

    private let remote = XCUIRemote.shared
    private var app: XCUIApplication!
    private static let focused = NSPredicate(format: "hasFocus == true")
    private static let resume = "tt0816692|Interstellar|0.42|169"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    /// One profile (every device until a second is made): no picker, the Home at once.
    func testOneProfileOpensTheHomeAtOnce() throws {
        launch([])
        XCTAssertTrue(element("Home.Hero").waitForExistence(timeout: 30), "the Home never showed")
        XCTAssertFalse(element("Profiles.Title").exists, "« Who's Watching? » with a single profile")
    }

    /// Two profiles: the picker first; « Me » gets the movie in progress;
    /// Settings › Switch Profile › Alex shows a Home without it; back to
    /// « Me », it is there again.
    func testThePickerAndSwitchingKeepEachProfilesContinueWatching() throws {
        launch(["-PTDebugProfiles", "Alex", "-PTDebugHomeResume", Self.resume])
        XCTAssertTrue(element("Profiles.Title").waitForExistence(timeout: 20), "« Who's Watching? » never showed")
        XCTAssertTrue(element("Profiles.Profile.Me").exists && element("Profiles.Profile.Alex").exists, "the two profiles are not offered")
        XCTAssertFalse(element("Profiles.Cancel").exists, "the launch picker can be dismissed without a pick")
        pause(1.5)
        snap("1-who-is-watching")
        XCTAssertEqual(focusedIdentifier, "Profiles.Profile.Me", "the focus does not start on the first profile")

        // « Me »: the movie in progress.
        remote.press(.select)
        XCTAssertTrue(element("Home.Section.continueWatching").waitForExistence(timeout: 30), "Me's Home has no Continue Watching")
        snap("2-me-home")

        // Settings › Switch Profile › Alex.
        try switchProfile(to: "Alex", moves: 1)
        XCTAssertTrue(element("Home.Hero").waitForExistence(timeout: 30), "Alex's Home never showed")
        pause(3)
        snap("4-alex-home")
        XCTAssertFalse(element("Home.Section.continueWatching").exists, "Alex sees Me's Continue Watching")

        // Back to « Me ».
        try switchProfile(to: "Me", moves: 0)
        XCTAssertTrue(element("Home.Section.continueWatching").waitForExistence(timeout: 30), "Me's Continue Watching is gone")
        snap("5-me-again")
    }

    // MARK: - Helpers

    /// From the Home: the tab bar, Settings, « Switch Profile », then `moves`
    /// to the right in the picker and a press.
    private func switchProfile(to name: String, moves: Int) throws {
        pause(2)
        for _ in 0..<4 where !tabBarHasFocus {
            remote.press(.up)
            pause(0.8)
        }
        XCTAssertTrue(tabBarHasFocus, "the tab bar never got the focus: \(focusedIdentifier)")
        for _ in 0..<8 where selectedTab != "settings" {
            remote.press(.right)
            pause(1)
        }
        XCTAssertEqual(selectedTab, "settings", "Settings never got selected")
        let row = element("Settings.Row.switchProfile")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Settings has no « Switch Profile » row")
        remote.press(.down)
        pause(1)
        // The row is the right column's first: up from any other row of it.
        for _ in 0..<8 where focusedIdentifier != "Settings.Row.switchProfile" {
            remote.press(focusedIsInRightColumn ? .up : .right)
            pause(0.8)
        }
        XCTAssertEqual(focusedIdentifier, "Settings.Row.switchProfile", "« Switch Profile » never got the focus")
        snap("3-settings-\(name)")
        remote.press(.select)
        XCTAssertTrue(element("Profiles.Cancel").waitForExistence(timeout: 10), "the picker from Settings never showed (or has no Cancel)")
        pause(1.5)
        for _ in 0..<moves {
            remote.press(.right)
            pause(0.8)
        }
        XCTAssertEqual(focusedIdentifier, "Profiles.Profile.\(name)", "the focus is not on \(name)")
        remote.press(.select)
        XCTAssertTrue(element("Profiles.Title").waitForNonExistence(timeout: 10), "the picker stayed")
    }

    private var focusedIsInRightColumn: Bool {
        let focused = focusedElement
        return focused.exists && focused.frame.minX > app.windows.firstMatch.frame.midX
    }

    private func launch(_ arguments: [String]) {
        let app = XCUIApplication()
        app.launchArguments = [
            "-tosAccepted", "YES",
            "-lastWhatsNewVersion", "99",
            "-themeSongVolume", "0",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-PTDebugLibraryInMemory", "YES",
            "-PTDebugHomeFixtures", Self.fixtures,
            "-PTDebugHomeDryRunPlay", "YES",
            "-PTDebugHomeHero", "0",
            "-PTDebugSettingsRow", "switchProfile",
        ] + arguments
        app.launch()
        self.app = app
    }

    private static var fixtures: String {
        if let folder = ProcessInfo.processInfo.environment["PT_UITEST_HOME_FIXTURES"], !folder.isEmpty { return folder }
        return URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PopcornTimeTests/Fixtures/Home").path
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private var focusedElement: XCUIElement {
        app.descendants(matching: .any).matching(Self.focused).firstMatch
    }

    private var focusedIdentifier: String {
        let focused = focusedElement
        return focused.exists ? focused.identifier : "none"
    }

    private var tabBarHasFocus: Bool {
        app.tabBars.descendants(matching: .any).matching(Self.focused).firstMatch.exists
    }

    private var selectedTab: String {
        let bar = app.tabBars.firstMatch
        guard bar.exists else { return "none" }
        let identifier = bar.identifier
        return identifier.hasPrefix("TabBar.") ? String(identifier.dropFirst("TabBar.".count)) : "none (\(identifier))"
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func snap(_ step: String) {
        guard let folder = ProcessInfo.processInfo.environment["PT_UITEST_SHOTS"], !folder.isEmpty else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("profiles-\(step).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
