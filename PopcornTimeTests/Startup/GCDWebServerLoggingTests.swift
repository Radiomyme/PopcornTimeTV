//
//  GCDWebServerLoggingTests.swift
//  PopcornTimeTests
//
//  Which GCDWebServer console lines are a client hanging up (a player closing its
//  connection: not logged as errors) and which are an expected retry of the listen
//  socket. (Port of the console-noise harness: 14 cases, 2 checks each.)
//

import XCTest
import Foundation

final class GCDWebServerLoggingTests: CheckedTestCase {

    func testClientDisconnectsAndExpectedRetries() {
        let cases: [(String, Bool, Bool)] = [   // message, disconnect, expected retry
            ("Error while writing to socket 25: Broken pipe (32)", true, false),
            ("Error while writing to socket 7: Connection reset by peer (54)", true, false),
            ("Error while reading from socket 9: Connection reset by peer (54)", true, false),
            ("Error while writing to socket 9: Socket is not connected (57)", true, false),
            ("No more data available on socket 12", true, false),
            ("No data received from socket 12", true, false),
            ("Failed reading response body for socket 29: Error Domain=com.popcorntimetv.popcorntorrent.http Code=2 \"(null)\"", true, false),
            ("Failed reading response body for socket 29: Error Domain=com.popcorntimetv.popcorntorrent.http Code=3 \"(null)\"", false, false),
            ("Error while writing to socket 25: Bad file descriptor (9)", false, false),
            ("Failed binding IPv4 listening socket: Address already in use (48)", false, true),
            ("Failed binding IPv6 listening socket: Address already in use (48)", false, true),
            ("Failed binding IPv4 listening socket: Permission denied (13)", false, false),
            ("Failed reading response body for socket 30: Error Domain=x Code=1 (null)", false, false),
            ("Failed opening response body for socket 30: (null)", false, false),
        ]
        for (message, disconnect, retry) in cases {
            check(GCDWebServerLogging.isClientDisconnect(message) == disconnect, "client disconnect: \(message)")
            check(GCDWebServerLogging.isExpectedRetry(message) == retry, "expected retry: \(message)")
        }
    }
}
