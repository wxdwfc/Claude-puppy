import Foundation

/// 小狗「说的一句话」。什么时候说、说多久,全由 SessionStore 决定;
/// UI 层只负责把它画成气泡。
///
/// 存在的理由:头顶那个 `!` 只有 6pt,余光里根本注意不到。
/// 真正要人回去处理的事(有 session 在等你 / 一轮跑完了),得让小狗主动说出来。
struct Announcement: Identifiable, Equatable {
    enum Kind: Equatable {
        case waiting(String?)   // 有 session 在等你,附 waitingFor
        case done               // 一轮任务跑完

        var icon: String {
            switch self {
            case .waiting: return "✋"
            case .done: return "✓"
            }
        }
    }

    /// 单调递增。同一个 session 被反复催时,视图靠它认出「这是新的一句」。
    let id: Int
    let kind: Kind
    let pid: Int32
    let name: String
    let expiresAt: Date

    var text: String {
        switch kind {
        case .waiting(let reason): return reason.map { "在等你 · \($0)" } ?? "在等你输入"
        case .done: return "跑完了"
        }
    }

    /// `--watch` 里打一行,方便不开 UI 也能验证时序。
    var debugLine: String { "\(kind.icon) \(name) \(text)" }
}
