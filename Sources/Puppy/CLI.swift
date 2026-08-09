import Foundation

/// Headless 模式:先于窗口创建执行,用来在没有 UI 的情况下验证数据层。
@MainActor
enum CLI {

    static func list() {
        let store = SessionStore()
        store.refresh()
        printTable(store.rows, header: "session (\(store.rows.count)) — mascot: \(banner(store))")
    }

    static func watch() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)   // 重定向到文件时也要实时可见
        let store = SessionStore()
        store.onChange = { [weak store] in
            guard let store else { return }
            let stamp = timeFormatter.string(from: Date())
            print("\n[\(stamp)] mascot: \(banner(store))")
            for bubble in store.bubbles { print("  💬 \(bubble.debugLine)") }
            printTable(store.rows, header: nil)
        }
        store.start()
        print("watching \(SessionRegistryReader.directory.path) — Ctrl-C 退出")
        let stamp = timeFormatter.string(from: Date())
        print("\n[\(stamp)] mascot: \(banner(store))")
        for bubble in store.bubbles { print("  💬 \(bubble.debugLine)") }
        printTable(store.rows, header: nil)
        dispatchMain()
    }

    /// `--focus <pid>`:单独验证 pid → tty → iTerm2 这条链路。
    static func focus(pid: Int32) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        print("pid \(pid) → tty \(ITermFocuser.tty(for: pid) ?? "(无 / 非 iTerm 终端)")")
        let focuser = ITermFocuser()
        focuser.focus(pid: pid) { outcome in
            switch outcome {
            case .focused:       print("✅ 已选中对应的 iTerm2 session")
            case .activatedOnly: print("⚠️  tty 匹配不上,只把 iTerm2 提到前台(tmux / ssh / 别的终端)")
            case .notAuthorized: print("🔒 Automation 授权被拒 —— 需要在系统设置里放行")
            case .failed(let m): print("❌ \(m)")
            }
            exit(0)
        }
        // Apple Events 在后台队列上跑,主线程等回调。
        dispatchMain()
    }

    // MARK: - 输出

    /// 身体动画 + 完成徽标。两者独立,所以都要打出来才看得出真实状态。
    private static func banner(_ store: SessionStore) -> String {
        store.celebrating && store.mascot != .celebrating
            ? "\(store.mascot.rawValue) + ✓"
            : store.mascot.rawValue
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func printTable(_ rows: [SessionRow], header: String?) {
        if let header { print(header) }
        guard !rows.isEmpty else {
            print("  (无运行中的 Claude Code session)")
            return
        }
        let now = Date()
        let nameWidth = max(12, rows.map { $0.info.displayName.count }.max() ?? 12)
        for row in rows {
            let name = row.info.displayName.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let dur = row.stateDuration(now: now).map(format(duration:)) ?? "-"
            let pid = String(row.info.pid).padding(toLength: 7, withPad: " ", startingAt: 0)
            let state = "\(row.display.icon) \(row.display.label)".padding(toLength: 22, withPad: " ", startingAt: 0)
            print("  \(pid) \(name)  \(state) \(dur.padding(toLength: 7, withPad: " ", startingAt: 0)) \(row.info.shortCwd)")
        }
    }

    static func format(duration: TimeInterval) -> String {
        let s = Int(duration)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m\(s % 60)s" }
        return "\(s / 3600)h\((s % 3600) / 60)m"
    }
}
