import Foundation

/// Puppy-owned lifecycle snapshots, never omp transcripts or private session files.
enum OmpSessionReader {
    static let directory: URL = {
        if let path = ProcessInfo.processInfo.environment["PUPPY_OMP_SESSIONS_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".puppy/omp-sessions", isDirectory: true)
    }()

    static func scan(directory: URL = directory,
                     identity: (Int32) -> CodexProcess.Identity? = CodexProcess.identity) -> [SessionInfo] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let decoder = JSONDecoder()
        let nowMilliseconds = Date().timeIntervalSince1970 * 1000
        return files.compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(OmpSessionRecord.self, from: data),
                  record.schemaVersion == 1,
                  record.pid > 0,
                  url.deletingPathExtension().lastPathComponent == String(record.pid),
                  record.hasValidTimestamps(nowMilliseconds: nowMilliseconds),
                  let process = identity(record.pid), process.pid == record.pid else { return nil }
            let startedMilliseconds = Double(process.startedSeconds) * 1000
                + Double(process.startedMicros) / 1000
            // JS estimates birth from wall time minus uptime; the kernel gives the generation.
            guard abs(startedMilliseconds - record.processStartedAt) <= 2000 else { return nil }
            return record.info
        }
    }
}

private struct OmpSessionRecord: Decodable {
    enum Status: String, Decodable {
        case idle, busy, interrupted, error

        var sessionStatus: SessionStatus {
            switch self {
            case .idle: return .idle
            case .busy: return .busy
            case .interrupted: return .other("已中断")
            case .error: return .other("出错")
            }
        }
    }

    let schemaVersion: Int
    let pid: Int32
    let processStartedAt: Double
    let sessionId: String
    let cwd: String
    let name: String?
    let status: Status
    let statusUpdatedAt: Double
    let completedAt: Double?
    let summary: String?

    func hasValidTimestamps(nowMilliseconds: Double) -> Bool {
        func valid(_ value: Double) -> Bool {
            value.isFinite && value > 0 && value <= nowMilliseconds + 2000
        }
        guard valid(processStartedAt), valid(statusUpdatedAt),
              statusUpdatedAt >= processStartedAt - 2000 else { return false }
        if let completedAt {
            guard valid(completedAt), completedAt >= processStartedAt - 2000,
                  completedAt <= statusUpdatedAt else { return false }
        }
        return true
    }

    var info: SessionInfo {
        let completion = status == .idle ? completedAt : nil
        return SessionInfo(provider: .omp,
                           explicitCompletedAt: completion.map { Date(timeIntervalSince1970: $0 / 1000) },
                           completionSummary: completion == nil ? nil : summary,
                           pid: pid, sessionId: sessionId, cwd: cwd, name: name,
                           kind: "interactive", entrypoint: "cli", version: nil,
                           status: status.sessionStatus, waitingFor: nil,
                           startedAt: Date(timeIntervalSince1970: processStartedAt / 1000),
                           statusUpdatedAt: Date(timeIntervalSince1970: statusUpdatedAt / 1000))
    }
}
