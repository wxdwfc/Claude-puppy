import Foundation

/// Claude Code 的 `Stop` hook 这一端:收 stdin 上的事件、写 sidecar,以及自己往
/// `~/.claude/settings.json` 里装/卸这条 hook。
///
/// 为什么是 hook 而不是把主路也搬过来:hook 是边沿触发的,漏一次就永远补不回来
/// (`SessionInfo.completedAt` 上那段注释记着这个坑),而且 payload 里**没有 pid**,
/// 而这个 app 从列表行到 iTerm 跳转全是 pid 寻址的。所以 hook 只干注册表干不了的事:
/// 把「这一轮说了什么」递过来。
enum StopHook {

    // MARK: - 收(被 Claude Code 拉起来的那一端)

    /// `puppy --hook`:读 stdin 的 JSON,提炼一句话,落盘,退出。
    ///
    /// **永远 exit 0、永远不往 stdout/stderr 写。** 这是挂在别人每一轮任务收尾上的进程,
    /// 一只桌面宠物的装饰功能没有任何资格在那儿打印错误。
    static func receive() -> Never {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.hookEventName == nil || payload.hookEventName == "Stop",
              let sessionId = payload.sessionId, !sessionId.isEmpty,
              let summary = SidecarStore.distill(payload.lastAssistantMessage)
        else { exit(0) }

        try? SidecarStore.write(SidecarNote(
            sessionId: sessionId,
            summary: summary,
            abnormal: SidecarStore.abnormalLabel(stopReason: payload.stopReason),
            at: Date()
        ))
        exit(0)
    }

    /// hook 的 stdin payload。只挑用得上的字段 —— 其余的(cwd / transcript_path /
    /// permission_mode …)注册表里都有,或者用不上。
    private struct Payload: Decodable {
        var sessionId: String?
        var hookEventName: String?
        var lastAssistantMessage: String?
        var stopReason: String?

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case hookEventName = "hook_event_name"
            case lastAssistantMessage = "last_assistant_message"
            case stopReason = "stop_reason"
        }
    }

    // MARK: - 装 / 卸

    /// `PUPPY_SETTINGS_FILE` 只为测试存在:装卸这套逻辑要能在临时文件上跑一遍,
    /// 不必拿用户真正的 settings.json 当试验田。
    static let settingsFile: URL = {
        if let override = ProcessInfo.processInfo.environment["PUPPY_SETTINGS_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }()

    /// hook 命令里写的**不是** `.build/` 里那个二进制,而是这份拷贝。
    /// 否则 `make clean` 一下,每个 session 每一轮收尾都会去执行一个不存在的文件。
    static let installedBinary = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".puppy/bin/puppy")

    /// 认领标记:装进去的命令永远指向 `installedBinary`,卸的时候按这个路径找回来。
    /// 不往命令里塞注释当标记 —— 那要赌 hook 一定经过 shell。
    private static var marker: String { installedBinary.path }

    /// 装到全局 settings(`~/.claude/settings.json`),对所有项目生效。
    /// 命令指向**当前这个二进制自己**,所以 `make app` 之后重跑一次就能改对路径。
    static func install() -> Int32 {
        guard let source = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            FileHandle.standardError.write(Data("找不到自己的可执行文件路径\n".utf8))
            return 1
        }
        do { try copySelf(from: source) } catch {
            FileHandle.standardError.write(Data("拷贝二进制失败:\(error.localizedDescription)\n".utf8))
            return 1
        }
        let binary = installedBinary.path
        // 路径进 shell 命令行,单引号包住并转义里面的单引号。
        let quoted = "'" + binary.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let entry: [String: Any] = [
            "type": "command",
            "command": "\(quoted) --hook",
            // async:不进那一轮任务收尾的关键路径。少了这个,每次 Claude 说完话
            // 都要等这个进程退出才算完 —— 为一句气泡文案拖慢真正的工作,不值。
            "async": true,
            "timeout": 5,
        ]

        do {
            var settings = try load()
            var hooks = settings["hooks"] as? [String: Any] ?? [:]
            var groups = (hooks["Stop"] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            groups.append(["hooks": [entry]])
            hooks["Stop"] = groups
            settings["hooks"] = hooks
            try save(settings)
            print("已装到 \(settingsFile.path)")
            print("  Stop → \(binary) --hook")
            print("  (二进制是拷贝的,\(source.path) 被删掉也不影响)")
            print("新开的 Claude Code session 就会开始上报;已经开着的要重启才生效。")
            return 0
        } catch {
            FileHandle.standardError.write(Data("装 hook 失败:\(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// 卸干净:按标记摘掉自己那条,顺手把空掉的容器删掉,别在别人配置里留渣。
    static func uninstall() -> Int32 {
        do {
            var settings = try load()
            guard var hooks = settings["hooks"] as? [String: Any],
                  let groups = hooks["Stop"] as? [[String: Any]]
            else { print("没装过,什么都不用做"); return 0 }

            let kept = groups.filter { !isOurs($0) }
            guard kept.count != groups.count else { print("没装过,什么都不用做"); return 0 }

            if kept.isEmpty { hooks.removeValue(forKey: "Stop") } else { hooks["Stop"] = kept }
            if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
            try save(settings)
            print("已从 \(settingsFile.path) 卸掉")
            return 0
        } catch {
            FileHandle.standardError.write(Data("卸 hook 失败:\(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// 把自己拷到一个稳定位置。已经装过就覆盖 —— 重装即升级。
    private static func copySelf(from source: URL) throws {
        let fm = FileManager.default
        guard source != installedBinary else { return }    // 就是那份拷贝自己在装
        try fm.createDirectory(at: installedBinary.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        // 直接覆盖会 ETXTBSY,而且正在跑的 hook 进程也不该被抽掉脚下的文件;
        // 先写到旁边再原子替换。
        let staging = installedBinary.appendingPathExtension("new")
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: source, to: staging)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        _ = try fm.replaceItemAt(installedBinary, withItemAt: staging)
    }

    /// 一个 Stop 分组是不是我们装的 —— 只要里面有任意一条带标记就算。
    private static func isOurs(_ group: [String: Any]) -> Bool {
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains {
            guard let command = $0["command"] as? String else { return false }
            return command.contains(marker) && command.contains("--hook")
        }
    }

    /// 用 JSONSerialization 而不是 Codable:settings.json 是**用户的**文件,
    /// 里面有一堆我们不认识的键,解成结构体再写回去等于顺手删掉它们。
    private static func load() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsFile), !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure("\(settingsFile.lastPathComponent) 不是一个 JSON 对象,不敢动它")
        }
        return object
    }

    /// 改别人的配置之前留一份 `.bak`。
    private static func save(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes])
        let fm = FileManager.default
        try fm.createDirectory(at: settingsFile.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if let existing = try? Data(contentsOf: settingsFile), !existing.isEmpty {
            try? existing.write(to: settingsFile.appendingPathExtension("bak"), options: .atomic)
        }
        try data.write(to: settingsFile, options: .atomic)
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
