//
//  TestSupport.swift
//  PopcornTimeTests
//
//  Shared helpers of the unit tests. Most test files are ports of the command-line
//  harnesses used during development (one `check` per line of output there): `check`,
//  `expect` and `eq` keep their call sites, each one is an XCTest assertion, and every
//  test class prints how many it made so a port can be compared with its harness.
//

import Foundation
import XCTest

enum Checks {
    /// Assertions made so far by `check`, `expect` and `eq` (tests run one at a time).
    static var total = 0
}

/// One assertion: `condition` must hold. `detail` is appended to the message on failure.
func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "",
           _ detail: @autoclosure () -> String = "", file: StaticString = #filePath, line: Int = #line) {
    Checks.total += 1
    guard !condition() else { return }
    let extra = detail()
    XCTFail(message() + (extra.isEmpty ? "" : " — \(extra)"), file: file, line: UInt(line))
}

/// Same as `check` (the playback harnesses' spelling).
func expect(_ condition: @autoclosure () -> Bool, _ label: @autoclosure () -> String,
            _ detail: @autoclosure () -> String = "", file: StaticString = #filePath, line: Int = #line) {
    check(condition(), label(), detail(), file: file, line: line)
}

/// `a == b`, both shown on failure.
func eq<T: Equatable>(_ a: T, _ b: T, _ label: @autoclosure () -> String, file: StaticString = #filePath, line: Int = #line) {
    check(a == b, label(), "got \(a), expected \(b)", file: file, line: line)
}

/// The bundle's principal class (NSPrincipalClass), made before any test runs: the tests
/// compare English texts and en_US numbers whatever the Mac's language. (xcodebuild also
/// sets the language from the scheme; this covers `xctest` run directly, see tools/run-tests.sh.)
@objc(PopcornTimeTestsPrincipal)
final class TestsPrincipal: NSObject {
    override init() {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleLanguages"] = ["en"]
        arguments["AppleLocale"] = "en_US"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        super.init()
    }
}

/// Base class: prints the number of checks of each test class.
class CheckedTestCase: XCTestCase {
    private static var startCounts: [String: Int] = [:]

    override class func setUp() {
        super.setUp()
        startCounts[String(describing: self)] = Checks.total
    }

    override class func tearDown() {
        let made = Checks.total - (startCounts[String(describing: self)] ?? Checks.total)
        print("\(String(describing: self)): \(made) checks")
        super.tearDown()
    }
}

/// Recorded API answers and test media, in the bundle's Fixtures folder.
enum Fixtures {
    static let root: URL = {
        guard let resources = Bundle(for: CheckedTestCase.self).resourceURL else {
            fatalError("PopcornTimeTests: no resource folder")
        }
        return resources.appendingPathComponent("Fixtures", isDirectory: true)
    }()

    static func url(_ path: String) -> URL {
        return root.appendingPathComponent(path)
    }

    static func data(_ path: String, file: StaticString = #filePath, line: UInt = #line) -> Data {
        guard let data = try? Data(contentsOf: url(path)) else {
            XCTFail("missing fixture \(path)", file: file, line: line)
            return Data()
        }
        return data
    }
}
