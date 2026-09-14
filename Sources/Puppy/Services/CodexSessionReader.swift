import Foundation

/// Puppy-owned registry, not Codex's private transcript/database schema.
enum CodexSessionReader {
    static let directory: URL = {
        if let path = ProcessInfo.processInfo.environment["PUPPY_CODEX_SESSIONS_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".puppy/codex-sessions", isDirectory: true)
    }()

    static func scan(directory: URL = directory,
                     identity: (Int32) -> CodexProcess.Identity? = CodexProcess.identity) -> [SessionInfo] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(CodexSessionRecord.self, from: data),
                  record.schemaVersion == 1,
                  url.deletingPathExtension().lastPathComponent == String(record.process.pid),
                  identity(record.process.pid) == record.process else { return nil }
            return record.info
        }
    }
}

struct CodexSessionRecord: Codable {
    var schemaVersion = 1
    let process: CodexProcess.Identity
    let sessionID: String
    var cwd: String
    var status = "idle"
    var statusAt: Date
    var completedAt: Date?
    var summary: String?
    var turnID: String?
    /// Keyed by tool invocation/input; unrelated parallel tools cannot clear a wait.
    var waits: [String: String] = [:]

    var info: SessionInfo {
        SessionInfo(provider: .codex, explicitCompletedAt: completedAt,
                    completionSummary: summary, pid: process.pid, sessionId: sessionID,
                    cwd: cwd, name: nil, kind: "interactive", entrypoint: "cli",
                    version: nil, status: status == "interrupted" ? .other("已中断") : SessionStatus(raw: status),
                    waitingFor: waits.values.sorted().first,
                    startedAt: Date(timeIntervalSince1970: Double(process.startedSeconds)),
                    statusUpdatedAt: statusAt)
    }
}
