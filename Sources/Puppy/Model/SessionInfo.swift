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

    /// 「刚跑完一轮」的判定 —— 只看这个文件自己的字段,不依赖 app 有没有目击过状态跳变。
    ///
    /// 注册表里没有 "done",但 `status` 加上「什么时候变成这个 status 的」已经够用:
    /// 一轮任务收尾时 CLI 会把 status 刷成 idle 并更新 statusUpdatedAt,
    /// 于是「是 idle,而且刚变成 idle」就是「刚跑完」。
    ///
    /// 先前是 diff 出 `busy → idle` 这条边来判定的,漏一次就永远补不回来。而真实世界里
    /// 一轮任务收尾于 `waiting → idle`(答完权限询问那一下这轮就结束了)非常常见 ——
    /// 「有时候跑完了不冒气泡」就是这么来的。无状态判定顺带把漏事件、app 重启、
    /// pid 复用(旧 pid 的残留完成记录)这几类问题一起消掉了。
    ///
    /// 唯一要摘掉的是刚开出来的新 session:它一出生就是 idle,但那一刻的
    /// statusUpdatedAt 紧贴着 startedAt(实测 33ms),用这个把它跟真的跑完区分开。
    func completedAt(now: Date, within window: TimeInterval) -> Date? {
        guard status == .idle, let at = statusUpdatedAt else { return nil }
        guard now.timeIntervalSince(at) < window else { return nil }
        if let startedAt, at.timeIntervalSince(startedAt) < Self.birthSlop { return nil }
        return at
    }

    /// 新 session 落地到写下第一个 idle 的耗时上限。
    private static let birthSlop: TimeInterval = 2

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
    /// 这个 bg session 正在替谁干活。
    var jobId: String?
    /// 这一轮任务被 park 到了后台(Ctrl-B),交给 `jobId` 等于它的那个 bg session。
    var parkedJobId: String?

    /// 注册表文件只在状态跳变时才写,没有心跳。
    var stamp: Double? { statusUpdatedAt ?? updatedAt }

    /// `pidFallback` 来自文件名:即使 JSON 里 pid 字段缺失也还能定位进程。
    ///
    /// `parkedWorker` = `jobId` 与本行 `parkedJobId` 相同的那个 bg session,没有就传 nil。
    /// 一轮任务被 park 到后台之后,CLI 就不再更新这个文件了,`status` 会永久冻结在 park
    /// 那一刻的 `busy` —— 「明明跑完了还显示运行中」就是这么来的。真实状态在替它干活的
    /// bg session 身上,所以整套状态字段都从那边镜像过来。
    ///
    /// 那个 bg 进程都没了,说明活已经结束,按 `idle` 算。时间戳仍旧保留 park 那一刻的
    /// (而不是"现在"),免得凭空冒出一个假的「刚完成」。
    func toInfo(pidFallback: Int32, parkedWorker: SessionFile?) -> SessionInfo? {
        let resolved = pid.map(Int32.init) ?? pidFallback
        guard resolved > 0 else { return nil }

        let live: (status: String?, waitingFor: String?, stamp: Double?)
        switch (parkedJobId, parkedWorker) {
        case (nil, _):            live = (status, waitingFor, stamp)
        case (_, let worker?):    live = (worker.status, worker.waitingFor, worker.stamp)
        case (_, nil):            live = ("idle", nil, stamp)
        }

        return SessionInfo(
            pid: resolved,
            sessionId: sessionId,
            cwd: cwd,
            name: name,
            kind: kind,
            entrypoint: entrypoint,
            version: version,
            status: SessionStatus(raw: live.status),
            waitingFor: live.waitingFor,
            startedAt: Self.date(fromEpochMillis: startedAt),
            statusUpdatedAt: Self.date(fromEpochMillis: live.stamp)
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

/// 一行 = session + 推导出来的完成时刻(见 `SessionInfo.completedAt(now:within:)`)。
struct SessionRow: Identifiable, Equatable {
    let info: SessionInfo
    let completedAt: Date?

    var id: Int32 { info.pid }

    var display: DisplayState {
        switch info.status {
        case .waiting: return .waiting(info.waitingFor)
        case .busy: return .busy
        // completedAt 只可能伴随 idle 出现,所以别的分支不用再考虑「刚完成」。
        case .idle: return completedAt != nil ? .completed : .idle
        case .other(let s): return .other(s)
        }
    }

    /// 当前状态已经持续了多久。
    func stateDuration(now: Date) -> TimeInterval? {
        guard let t = info.statusUpdatedAt else { return nil }
        return max(0, now.timeIntervalSince(t))
    }
}
