import XCTest
@testable import Puppy

final class CodexTests: XCTestCase {
    let process = CodexProcess.Identity(pid: 123, startedSeconds: 100, startedMicros: 42)
    let now = Date(timeIntervalSince1970: 1000)

    func event(_ name: String, turn: String = "turn-1", tool: String = "Bash",
               input: [String: Any] = ["command": "echo hello"]) -> [String: Any] {
        ["hook_event_name": name, "session_id": "session-1", "cwd": "/tmp/project",
         "turn_id": turn, "tool_name": tool, "tool_input": input]
    }

    func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func read(_ directory: URL) throws -> CodexSessionRecord {
        try JSONDecoder().decode(CodexSessionRecord.self,
            from: Data(contentsOf: directory.appendingPathComponent("123.json")))
    }

    func testLifecycleAndFastCompletion() throws {
        let directory = try temp()
        try CodexHook.write(event("SessionStart"), process: process, directory: directory, now: now)
        XCTAssertNil(try read(directory).info.completedAt(now: now, within: 60))
        try CodexHook.write(event("UserPromptSubmit"), process: process, directory: directory, now: now)
        XCTAssertEqual(try read(directory).info.status, .busy)
        var stop = event("Stop")
        stop["last_assistant_message"] = "**测试全过**\n更多信息"
        try CodexHook.write(stop, process: process, directory: directory, now: now.addingTimeInterval(0.1))
        let record = try read(directory)
        XCTAssertEqual(record.summary, "测试全过")
        XCTAssertNotNil(record.info.completedAt(now: now.addingTimeInterval(1), within: 60))
        XCTAssertNil(record.info.completedAt(now: now.addingTimeInterval(61), within: 60))
        try CodexHook.write(event("SessionEnd"), process: process, directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("123.json").path))
        try CodexHook.write(stop, process: process, directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("123.json").path))
    }

    func testParallelToolsDoNotClearUnrelatedWait() {
        var record = CodexSessionRecord(process: process, sessionID: "session-1", cwd: "/tmp", statusAt: now)
        CodexHook.apply(event("UserPromptSubmit"), to: &record, now: now)
        CodexHook.apply(event("PermissionRequest"), to: &record, now: now)
        CodexHook.apply(event("PostToolUse", input: ["command": "other"]), to: &record, now: now)
        XCTAssertEqual(record.status, "waiting")
        CodexHook.apply(event("PreToolUse", tool: "request_user_input", input: [:]), to: &record, now: now)
        CodexHook.apply(event("PostToolUse"), to: &record, now: now)
        XCTAssertEqual(record.status, "waiting")
        CodexHook.apply(event("PostToolUse", tool: "request_user_input", input: [:]), to: &record, now: now)
        XCTAssertEqual(record.status, "busy")
    }

    func testLateEventsAndInterruptionNeverCelebrate() {
        var record = CodexSessionRecord(process: process, sessionID: "session-1", cwd: "/tmp", statusAt: now)
        CodexHook.apply(event("UserPromptSubmit", turn: "turn-2"), to: &record, now: now)
        CodexHook.apply(event("Stop", turn: "turn-1"), to: &record, now: now)
        XCTAssertEqual(record.status, "busy")
        CodexHook.apply(event("PermissionRequest", turn: "child-turn"), to: &record, now: now)
        XCTAssertEqual(record.status, "busy")
        CodexHook.apply(event("SessionStart"), to: &record, now: now)
        XCTAssertEqual(record.status, "busy")
        CodexHook.apply(event("Interrupt", turn: "turn-2"), to: &record, now: now)
        CodexHook.apply(event("PostToolUse", turn: "turn-2"), to: &record, now: now)
        CodexHook.apply(event("Stop", turn: "turn-2"), to: &record, now: now)
        XCTAssertEqual(record.status, "interrupted")
        XCTAssertNil(record.info.completedAt(now: now, within: 60))
    }

    func testSessionSwitchAndPIDReuse() throws {
        let directory = try temp()
        try CodexHook.write(event("UserPromptSubmit"), process: process, directory: directory, now: now)
        var start = event("SessionStart")
        start["session_id"] = "session-2"
        try CodexHook.write(start, process: process, directory: directory, now: now)
        try CodexHook.write(event("SessionEnd"), process: process, directory: directory, now: now)
        XCTAssertEqual(try read(directory).sessionID, "session-2")
        let reused = CodexProcess.Identity(pid: 123, startedSeconds: 200, startedMicros: 42)
        try CodexHook.write(event("Stop"), process: reused, directory: directory, now: now)
        XCTAssertEqual(try read(directory).sessionID, "session-2")
    }

    func testInstallerPreservesOtherHooksAndIsIdempotent() throws {
        let command = "'/tmp/puppy' --codex-hook"
        let existing: [String: Any] = ["custom": 42, "hooks": ["Stop": [[
            "matcher": "", "metadata": "keep", "hooks": [
                ["type": "command", "command": "echo unrelated"],
                ["type": "command", "command": command]]]]]]
        let installed = try CodexHookInstaller.edit(existing, command: command, install: true)
        let twice = try CodexHookInstaller.edit(installed, command: command, install: true)
        XCTAssertTrue(NSDictionary(dictionary: installed).isEqual(to: twice))
        let removed = try CodexHookInstaller.edit(installed, command: command, install: false)
        XCTAssertEqual(removed["custom"] as? Int, 42)
        let hooks = try XCTUnwrap(removed["hooks"] as? [String: Any])
        XCTAssertEqual(hooks.count, 1)
        let group = try XCTUnwrap((hooks["Stop"] as? [[String: Any]])?.first)
        XCTAssertEqual(group["metadata"] as? String, "keep")
        XCTAssertEqual((group["hooks"] as? [[String: Any]])?.first?["command"] as? String, "echo unrelated")
        XCTAssertThrowsError(try CodexHookInstaller.edit(["hooks": "bad"], command: command, install: true))
        XCTAssertThrowsError(try CodexHookInstaller.edit(["hooks": ["Stop": [42]]], command: command, install: true))
    }

    func testCLIClassification() {
        for args in [["codex"], ["codex", "resume", "abc"], ["codex", "-C", "exec"],
                     ["codex", "--", "exec"], ["codex", "-m", "model", "fix this"]] {
            XCTAssertTrue(CodexProcess.isInteractive(args), "\(args)")
        }
        for args in [["codex", "exec", "fix"], ["codex", "app-server"],
                     ["codex", "--remote", "unix://"], ["codex", "--remote=unix://"]] {
            XCTAssertFalse(CodexProcess.isInteractive(args), "\(args)")
        }
    }

    func testProcessGenerationIsStable() throws {
        let identity = try XCTUnwrap(CodexProcess.identity(getpid()))
        XCTAssertEqual(identity, CodexProcess.identity(getpid()))
        XCTAssertGreaterThan(identity.startedSeconds, 0)
        XCTAssertNil(CodexProcess.identity(Int32.max))
    }

    func testReaderRejectsDeadOrReusedPIDsAndMalformedFiles() throws {
        let directory = try temp()
        try CodexHook.write(event("SessionStart"), process: process, directory: directory, now: now)
        XCTAssertEqual(CodexSessionReader.scan(directory: directory, identity: { _ in self.process }).count, 1)
        XCTAssertTrue(CodexSessionReader.scan(directory: directory, identity: { _ in nil }).isEmpty)
        XCTAssertTrue(CodexSessionReader.scan(directory: directory, identity: { _ in
            CodexProcess.Identity(pid: 123, startedSeconds: 200, startedMicros: 42)
        }).isEmpty)
        try Data("{".utf8).write(to: directory.appendingPathComponent("123.json"))
        XCTAssertTrue(CodexSessionReader.scan(directory: directory, identity: { _ in self.process }).isEmpty)
    }

    func testApprovalDescriptionDoesNotPreventClearingWait() {
        var record = CodexSessionRecord(process: process, sessionID: "session-1", cwd: "/tmp", statusAt: now)
        CodexHook.apply(event("UserPromptSubmit"), to: &record, now: now)
        CodexHook.apply(event("PermissionRequest", input: ["command": "echo hello", "description": "Allow?"]),
                        to: &record, now: now)
        XCTAssertEqual(record.status, "waiting")
        CodexHook.apply(event("PostToolUse"), to: &record, now: now)
        XCTAssertEqual(record.status, "busy")
    }
}
