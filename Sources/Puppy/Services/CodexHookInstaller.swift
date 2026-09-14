import Foundation

enum CodexHookInstaller {
    static let binary = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".puppy/bin/puppy-codex")
    static let settings: URL = {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let root = home.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return root.appendingPathComponent("hooks.json")
    }()

    static func command(for binary: URL) -> String {
        "'" + binary.path.replacingOccurrences(of: "'", with: "'\\''") + "' --codex-hook"
    }

    static func edit(_ settings: [String: Any], command: String, install: Bool) throws -> [String: Any] {
        var result = settings
        if let value = result["hooks"], !(value is [String: Any]) { throw Failure("hooks 必须是 JSON 对象") }
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for event in CodexHook.events {
            if let value = hooks[event], !(value is [[String: Any]]) { throw Failure("\(event) 必须是数组") }
            var groups: [[String: Any]] = []
            for var group in hooks[event] as? [[String: Any]] ?? [] {
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    throw Failure("\(event) 的 hooks 必须是数组")
                }
                let kept = handlers.filter { $0["command"] as? String != command }
                // Preserve untouched groups verbatim, including custom group metadata.
                if kept.count == handlers.count { groups.append(group) }
                else if !kept.isEmpty { group["hooks"] = kept; groups.append(group) }
            }
            if install {
                // Sync prevents hooks overtaking each other; no output means no decisions.
                groups.append(["hooks": [["type": "command", "command": command, "timeout": 1]]])
            }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        if hooks.isEmpty { result.removeValue(forKey: "hooks") } else { result["hooks"] = hooks }
        return result
    }

    static func run(install: Bool) -> Int32 {
        do {
            let fm = FileManager.default
            let original: Data? = fm.fileExists(atPath: settings.path) ? try Data(contentsOf: settings) : nil
            let object: [String: Any]
            if let original {
                guard let decoded = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                    throw Failure("hooks.json 不是 JSON 对象,未修改")
                }
                object = decoded
            } else { object = [:] }
            let changed = try edit(object, command: command(for: binary), install: install)
            let data = try JSONSerialization.data(withJSONObject: changed, options: [.prettyPrinted, .sortedKeys])
            if install {
                guard let source = Bundle.main.executableURL else { throw Failure("找不到 Puppy 可执行文件") }
                try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
                if source.resolvingSymlinksInPath() != binary.resolvingSymlinksInPath() {
                    try Data(contentsOf: source).write(to: binary, options: .atomic)
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
                }
                try fm.createDirectory(at: CodexSessionReader.directory, withIntermediateDirectories: true)
            }
            if !NSDictionary(dictionary: changed).isEqual(to: object) {
                try fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let original {
                    let backup = settings.appendingPathExtension("puppy-\(UUID().uuidString).bak")
                    try original.write(to: backup, options: .atomic)
                    print("备份: \(backup.path)")
                }
                try data.write(to: settings, options: .atomic)
            }
            if install {
                print("已安装 Codex CLI hooks: \(settings.path)")
                print("命令: \(command(for: binary))")
                print("在 Codex 的 /hooks 中审阅并信任 Puppy hooks,然后新开或恢复 CLI 会话。")
                print("只采集本地交互式 CLI;不接管审批,不读取聊天记录。")
            } else {
                print("已移除 Puppy 的 Codex hooks。已运行的 CLI 需重启才能停止旧 hooks。")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Codex hook 配置失败: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
