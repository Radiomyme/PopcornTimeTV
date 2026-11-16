import XCTest

/// Not a check: plays a script of Siri Remote presses (`XCUIRemote`) on the
/// app launched with a test rig's own arguments (the loopback rig of the
/// native resume: `-PTDebugPlayTorrent <.torrent> -PTDebugLoopbackPort
/// <port>`, a private trackerless torrent seeded on 127.0.0.1), so that the
/// moves of a real remote on AVKit's transport bar (a pause, a scrub then a
/// click, ±10 s skips, a held skip) can be replayed and timed against the
/// app's log. The test never plays a title by itself: it presses what the
/// script says, nothing else. The app is closed with the test.
///
/// Skipped unless `PT_REMOTE_SCRIPT` is set (`TEST_RUNNER_PT_REMOTE_SCRIPT`
/// on the xcodebuild command line), so the suite is unchanged by default.
/// Other variables: `PT_REMOTE_LAUNCH_ARGS` / `PT_REMOTE_LAUNCH_ENV` (the
/// app's arguments and environment, fields separated by U+001F, the
/// environment as KEY=VALUE), `PT_REMOTE_LOG` (the app's console log, a host
/// path the `waitlog` / `waitnew` steps read), `PT_REMOTE_SHOTS` (a host
/// folder the `shot` steps write into), `PT_REMOTE_BUNDLE` (default
/// `com.popcorntime.tvos`). The app's console: an app launched by XCUITest
/// prints nowhere, so a rig injects a stdout shim in its environment
/// (`DYLD_INSERT_LIBRARIES=<shim>`, `PT_STDOUT_FILE=<file>`; the shim is the
/// rig's, not the app's). An app launched by the rig itself (`simctl
/// launch`) is not seen by the runner on the tvOS 26.5 simulator (its state
/// reads « not running »), and the runner is then killed once the app plays.
///
/// The script: steps separated by `;` or new lines, blanks ignored.
///   launch              launch the app with PT_REMOTE_LAUNCH_ARGS / PT_REMOTE_LAUNCH_ENV
///   wait:<s>            sleep
///   waitlog:<text>      wait (up to 300 s) until the log holds <text> anywhere
///   waitnew:<text>      the same, in lines written after this step began
///   playPause | select | menu | up | down | left | right    one press;
///       `<button>*<n>` presses n times, `<button>*<n>/<s>` with <s> seconds between them
///   holdLeft:<s> | holdRight:<s> | holdSelect:<s>           a press held that long
///   shot:<name>         the screen into <PT_REMOTE_SHOTS>/<name>.png
///   texts               the app's visible texts (the transport bar's times) in the output
/// Every step prints `PT_REMOTE <wall clock> <step>` when it starts and
/// `PT_REMOTE <wall clock> done <step>` when it returns, on the rig's clock.
///
/// Run (tvOS simulator, the UI tests built with build-for-testing; the rig's
/// launcher sets all of this):
///   TEST_RUNNER_PT_REMOTE_SCRIPT='launch;waitlog:landed;wait:5;playPause;wait:3;left*30/0.3;select;wait:60'
///   TEST_RUNNER_PT_REMOTE_LAUNCH_ARGS=… TEST_RUNNER_PT_REMOTE_LAUNCH_ENV=…
///   TEST_RUNNER_PT_REMOTE_LOG=<console log> TEST_RUNNER_PT_REMOTE_SHOTS=<folder>
///   xcodebuild test-without-building -xctestrun <…xctestrun> -destination id=<simulator>
///     -only-testing:PopcornTimetvOSUITests/RemoteScriptUITests/testPlaysTheRemoteScript
final class RemoteScriptUITests: XCTestCase {

    private let remote = XCUIRemote.shared
    private let environment = ProcessInfo.processInfo.environment

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private func say(_ text: String) {
        print("PT_REMOTE \(Self.clock.string(from: Date())) \(text)")
    }

    func testPlaysTheRemoteScript() throws {
        guard let script = environment["PT_REMOTE_SCRIPT"], !script.isEmpty else {
            throw XCTSkip("PT_REMOTE_SCRIPT is not set")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: environment["PT_REMOTE_BUNDLE"] ?? "com.popcorntime.tvos")
        let steps = script.split(whereSeparator: { $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        say("ready — \(steps.count) step(s)")
        for step in steps {
            say(step)
            try play(step, app: app)
            say("done \(step)")
        }
    }

    private func play(_ step: String, app: XCUIApplication) throws {
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let verb = parts[0], argument = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "launch":
            // The rig's arguments and environment (`PT_REMOTE_LAUNCH_ARGS`, `PT_REMOTE_LAUNCH_ENV`: fields
            // separated by U+001F, the environment as KEY=VALUE).
            let separator: Character = "\u{1F}"
            app.launchArguments = (environment["PT_REMOTE_LAUNCH_ARGS"] ?? "").split(separator: separator).map(String.init)
            for pair in (environment["PT_REMOTE_LAUNCH_ENV"] ?? "").split(separator: separator) {
                let field = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if field.count == 2 { app.launchEnvironment[field[0]] = field[1] }
            }
            say("launch arguments: \(app.launchArguments.joined(separator: " "))")
            app.launch()
        case "wait":
            Thread.sleep(forTimeInterval: Double(argument) ?? 0)
        case "waitlog", "waitnew":
            let start = verb == "waitnew" ? logText().utf8.count : 0
            let deadline = Date().addingTimeInterval(300)
            while true {
                let text = logText()
                let fresh = text.utf8.count > start ? String(decoding: Array(text.utf8)[start...], as: UTF8.self) : ""
                if (verb == "waitlog" ? text : fresh).contains(argument) { break }
                guard Date() < deadline else { return XCTFail("the log never said \(argument)") }
                Thread.sleep(forTimeInterval: 0.2)
            }
        case "holdLeft", "holdRight", "holdSelect":
            let button: XCUIRemote.Button = verb == "holdLeft" ? .left : verb == "holdRight" ? .right : .select
            remote.press(button, forDuration: Double(argument) ?? 1)
        case "shot":
            let folder = environment["PT_REMOTE_SHOTS"] ?? NSTemporaryDirectory()
            let png = XCUIScreen.main.screenshot().pngRepresentation
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(argument).png"))
        case "texts":
            let labels = app.staticTexts.allElementsBoundByIndex.map { $0.label }.filter { !$0.isEmpty }
            say("texts: \(labels.joined(separator: " | "))")
        default:
            // <button>[*<n>[/<s>]]
            let press = verb.split(separator: "*", maxSplits: 1).map(String.init)
            guard let button = Self.buttons[press[0]] else { return XCTFail("unknown step: \(step)") }
            var count = 1, gap = 0.0
            if press.count > 1 {
                let repeatParts = press[1].split(separator: "/", maxSplits: 1).map(String.init)
                count = Int(repeatParts[0]) ?? 1
                if repeatParts.count > 1 { gap = Double(repeatParts[1]) ?? 0 }
            }
            for index in 0..<count {
                remote.press(button)
                if gap > 0, index < count - 1 { Thread.sleep(forTimeInterval: gap) }
            }
        }
    }

    private static let buttons: [String: XCUIRemote.Button] = [
        "playPause": .playPause, "select": .select, "menu": .menu,
        "up": .up, "down": .down, "left": .left, "right": .right,
    ]

    private func logText() -> String {
        guard let log = environment["PT_REMOTE_LOG"], let data = FileManager.default.contents(atPath: log) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
