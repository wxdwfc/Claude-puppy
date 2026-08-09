import Foundation

/// 栈里的一条气泡。**完全由 `SessionRow` 派生**,没有「已读」标记也没有自己的到期时钟:
///
///     栈 ≡ { row | row.display ∈ (.waiting, .completed) }
///
/// 于是屏幕上看到的严格等于真实待办 —— 不可能出现「关掉了但其实没处理」。
///
/// 存在的理由:先前是单条瞬时气泡,本质是「刚发生了什么」的通道,却被当成待办清单用。
/// 同时有几件事要你处理时后一句顶掉前一句,处理完一个也想不起来还有别的。
struct BubbleItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case waiting(String?)   // 在等你,附 waitingFor
        case done               // 一轮跑完了。限时,跟着 `completedBadgeWindow` 一起消失

        var icon: String {
            switch self {
            case .waiting: return "✋"
            case .done: return "✓"
            }
        }
    }

    let pid: Int32
    let kind: Kind
    let name: String
    /// 「40m」。分钟级 —— 秒级要一个 1Hz 时钟,而这是个 24h 挂着的常驻窗口。
    /// 不满一分钟为 nil:刚冒出来就顶个「0m」既没信息量又多一次重绘。
    let ageLabel: String?

    var id: Int32 { pid }

    /// 这一行不该出现在栈里就返回 nil —— 唯一的准入判定,别处不要再抄一份。
    init?(row: SessionRow, now: Date) {
        switch row.display {
        case .waiting(let reason): kind = .waiting(reason)
        case .completed: kind = .done
        case .busy, .idle, .other: return nil
        }
        pid = row.info.pid
        name = row.info.displayName
        ageLabel = row.stateDuration(now: now).flatMap(Self.age(_:))
    }

    var text: String {
        switch kind {
        case .waiting(let reason): return reason.map { "在等你 · \($0)" } ?? "在等你输入"
        case .done: return "跑完了"
        }
    }

    /// `--watch` 里打一行,方便不开 UI 也能验证栈的内容。
    var debugLine: String {
        "\(kind.icon) \(name) \(text)" + (ageLabel.map { " · \($0)" } ?? "")
    }

    private static func age(_ seconds: TimeInterval) -> String? {
        let minutes = Int(seconds) / 60
        guard minutes >= 1 else { return nil }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h\(minutes % 60)m"
    }
}
