import Foundation

/// 读 `~/.claude/sessions/`。整个目录一次全读(文件都是几百字节),
/// 幂等,所以 FSEvents 的事件只需要当作「该重扫了」的触发器。
enum SessionRegistryReader {

    /// `PUPPY_SESSIONS_DIR` 只为测试存在:可以在临时目录里伪造整套注册表,
    /// 不必往真实的 `~/.claude/sessions` 里塞假文件。
    static let directory: URL = {
        if let override = ProcessInfo.processInfo.environment["PUPPY_SESSIONS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)
    }()

    /// 同样只为测试:假 pid 的存活检查会被跳过。
    private static let ignoreLiveness =
        ProcessInfo.processInfo.environment["PUPPY_IGNORE_LIVENESS"] == "1"

    struct Result {
        var infos: [SessionInfo] = []
        /// 文件在盘上、进程还活着,但这一刻读不出来(典型:被截断重写到一半)。
        /// 调用方应该短暂沿用上一次的好数据,而不是让这一行闪掉。
        var unreadable: Set<Int32> = []
    }

    /// 目录不存在时返回空结果 —— 不创建、不报错,界面显示「无 session」。
    static func scan() -> Result {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return Result() }

        let decoder = JSONDecoder()
        var result = Result()
        result.infos.reserveCapacity(entries.count)

        for url in entries where url.pathExtension == "json" {
            guard let pidFromName = Int32(url.deletingPathExtension().lastPathComponent) else { continue }
            guard isAlive(pid: pidFromName) else { continue }   // 死 pid 的残留文件直接丢弃

            guard let data = try? Data(contentsOf: url),
                  let file = try? decoder.decode(SessionFile.self, from: data),
                  let info = file.toInfo(pidFallback: pidFromName)
            else {
                result.unreadable.insert(pidFromName)
                continue
            }
            // headless / 子代理进程不进列表;kind 缺失时宽容放行。
            if let kind = info.kind, kind != "interactive" { continue }
            // JSON 里的 pid 与文件名不一致时以 JSON 为准,但要重新验活。
            guard info.pid == pidFromName || isAlive(pid: info.pid) else { continue }
            result.infos.append(info)
        }
        return result
    }

    /// 残留死文件过滤。EPERM = 进程存在但不属于我们(不会发生在自己的 session 上,但便宜且安全)。
    static func isAlive(pid: Int32) -> Bool {
        if ignoreLiveness { return true }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
