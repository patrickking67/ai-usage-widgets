import Foundation
import os
import XCTest

/// The app defines `log` in Collector.swift, which pulls in the whole app.
/// The test bundle compiles only the parsing sources, so it brings its own.
let log = Logger(subsystem: "com.patrickking.tokenmeter.tests", category: "tests")

/// Reads files from `spec/fixtures`, the same fixtures the Windows and plugin
/// tests use. Nothing here touches the network, the Keychain or `~`.
enum Fixture {
    static let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // Tests
        .deletingLastPathComponent()      // macos
        .deletingLastPathComponent()      // apps
        .deletingLastPathComponent()      // repo root
        .appendingPathComponent("spec/fixtures", isDirectory: true)

    static func text(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let url = dir.appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            XCTFail("missing fixture \(name)", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func json(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let data = Data(try text(name, file: file, line: line).utf8)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
    }

    static func unix(_ iso: String) -> TimeInterval {
        ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970
    }
}
