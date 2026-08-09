import Foundation

/// 注册表里出现过的 status。schema 未文档化,任何没见过的值走 `.other` 保持中性,
/// 绝不因为 CLI 升级出了新状态就崩溃或误判。
enum SessionStatus: Equatable {
    case busy
    case idle
    case waiting
    case other(String)

    init(raw: String?) {
        switch raw?.lowercased() {
        case "busy": self = .busy
        case "idle": self = .idle
        case "waiting": self = .waiting
        case let s?: self = .other(s)
        case nil: self = .other("unknown")
        }
    }

    var raw: String {
        switch self {
        case .busy: return "busy"
        case .idle: return "idle"
        case .waiting: return "waiting"
        case .other(let s): return s
        }
    }
}

/// `~/.claude/sessions/<pid>.json` 的一条记录。
/// 全字段 Optional:schema 会随 CLI 版本漂移,缺字段必须能降级显示而不是丢掉整行。
struct SessionInfo: Identifiable, Equatable {
    let pid: Int32
    let sessionId: String?
    let cwd: String?
    let name: String?
    let kind: String?
    let entrypoint: String?
    let version: String?
    let status: SessionStatus
    let waitingFor: String?
    let startedAt: Date?
    let statusUpdatedAt: Date?

    var id: Int32 { pid }

    /// 显示名:优先 CLI 自己派生的 name,退化到 cwd 末段,再退化到 pid。
    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let cwd, !cwd.isEmpty { return URL(fileURLWithPath: cwd).lastPathComponent }
        return "pid \(pid)"
    }

    /// cwd 缩写成 `~/a/b` 形式。
    var shortCwd: String {
        guard let cwd, !cwd.isEmpty else { return "" }
        let home = NSHomeDirectory()
        if cwd == home { return "~" }
        if cwd.hasPrefix(home + "/") { return "~" + cwd.dropFirst(home.count) }
        return cwd
    }
}

/// 磁盘上的原始 JSON。解码失败(半写文件)由调用方跳过,下一次 FSEvents 事件会自愈。
struct SessionFile: Decodable {
    var pid: Int?
    var sessionId: String?
    var cwd: String?
    var name: String?
    var kind: String?
    var entrypoint: String?
    var version: String?
    var status: String?
    var waitingFor: String?
    var startedAt: Double?
    var updatedAt: Double?
    var statusUpdatedAt: Double?

    /// `pidFallback` 来自文件名:即使 JSON 里 pid 字段缺失也还能定位进程。
    func toInfo(pidFallback: Int32) -> SessionInfo? {
        let resolved = pid.map(Int32.init) ?? pidFallback
        guard resolved > 0 else { return nil }
        return SessionInfo(
            pid: resolved,
            sessionId: sessionId,
            cwd: cwd,
            name: name,
            kind: kind,
            entrypoint: entrypoint,
            version: version,
            status: SessionStatus(raw: status),
            waitingFor: waitingFor,
            startedAt: Self.date(fromEpochMillis: startedAt),
            statusUpdatedAt: Self.date(fromEpochMillis: statusUpdatedAt ?? updatedAt)
        )
    }

    private static func date(fromEpochMillis ms: Double?) -> Date? {
        guard let ms, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}

/// 界面上真正要画的状态 —— 只有 `.completed` 是 app 推导出来的,其余直读文件。
enum DisplayState: Equatable {
    case waiting(String?)   // 需要用户介入,附 waitingFor
    case busy
    case completed          // 由 busy → idle 的转变推导,限时显示
    case idle
    case other(String)

    var icon: String {
        switch self {
        case .waiting: return "✋"
        case .busy: return "⏳"
        case .completed: return "✅"
        case .idle: return "💤"
        case .other: return "•"
        }
    }

    var label: String {
        switch self {
        case .waiting(let reason): return reason.map { "等待:\($0)" } ?? "等待输入"
        case .busy: return "运行中"
        case .completed: return "刚完成"
        case .idle: return "空闲"
        case .other(let s): return s
        }
    }
}

/// 一行 = session + 推导出来的完成时刻。
struct SessionRow: Identifiable, Equatable {
    let info: SessionInfo
    let completedAt: Date?

    var id: Int32 { info.pid }

    var display: DisplayState {
        switch info.status {
        case .waiting: return .waiting(info.waitingFor)
        case .busy: return .busy
        case .idle: return completedAt != nil ? .completed : .idle
        case .other(let s): return completedAt != nil ? .completed : .other(s)
        }
    }

    /// 当前状态已经持续了多久。
    func stateDuration(now: Date) -> TimeInterval? {
        guard let t = info.statusUpdatedAt else { return nil }
        return max(0, now.timeIntervalSince(t))
    }
}
