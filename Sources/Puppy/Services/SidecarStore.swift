import Foundation

/// Stop hook 落下来的「这一轮到底干了什么」。
///
/// 注册表(`~/.claude/sessions`)只说得出「现在是什么状态」,说不出「刚才那轮做完了什么」——
/// 那句话只在 CLI 进程内存里,唯一的出口就是 hook 的 `last_assistant_message`。
struct SidecarNote: Equatable {
    let sessionId: String
    let summary: String
    /// `stop_reason != end_turn` —— 这轮不是正常收尾(典型:撞到 max_tokens)。
    let abnormal: String?
    let at: Date

    /// 气泡里那一行。
    var display: String {
        abnormal.map { "\(summary) · \($0)" } ?? summary
    }
}

/// `~/.puppy/events/<session-id>.json` 的读写两端。
///
/// **刻意是旁路,不是数据源。** 状态判定全都在注册表那条线上(见
/// `SessionInfo.completedAt(now:within:)`),这里的东西只用来给气泡配文案:
/// hook 没装、没跑、写失败、app 重启期间漏掉,后果都只是气泡退回「跑完了」,状态不会错。
/// 这是把不可靠的边沿事件关进纯装饰层的代价换来的 —— 别让它渗到状态里去。
enum SidecarStore {

    /// `PUPPY_EVENTS_DIR` 只为测试存在,跟 `PUPPY_SESSIONS_DIR` 一个用法。
    static let directory: URL = {
        if let override = ProcessInfo.processInfo.environment["PUPPY_EVENTS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".puppy/events", isDirectory: true)
    }()

    /// app 没开着的时候 hook 照样在写,所以读的这一头得顺手清。
    /// 反正只有 `completedBadgeWindow`(60s)以内的事件用得上,留 6 小时纯属宽容。
    static let ttl: TimeInterval = 6 * 3600

    /// 摘要长度上限。气泡一行放不下这么多,截在写入端只是不想让缓存目录长胖。
    static let summaryLimit = 120

    // MARK: - 读(app 侧)

    /// sessionId → 最近一轮的摘要。目录不存在返回空 —— 没装 hook 是正常状态,不报错。
    static func scan(now: Date = Date()) -> [String: SidecarNote] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        let decoder = JSONDecoder()
        var notes: [String: SidecarNote] = [:]

        for url in entries where url.pathExtension == "json" {
            // 先按 mtime 淘汰,过期的连读都不用读。
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, now.timeIntervalSince(modified) > ttl {
                try? fm.removeItem(at: url)
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let file = try? decoder.decode(EventFile.self, from: data),
                  let note = file.toNote(idFallback: url.deletingPathExtension().lastPathComponent)
            else { continue }    // 半写文件:跳过,下一次事件会自愈
            notes[note.sessionId] = note
        }
        return notes
    }

    // MARK: - 写(hook 侧)

    /// 一个 session 一个文件、覆盖写 —— 只有最后一轮有意义,不留历史就不用管清理节奏。
    /// 原子写:读的那头绝不会看到半个文件。
    static func write(_ note: SidecarNote) throws {
        // sessionId 直接当文件名,先挡掉路径穿越(实测是 UUID,但这是别人喂进来的字符串)。
        let safe = note.sessionId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        guard !safe.isEmpty, safe != ".", safe != ".." else { return }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = EventFile(sessionId: note.sessionId,
                             summary: note.summary,
                             abnormal: note.abnormal,
                             at: note.at.timeIntervalSince1970 * 1000)
        let data = try JSONEncoder().encode(file)
        try data.write(to: directory.appendingPathComponent("\(safe).json"), options: .atomic)
    }

    /// `last_assistant_message` 是整段回答(经常几百行 markdown),气泡只有一行。
    /// 取第一段非空文字并剥掉 markdown 记号 —— 回答的第一句基本就是结论。
    static func distill(_ message: String?) -> String? {
        guard let message else { return nil }
        var insideFence = false
        for rawLine in message.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            // 代码块整块跳过 —— 回答开头就是一段 diff 时,拿第一行代码当摘要毫无意义。
            if line.hasPrefix("```") { insideFence.toggle(); continue }
            if insideFence || line.isEmpty { continue }
            // 标题 / 列表 / 引用的行首记号,以及包住整句的 **粗体**。
            line = line.replacingOccurrences(
                of: "^(#{1,6}|>|[-*+]|\\d+[.)])\\s+", with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: "**", with: "")
            line = line.replacingOccurrences(of: "`", with: "")
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard line.count > summaryLimit else { return line }
            return line.prefix(summaryLimit).trimmingCharacters(in: .whitespaces) + "…"
        }
        return nil
    }

    /// 非正常收尾的说法。`end_turn` / 缺失都算正常,不加后缀。
    static func abnormalLabel(stopReason: String?) -> String? {
        switch stopReason {
        case "max_tokens":     return "被截断"
        case "stop_sequence":  return "提前停下"
        default:               return nil
        }
    }

    /// 盘上的原始 JSON。字段全 Optional,格式漂移时降级而不是整条丢掉。
    private struct EventFile: Codable {
        var sessionId: String?
        var summary: String?
        var abnormal: String?
        /// epoch millis,跟注册表的时间戳同一种单位,省得两边换算。
        var at: Double?

        func toNote(idFallback: String) -> SidecarNote? {
            let id = sessionId.flatMap { $0.isEmpty ? nil : $0 } ?? idFallback
            guard let summary, !summary.isEmpty, let at, at > 0 else { return nil }
            return SidecarNote(sessionId: id,
                               summary: summary,
                               abnormal: abnormal.flatMap { $0.isEmpty ? nil : $0 },
                               at: Date(timeIntervalSince1970: at / 1000))
        }
    }
}
