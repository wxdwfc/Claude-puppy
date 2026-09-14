import Foundation
import CryptoKit
import Darwin

/// Observational only: no approval decisions, model context, or transcript reads.
enum CodexHook {
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
                         "PostToolUse", "Stop", "Interrupt", "SessionEnd"]

    static func receive() -> Never {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let process = CodexProcess.findCLI() else { exit(0) }
        try? write(event, process: process, directory: CodexSessionReader.directory)
        exit(0)
    }

    static func write(_ event: [String: Any], process: CodexProcess.Identity,
                      directory: URL, now: Date = Date()) throws {
        guard let name = event["hook_event_name"] as? String, events.contains(name),
              let sessionID = event["session_id"] as? String, !sessionID.isEmpty,
              let cwd = event["cwd"] as? String, event["agent_id"] as? String == nil else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(process.pid).json")
        // Codex can run tool hooks concurrently. Lock the read/modify/atomic-write cycle.
        let lock = open(directory.appendingPathComponent("\(process.pid).lock").path,
                        O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { return }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { return }
        defer { flock(lock, LOCK_UN) }
        let old = (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode(CodexSessionRecord.self, from: $0)
        }
        let sameSession = old?.process == process && old?.sessionID == sessionID
        if name == "SessionEnd" {
            if sameSession { try? fm.removeItem(at: url) }
            return
        }
        // A delayed tool/Stop hook must never resurrect or overwrite another session.
        guard sameSession || name == "SessionStart" || name == "UserPromptSubmit" else { return }
        var record = sameSession ? old! : CodexSessionRecord(process: process,
            sessionID: sessionID, cwd: cwd, statusAt: now)
        guard apply(event, to: &record, now: now) else { return }
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }

    @discardableResult
    static func apply(_ event: [String: Any], to record: inout CodexSessionRecord,
                      now: Date) -> Bool {
        guard let name = event["hook_event_name"] as? String else { return false }
        let turn = event["turn_id"] as? String
        let previousStatus = record.status
        let previousWaits = record.waits
        switch name {
        case "SessionStart":
            // Startup isn't completion; compaction must not turn an active turn idle.
            return true
        case "UserPromptSubmit":
            guard let turn else { return false }
            record.turnID = turn
            record.status = "busy"
            record.completedAt = nil
            record.summary = nil
            record.waits = [:]
            record.statusAt = now
            if let cwd = event["cwd"] as? String { record.cwd = cwd }
        case "PreToolUse", "PostToolUse", "PermissionRequest":
            guard let turn, turn == record.turnID, record.completedAt == nil,
                  record.status == "busy" || record.status == "waiting" else { return false }
            guard let key = toolKey(event) else { return false }
            if name == "PermissionRequest" {
                record.waits[key] = "审批请求"
            } else if name == "PreToolUse", event["tool_name"] as? String == "request_user_input" {
                record.waits[key] = "等待输入"
            } else if name == "PostToolUse" {
                record.waits.removeValue(forKey: key)
            }
            record.status = record.waits.isEmpty ? "busy" : "waiting"
        case "Stop", "Interrupt":
            guard let turn, turn == record.turnID, record.completedAt == nil,
                  record.status == "busy" || record.status == "waiting" else { return false }
            record.waits = [:]
            record.status = name == "Stop" ? "idle" : "interrupted"
            record.completedAt = name == "Stop" ? now : nil
            record.summary = name == "Stop" ? SidecarStore.distill(event["last_assistant_message"] as? String) : nil
            record.statusAt = now
        default: return false
        }
        if record.status != previousStatus || record.waits != previousWaits { record.statusAt = now }
        return true
    }

    private static func toolKey(_ event: [String: Any]) -> String? {
        guard let name = event["tool_name"] as? String,
              var input = event["tool_input"] else { return nil }
        // PermissionRequest may add a human-facing description absent in PostToolUse.
        if (name == "Bash" || name == "apply_patch"), var fields = input as? [String: Any] {
            fields.removeValue(forKey: "description")
            input = fields
        }
        guard let data = try? JSONSerialization.data(withJSONObject: [name, input], options: [.sortedKeys])
        else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
