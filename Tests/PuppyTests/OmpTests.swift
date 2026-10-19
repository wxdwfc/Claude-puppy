import XCTest
@testable import Puppy

final class OmpTests: XCTestCase {
    private let process = CodexProcess.Identity(pid: 321, startedSeconds: 1_700_000_000,
                                                startedMicros: 250_000)
    private let startedMilliseconds = 1_700_000_000_250.0

    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fixture(status: String = "idle") -> [String: Any] {
        ["schemaVersion": 1, "pid": process.pid, "processStartedAt": startedMilliseconds,
         "sessionId": "omp-session-1", "cwd": "/tmp/omp-project", "name": "My omp session",
         "status": status, "statusUpdatedAt": startedMilliseconds]
    }

    private func write(_ record: [String: Any], to directory: URL,
                       filename: String = "321.json") throws {
        try JSONSerialization.data(withJSONObject: record)
            .write(to: directory.appendingPathComponent(filename), options: .atomic)
    }

    private func scan(_ directory: URL) -> [SessionInfo] {
        OmpSessionReader.scan(directory: directory, identity: { _ in self.process })
    }

    private func row(_ info: SessionInfo, now: Date) -> SessionRow {
        SessionRow(info: info, completedAt: info.completedAt(now: now, within: 60))
    }

    func testStartupMapsRegistryFieldsWithoutCompletion() throws {
        let directory = try temp()
        try write(fixture(), to: directory)
        let info = try XCTUnwrap(scan(directory).first)
        let now = Date(timeIntervalSince1970: startedMilliseconds / 1000 + 1)
        XCTAssertEqual(info.provider, .omp)
        XCTAssertEqual(info.status, .idle)
        XCTAssertNil(info.explicitCompletedAt)
        XCTAssertNil(info.completionSummary)
        XCTAssertNil(info.completedAt(now: now, within: 60))
        let startup = row(info, now: now)
        XCTAssertEqual(startup.display, .idle)
        XCTAssertNil(BubbleItem(row: startup, now: now))
        XCTAssertEqual(MascotState.derive(rows: [startup], celebrating: false), .sleeping)

        var unnamed = fixture()
        unnamed.removeValue(forKey: "name")
        try write(unnamed, to: directory)
        XCTAssertEqual(try XCTUnwrap(scan(directory).first).displayName, "omp-project")
    }

    func testFastSuccessShowsBubbleWithoutObservedBusyAndExpires() throws {
        let directory = try temp()
        let completedMilliseconds = startedMilliseconds + 100
        var completed = fixture()
        completed["statusUpdatedAt"] = completedMilliseconds
        completed["completedAt"] = completedMilliseconds
        completed["summary"] = "Implemented the fix"
        try write(completed, to: directory)
        let info = try XCTUnwrap(scan(directory).first)
        let at = Date(timeIntervalSince1970: completedMilliseconds / 1000)
        let now = at.addingTimeInterval(1)
        XCTAssertEqual(info.explicitCompletedAt, at)
        XCTAssertEqual(info.completionSummary, "Implemented the fix")
        XCTAssertEqual(info.completedAt(now: at, within: 60), at)
        XCTAssertNil(info.completedAt(now: at.addingTimeInterval(-0.01), within: 60))
        let completedRow = row(info, now: now)
        XCTAssertEqual(completedRow.display, .completed)
        let bubble = try XCTUnwrap(BubbleItem(row: completedRow, now: now))
        XCTAssertEqual(bubble.kind, .done)
        XCTAssertEqual(bubble.pid, process.pid)
        XCTAssertEqual(bubble.name, "\(info.provider.label) · My omp session")
        XCTAssertEqual(MascotState.derive(rows: [completedRow], celebrating: true), .celebrating)

        let expiredNow = at.addingTimeInterval(60)
        let expiredRow = row(info, now: expiredNow)
        XCTAssertNil(expiredRow.completedAt)
        XCTAssertEqual(expiredRow.display, .idle)
        XCTAssertNil(BubbleItem(row: expiredRow, now: expiredNow))
        XCTAssertEqual(MascotState.derive(rows: [expiredRow], celebrating: false), .sleeping)
    }

    func testBusyInterruptionAndErrorsNeverCompleteEvenWithStaleCompletion() throws {
        let directory = try temp()
        let now = Date(timeIntervalSince1970: startedMilliseconds / 1000 + 1)
        let statuses: [(String, SessionStatus, DisplayState, MascotState)] = [
            ("busy", .busy, .busy, .working),
            ("interrupted", .other("已中断"), .other("已中断"), .sleeping),
            ("error", .other("出错"), .other("出错"), .sleeping)
        ]
        for (status, expectedStatus, display, mascot) in statuses {
            var record = fixture(status: status)
            record["statusUpdatedAt"] = startedMilliseconds + 100
            record["completedAt"] = startedMilliseconds + 100
            record["summary"] = "Stale success"
            try write(record, to: directory)
            let info = try XCTUnwrap(scan(directory).first)
            XCTAssertEqual(info.status, expectedStatus)
            XCTAssertNil(info.explicitCompletedAt, status)
            XCTAssertNil(info.completionSummary, status)
            let current = row(info, now: now)
            XCTAssertNil(current.completedAt, status)
            XCTAssertEqual(current.display, display)
            XCTAssertNil(BubbleItem(row: current, now: now), status)
            XCTAssertEqual(MascotState.derive(rows: [current], celebrating: false), mascot)
        }
    }

    func testReaderRejectsDeadReusedAndMismatchedProcessIdentities() throws {
        let directory = try temp()
        try write(fixture(), to: directory)
        XCTAssertEqual(scan(directory).count, 1)
        XCTAssertTrue(OmpSessionReader.scan(directory: directory, identity: { _ in nil }).isEmpty)
        for identity in [
            CodexProcess.Identity(pid: process.pid, startedSeconds: process.startedSeconds + 3,
                                  startedMicros: process.startedMicros),
            CodexProcess.Identity(pid: process.pid, startedSeconds: process.startedSeconds - 3,
                                  startedMicros: process.startedMicros),
            CodexProcess.Identity(pid: process.pid + 1, startedSeconds: process.startedSeconds,
                                  startedMicros: process.startedMicros)
        ] {
            XCTAssertTrue(OmpSessionReader.scan(directory: directory, identity: { _ in identity }).isEmpty)
        }
    }

    func testProcessGenerationToleranceIncludesKernelMicroseconds() throws {
        let directory = try temp()
        for offset in [-2000.0, 2000.0] {
            var record = fixture()
            record["processStartedAt"] = startedMilliseconds + offset
            try write(record, to: directory)
            XCTAssertEqual(scan(directory).count, 1, "offset \(offset)")
        }
        for offset in [-2001.0, 2001.0] {
            var record = fixture()
            record["processStartedAt"] = startedMilliseconds + offset
            record["statusUpdatedAt"] = startedMilliseconds + 3000
            try write(record, to: directory)
            XCTAssertTrue(scan(directory).isEmpty, "offset \(offset)")
        }
    }

    func testMalformedSchemaAndTimestampsAreIgnored() throws {
        let directory = try temp()
        let invalidValues: [(String, Any)] = [
            ("schemaVersion", 2), ("schemaVersion", "1"),
            ("pid", 0), ("pid", -1), ("pid", Int64(Int32.max) + 1), ("pid", 321.5),
            ("sessionId", 123), ("cwd", NSNull()), ("name", 123), ("summary", 123),
            ("status", "waiting"), ("status", "unknown"),
            ("processStartedAt", 0), ("processStartedAt", -1), ("processStartedAt", 1e300),
            ("statusUpdatedAt", 0), ("statusUpdatedAt", -1), ("statusUpdatedAt", 1e300),
            ("statusUpdatedAt", startedMilliseconds - 2001),
            ("statusUpdatedAt", Date().timeIntervalSince1970 * 1000 + 60_000),
            ("completedAt", 0), ("completedAt", -1), ("completedAt", 1e300),
            ("completedAt", startedMilliseconds - 2001),
            ("completedAt", startedMilliseconds + 1)
        ]
        for (key, value) in invalidValues {
            var record = fixture()
            record[key] = value
            try write(record, to: directory)
            XCTAssertTrue(scan(directory).isEmpty, "\(key): \(value)")
        }
        for key in ["schemaVersion", "pid", "processStartedAt", "sessionId", "cwd", "status", "statusUpdatedAt"] {
            var record = fixture()
            record.removeValue(forKey: key)
            try write(record, to: directory)
            XCTAssertTrue(scan(directory).isEmpty, "missing \(key)")
        }
        for json in ["{", "[]", "null", "{\"statusUpdatedAt\":NaN}", "{\"statusUpdatedAt\":Infinity}"] {
            try Data(json.utf8).write(to: directory.appendingPathComponent("321.json"))
            XCTAssertTrue(scan(directory).isEmpty, json)
        }
    }

    func testReaderIgnoresMismatchedFilenamesAndUnpublishedTemporaryFiles() throws {
        let directory = try temp()
        for filename in ["322.json", "0321.json", "321.tmp", ".321.json", "321.json.tmp"] {
            try write(fixture(), to: directory, filename: filename)
        }
        XCTAssertTrue(scan(directory).isEmpty)
        try write(fixture(), to: directory)
        XCTAssertEqual(scan(directory).count, 1)
        XCTAssertTrue(scan(directory.appendingPathComponent("missing")).isEmpty)
    }

    func testDefaultIdentityReadsCurrentProcessGeneration() throws {
        let directory = try temp()
        let live = try XCTUnwrap(CodexProcess.identity(getpid()))
        var record = fixture()
        record["pid"] = live.pid
        record["processStartedAt"] = Double(live.startedSeconds) * 1000 + Double(live.startedMicros) / 1000
        record["statusUpdatedAt"] = Date().timeIntervalSince1970 * 1000
        try write(record, to: directory, filename: "\(live.pid).json")
        let info = try XCTUnwrap(OmpSessionReader.scan(directory: directory).first)
        XCTAssertEqual(info.pid, live.pid)
        XCTAssertEqual(info.provider, .omp)
        XCTAssertNil(info.explicitCompletedAt)
    }
}
