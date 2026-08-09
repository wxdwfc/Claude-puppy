import Foundation
import Combine

/// 唯一的 source of truth。事件驱动:FSEvents 触发重扫,30s 低频兜底,
/// 另外在「完成徽标 / 庆祝动画」到期的确切时刻排一次性定时器 —— 没有任何轮询。
@MainActor
final class SessionStore: ObservableObject {

    /// 完成徽标(列表里的 ✅)显示时长。
    static let completedBadgeWindow: TimeInterval = 60
    /// 庆祝动画时长。
    static let celebrateWindow: TimeInterval = 10
    /// 气泡停留时长:「在等你」比「跑完了」更需要被看见,留久一点。
    static let waitingBubbleDuration: TimeInterval = 12
    static let doneBubbleDuration: TimeInterval = 6
    /// 一直没人管的话,隔这么久再催一次 —— 漏看一次不至于就永远漏掉。
    static let nagInterval: TimeInterval = 90
    /// 兜底重扫周期:防漏事件 + 清理死 pid 残留。
    static let fallbackInterval: TimeInterval = 30
    /// 文件被截断重写的瞬间读不出来时,沿用上一次好数据的时长 —— 防止行闪烁。
    static let staleGrace: TimeInterval = 3

    @Published private(set) var rows: [SessionRow] = []
    @Published private(set) var mascot: MascotState = .sleeping
    /// 最近 `celebrateWindow` 内有 session 跑完 —— 独立于 `mascot`,
    /// 这样别的 session 还在跑的时候也能冒 ✓,不会被 working 吃掉。
    @Published private(set) var celebrating: Bool = false
    /// 小狗当前要说的话,nil = 不说话。到期由 store 自己清掉。
    @Published private(set) var announcement: Announcement?
    /// 吉祥物窗口被完全遮挡时置 false,视图据此停掉动画。
    @Published var mascotVisible: Bool = true
    /// 递增即抖一下 —— 用于 iTerm 跳转失败的无声反馈。
    @Published private(set) var shakeToken: Int = 0

    /// CLI `--watch` 模式用的变更回调。
    var onChange: (() -> Void)?

    /// 一次「刚跑完」。带 sessionId:pid 是会被系统复用的,复用后旧记录必须作废。
    private struct Completion {
        let at: Date
        let sessionId: String?
    }

    private var lastSeen: [Int32: (status: SessionStatus, sessionId: String?)] = [:]
    private var completions: [Int32: Completion] = [:]
    private var announcementSeq = 0
    /// 每个还在等你的 session 上一次被「说出来」的时刻,用来控制催的节奏。
    private var lastNagged: [Int32: Date] = [:]
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
        celebrating = preview.contains { row in
            guard let t = row.completedAt else { return false }
            return now.timeIntervalSince(t) < Self.celebrateWindow
        }
        mascot = MascotState.derive(rows: rows, celebrating: celebrating)
    }

    // MARK: - 扫描 + diff

    func refresh() {
        let result = SessionRegistryReader.scan()
        let now = Date()
        let scanned = merge(result, now: now)

        var justFinished: [SessionInfo] = []
        for s in scanned {
            let prev = lastSeen[s.pid]
            // pid 被复用(同 pid 换了 sessionId):上一条记录跟眼前这个 session 无关,全清。
            if let prev, prev.sessionId != s.sessionId { completions[s.pid] = nil }
            let continuous = prev?.sessionId == s.sessionId

            switch s.status {
            case .idle where continuous && prev?.status == .busy:
                // 注册表里没有 "done" —— busy → idle 就是一轮任务完成。
                completions[s.pid] = Completion(at: now, sessionId: s.sessionId)
                justFinished.append(s)
            case .busy, .waiting:
                // 又开始干活 / 需要介入 —— 上一轮的完成徽标立刻作废。
                completions[s.pid] = nil
            default:
                break
            }
        }

        // 只按时间窗淘汰,**不**按进程存活淘汰:跑完顺手退出 claude 的话 pid 立刻消失,
        // 但那一声「跑完了」照样得说完。
        completions = completions.filter { now.timeIntervalSince($0.value.at) < Self.completedBadgeWindow }
        lastSeen = Dictionary(
            scanned.map { ($0.pid, (status: $0.status, sessionId: $0.sessionId)) },
            uniquingKeysWith: { a, _ in a }
        )

        let newRows = Self.sorted(scanned.map { info in
            SessionRow(info: info, completedAt: completions[info.pid].flatMap {
                $0.sessionId == info.sessionId ? $0.at : nil
            })
        })
        let newCelebrating = completions.values.contains { now.timeIntervalSince($0.at) < Self.celebrateWindow }
        let newMascot = MascotState.derive(rows: newRows, celebrating: newCelebrating)

        let previousAnnouncementID = announcement?.id
        var changed = newRows != rows || newMascot != mascot || newCelebrating != celebrating

        rows = newRows
        celebrating = newCelebrating
        mascot = newMascot
        updateAnnouncement(scanned: scanned, justFinished: justFinished, now: now)
        changed = changed || announcement?.id != previousAnnouncementID

        scheduleNextExpiry(now: now)
        if changed { onChange?() }
    }

    // MARK: - 说话

    /// 决定小狗这一刻该说什么。规则:
    /// 1. 到期的话先收起;
    /// 2. 「在等你」优先 —— 第一次进 waiting 立刻说,一直没人管就每 `nagInterval` 催一次;
    /// 3. 没人等你的时候才轮到「跑完了」,而且不顶掉正在显示的等待提示。
    private func updateAnnouncement(scanned: [SessionInfo], justFinished: [SessionInfo], now: Date) {
        if let current = announcement, now >= current.expiresAt { announcement = nil }

        let waiters = scanned.filter { $0.status == .waiting }
        // 不再等待(或已经退出)的 session 不该保留催促记录 —— 下次再等你时要立刻说。
        let waitingPIDs = Set(waiters.map(\.pid))
        lastNagged = lastNagged.filter { waitingPIDs.contains($0.key) }

        // 已经在说一句「在等你」了就先说完 —— 同时有两个 session 在等的时候,
        // 第二句会在第一句到期后的那次 refresh 里补上,而不是抢在 0.1 秒后闪一下。
        if case .waiting = announcement?.kind { return }

        let due = waiters
            .filter { now.timeIntervalSince(lastNagged[$0.pid] ?? .distantPast) >= Self.nagInterval }
            .min { ($0.statusUpdatedAt ?? .distantPast) < ($1.statusUpdatedAt ?? .distantPast) }

        if let due {
            lastNagged[due.pid] = now
            say(.waiting(due.waitingFor), for: due, duration: Self.waitingBubbleDuration, now: now)
            return
        }

        guard let finished = justFinished.last else { return }
        say(.done, for: finished, duration: Self.doneBubbleDuration, now: now)
    }

    private func say(_ kind: Announcement.Kind, for info: SessionInfo, duration: TimeInterval, now: Date) {
        announcementSeq += 1
        announcement = Announcement(
            id: announcementSeq,
            kind: kind,
            pid: info.pid,
            name: info.displayName,
            expiresAt: now.addingTimeInterval(duration)
        )
    }

    /// 点了气泡 / 跳过去了 —— 立刻闭嘴,别等自然到期。
    func dismissAnnouncement() {
        guard announcement != nil else { return }
        announcement = nil
        scheduleNextExpiry(now: Date())
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

    /// 完成徽标和庆祝动画都是「到点就该变」的状态。与其每秒轮询,
    /// 不如在最近的一个到期时刻排一发一次性定时器。
    private func scheduleNextExpiry(now: Date) {
        expiryTimer?.cancel()
        expiryTimer = nil

        var deadlines: [TimeInterval] = []
        if let staleDeadline { deadlines.append(staleDeadline.timeIntervalSince(now)) }
        if let announcement { deadlines.append(announcement.expiresAt.timeIntervalSince(now)) }
        // 还在等你的 session:到点得再催一次。
        for at in lastNagged.values { deadlines.append(Self.nagInterval - now.timeIntervalSince(at)) }
        for completion in completions.values {
            let age = now.timeIntervalSince(completion.at)
            if age < Self.celebrateWindow { deadlines.append(Self.celebrateWindow - age) }
            if age < Self.completedBadgeWindow { deadlines.append(Self.completedBadgeWindow - age) }
        }
        guard let next = deadlines.min() else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(0.1, next), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        expiryTimer = timer
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
