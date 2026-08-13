import Foundation
import Combine

/// 唯一的 source of truth。事件驱动:FSEvents 触发重扫,30s 低频兜底,
/// 另外在「完成徽标 / 庆祝动画 / 气泡分钟标签」到期的确切时刻排一次性定时器 —— 没有任何轮询。
@MainActor
final class SessionStore: ObservableObject {

    /// 完成徽标(列表里的 ✅)显示时长,同时也是「跑完了」气泡在栈里活多久。
    static let completedBadgeWindow: TimeInterval = 60
    /// 庆祝动画时长。
    static let celebrateWindow: TimeInterval = 10
    /// 兜底重扫周期:防漏事件 + 清理死 pid 残留。
    static let fallbackInterval: TimeInterval = 30
    /// 文件被截断重写的瞬间读不出来时,沿用上一次好数据的时长 —— 防止行闪烁。
    static let staleGrace: TimeInterval = 3

    @Published private(set) var rows: [SessionRow] = []
    @Published private(set) var mascot: MascotState = .sleeping
    /// 最近 `celebrateWindow` 内有 session 跑完 —— 独立于 `mascot`,
    /// 这样别的 session 还在跑的时候也能冒 ✓,不会被 working 吃掉。
    @Published private(set) var celebrating: Bool = false
    /// 小狗身边那摞气泡,顺序与 `rows` 一致(等最久的在前 = 贴着小狗那一格)。
    /// 纯派生量,没有任何独立生命周期 —— 见 `BubbleItem`。
    @Published private(set) var bubbles: [BubbleItem] = []
    /// 吉祥物窗口被完全遮挡时置 false,视图据此停掉动画。
    @Published var mascotVisible: Bool = true
    /// 当前形象。跟 session 逻辑一点关系都没有,放这儿只是因为几个视图都盯着这一个 store。
    /// 默认给内置的,开窗口时才由 AppDelegate 换成用户选的 —— `--list` / `--watch`
    /// 这些 headless 路径也会建 store,不该顺手去读磁盘、解一堆 PNG。
    @Published var skin: MascotSkin = Sprites.builtIn
    /// 递增即抖一下 —— 用于 iTerm 跳转失败的无声反馈。
    @Published private(set) var shakeToken: Int = 0

    /// CLI `--watch` 模式用的变更回调。
    var onChange: (() -> Void)?

    private var lastGood: [Int32: (info: SessionInfo, at: Date)] = [:]
    private var staleDeadline: Date?

    private var watcher: DirectoryWatcher?
    private var fallbackTimer: DispatchSourceTimer?
    private var expiryTimer: DispatchSourceTimer?
    private var started = false

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true

        refresh()

        watcher = DirectoryWatcher(path: SessionRegistryReader.directory.path) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        // 目录还不存在时 start() 会失败(比如从没跑过 Claude Code);
        // 不创建目录,交给兜底定时器,等目录出现后的下一次 refresh 里重试。
        watcher?.start()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.fallbackInterval,
            repeating: Self.fallbackInterval,
            leeway: .seconds(10)     // 大 leeway:允许系统把唤醒合并到别的定时器上
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.watcher?.start() == false { /* 目录仍不存在,继续等 */ }
            self.refresh()
        }
        timer.resume()
        fallbackTimer = timer
    }

    func stop() {
        watcher?.stop(); watcher = nil
        fallbackTimer?.cancel(); fallbackTimer = nil
        expiryTimer?.cancel(); expiryTimer = nil
        started = false
    }

    func shake() { shakeToken &+= 1 }

    /// 只给 `--render` 用:塞一组假数据进去,不启动任何监听。
    func installPreviewRows(_ preview: [SessionRow]) {
        let now = Date()
        rows = Self.sorted(preview)
        celebrating = Self.celebrating(rows, now: now)
        mascot = MascotState.derive(rows: rows, celebrating: celebrating)
        bubbles = rows.compactMap { BubbleItem(row: $0, now: now) }
    }

    // MARK: - 扫描

    /// 「谁刚跑完」不在这里 diff —— 每一行自己看自己的字段就能算出来
    /// (`SessionInfo.completedAt(now:within:)`)。所以这里没有任何跨次刷新的状态要维护:
    /// 少一次事件、app 中途重启、pid 被复用,都不会让某一次「跑完了」永久丢掉。
    func refresh() {
        let result = SessionRegistryReader.scan()
        let now = Date()
        let scanned = merge(result, now: now)

        let newRows = Self.sorted(scanned.map { info in
            SessionRow(info: info, completedAt: info.completedAt(now: now, within: Self.completedBadgeWindow))
        })
        let newCelebrating = Self.celebrating(newRows, now: now)
        let newMascot = MascotState.derive(rows: newRows, celebrating: newCelebrating)
        let newBubbles = newRows.compactMap { BubbleItem(row: $0, now: now) }

        let changed = newRows != rows
            || newMascot != mascot
            || newCelebrating != celebrating
            || newBubbles != bubbles

        rows = newRows
        celebrating = newCelebrating
        mascot = newMascot
        bubbles = newBubbles

        scheduleNextExpiry(now: now)
        if changed { onChange?() }
    }

    /// 把「这次读到的」和「上次读到的好数据」拼起来:
    /// 文件正被截断重写时(读不出来但进程还活着)短暂沿用旧值,避免行闪一下又回来。
    private func merge(_ result: SessionRegistryReader.Result, now: Date) -> [SessionInfo] {
        var infos = result.infos
        staleDeadline = nil
        for pid in result.unreadable {
            guard let cached = lastGood[pid], now.timeIntervalSince(cached.at) < Self.staleGrace else { continue }
            infos.append(cached.info)
            // 如果文件一直读不出来,不会再有 FSEvents 事件把这行清掉 —— 自己排一发。
            staleDeadline = min(staleDeadline ?? .distantFuture, cached.at.addingTimeInterval(Self.staleGrace))
        }
        for info in result.infos { lastGood[info.pid] = (info, now) }
        let present = Set(infos.map(\.pid))
        lastGood = lastGood.filter { present.contains($0.key) }
        return infos
    }

    /// 完成徽标、庆祝动画、气泡上的分钟标签都是「到点就该变」的状态。与其每秒轮询,
    /// 不如在最近的一个到期时刻排一发一次性定时器。
    private func scheduleNextExpiry(now: Date) {
        expiryTimer?.cancel()
        expiryTimer = nil

        var deadlines: [TimeInterval] = []
        if let staleDeadline { deadlines.append(staleDeadline.timeIntervalSince(now)) }
        for at in rows.compactMap(\.completedAt) {
            let age = now.timeIntervalSince(at)
            if age < Self.celebrateWindow { deadlines.append(Self.celebrateWindow - age) }
            deadlines.append(Self.completedBadgeWindow - age)    // completedAt 还在,就说明这一条尚未到期
        }
        // 气泡上的「已等 40m」:在下一个整分边界醒一次就够。栈空时一次都不排 ——
        // 这是这个常驻窗口唯一的周期性唤醒,且下面给了 1s leeway 让系统合并掉。
        for row in rows where BubbleItem(row: row, now: now) != nil {
            guard let since = row.info.statusUpdatedAt else { continue }
            let age = now.timeIntervalSince(since)
            guard age >= 0 else { continue }
            deadlines.append((age / 60).rounded(.down) * 60 + 60 - age)
        }
        guard let next = deadlines.min() else { return }

        let delay = max(0.1, next)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // 远处的唤醒给大 leeway,近处的(动画到期)要准。
        timer.schedule(deadline: .now() + delay, leeway: delay > 5 ? .seconds(1) : .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        expiryTimer = timer
    }

    /// 庆祝动画只看最近 `celebrateWindow` 内有没有人跑完 —— 比完成徽标的窗口短得多。
    private static func celebrating(_ rows: [SessionRow], now: Date) -> Bool {
        rows.contains { row in
            guard let at = row.completedAt else { return false }
            return now.timeIntervalSince(at) < Self.celebrateWindow
        }
    }

    // MARK: - 排序

    /// waiting(等最久的在前)→ busy(最新变 busy 的在前)→ 其余;同级按 pid 稳定排序防跳动。
    static func sorted(_ rows: [SessionRow]) -> [SessionRow] {
        func rank(_ r: SessionRow) -> Int {
            switch r.info.status {
            case .waiting: return 0
            case .busy: return 1
            default: return r.completedAt != nil ? 2 : 3
            }
        }
        return rows.sorted { a, b in
            let (ra, rb) = (rank(a), rank(b))
            if ra != rb { return ra < rb }
            let ta = a.info.statusUpdatedAt ?? .distantPast
            let tb = b.info.statusUpdatedAt ?? .distantPast
            if ta != tb {
                return ra == 0 ? ta < tb : ta > tb   // waiting 比谁等得久,其余比谁最新
            }
            return a.info.pid < b.info.pid
        }
    }
}
