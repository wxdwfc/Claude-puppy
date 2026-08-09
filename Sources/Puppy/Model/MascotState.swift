import Foundation

/// 吉祥物的**身体动画**。优先级:alert > working > celebrating > sleeping。
///
/// 注意 celebrating 排在 working 后面 —— 并行开多个 session 时,A 跑完的那一刻
/// B 还在跑,身体就该继续小跑。「刚完成」这件事由 `SessionStore.celebrating`
/// 单独驱动一个 ✓ 徽标(见 MascotView),不跟身体动画抢位置,否则永远显示不出来。
enum MascotState: String, Equatable {
    case alert          // 有 session 在等用户
    case working        // 有 session 在跑
    case celebrating    // 刚有 session 完成,且没有别的活
    case sleeping       // 全空闲 / 没有 session

    static func derive(rows: [SessionRow], celebrating: Bool) -> MascotState {
        if rows.contains(where: { if case .waiting = $0.info.status { return true } else { return false } }) {
            return .alert
        }
        if rows.contains(where: { $0.info.status == .busy }) {
            return .working
        }
        return celebrating ? .celebrating : .sleeping
    }
}
