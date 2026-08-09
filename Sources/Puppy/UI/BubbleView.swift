import SwiftUI

/// 小狗身边那摞气泡。
///
/// 顺序沿用 `SessionStore.sorted` —— **贴着小狗的那一格给等最久的**,往上依次递减紧急度。
/// 于是处理完最紧急的一个,下一个会自动滑到狗嘴边;溢出的那几个折在最上面(最不紧急那端)。
///
/// 只有最靠近小狗的那一条画尾巴:每条都长一根尾巴看着像一排箭头,不像一只狗在说话。
struct BubbleStackView: View {
    @ObservedObject var store: SessionStore
    /// true = 整摞在小狗左边(尾巴朝右);false = 在右边(尾巴朝左)。
    let tailOnRight: Bool
    var onSelect: (Int32) -> Void = { _ in }
    var onOverflow: () -> Void = {}
    /// 离屏渲染(`--render`)时关掉弹入动画 —— ImageRenderer 不跑 onAppear,不关就渲染出空白。
    var animated: Bool = true

    static let bodyWidth: CGFloat = 210
    static let tailWidth: CGFloat = 8
    static let rowHeight: CGFloat = 54
    static let overflowHeight: CGFloat = 26
    static let spacing: CGFloat = 4
    /// 超过这个数就折成一条「还有 N 个」。5 条约 300pt,右下角还塞得下。
    static let maxVisible = 5

    /// panel 要开多宽 —— 含尾巴。
    static var width: CGFloat { bodyWidth + tailWidth }

    /// panel 要开多高。BubbleStackController 用它算窗口 frame。
    static func height(itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        let shown = min(maxVisible, itemCount)
        var total = CGFloat(shown) * rowHeight + CGFloat(shown - 1) * spacing
        if itemCount > maxVisible { total += spacing + overflowHeight }
        return total
    }

    var body: some View {
        let shown = Array(store.bubbles.prefix(Self.maxVisible))
        let hidden = store.bubbles.count - shown.count

        // VStack 从上往下排,而栈是从小狗那头往上长 —— 所以最紧急的(数组第一个)要放最后。
        VStack(alignment: alignment, spacing: Self.spacing) {
            if hidden > 0 {
                OverflowChip(count: hidden)
                    .onTapGesture(perform: onOverflow)
            }
            ForEach(shown.reversed()) { item in
                BubbleView(item: item,
                           tailOnRight: tailOnRight,
                           hasTail: item.id == shown.first?.id,
                           animated: animated)
                    .onTapGesture { onSelect(item.pid) }
            }
        }
        .frame(width: Self.width, alignment: tailOnRight ? .leading : .trailing)
    }

    /// 尾巴在右 → 本体一律左对齐,右边那 8pt 留给尾巴(只有最下面一条用得上)。
    private var alignment: HorizontalAlignment { tailOnRight ? .leading : .trailing }
}

/// 栈里的一条。点一下 = 跳到那个 session 的 iTerm 窗口。
///
/// 注意跳过去**不会**让它消失 —— 它只跟 `row.display` 走,你没真回答它就还在。
struct BubbleView: View {
    let item: BubbleItem
    /// true = 气泡在小狗左边(尾巴朝右);false = 在右边(尾巴朝左)。
    let tailOnRight: Bool
    /// 只有最靠近小狗的那一条为 true。
    var hasTail: Bool = true
    var animated: Bool = true

    /// 弹出动画。静止出现的东西在余光里跟没出现一样。
    @State private var appeared = false

    private var visible: Bool { !animated || appeared }

    var body: some View {
        HStack(spacing: 0) {
            if !tailOnRight && hasTail { tail }
            card
            if tailOnRight && hasTail { tail }
        }
        .frame(height: BubbleStackView.rowHeight)
        .contentShape(Rectangle())
        .scaleEffect(visible ? 1 : 0.9, anchor: tailOnRight ? .trailing : .leading)
        .opacity(visible ? 1 : 0)
        .onAppear {
            guard animated else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.65)) { appeared = true }
        }
    }

    private var card: some View {
        HStack(spacing: 9) {
            Text(item.kind.icon)
                .font(.system(size: 16))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                    // 挂久了的和刚冒出来的,不给个时长根本分不出来 —— 尤其在它永远不会自己消失之后。
                    if let age = item.ageLabel {
                        Text(age)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                // 正文一律用 .primary(浅色外观下就是黑):彩色小字压在毛玻璃上太糊。
                // 状态的颜色信号交给左边的图标。
                Text(item.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 11)
        .frame(width: BubbleStackView.bodyWidth, height: BubbleStackView.rowHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    /// 尾巴单独画一个三角:跟气泡本体同一种材质,拼在一起看不出接缝。
    private var tail: some View {
        Triangle(pointsRight: tailOnRight)
            .fill(.regularMaterial)
            .frame(width: BubbleStackView.tailWidth, height: 14)
    }

    private var tint: Color {
        switch item.kind {
        case .waiting: return Color(red: 0.95, green: 0.45, blue: 0.30)
        case .done: return Sprites.doneColor
        }
    }
}

/// 「还有 N 个 ›」。点它开列表面板 —— 完整清单本来就在那儿,不必在栈里重复一遍。
private struct OverflowChip: View {
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("还有 \(count) 个")
                .font(.system(size: 11, weight: .medium))
            Text("›")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .frame(width: BubbleStackView.bodyWidth, height: BubbleStackView.overflowHeight)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .contentShape(Capsule())
    }
}

private struct Triangle: Shape {
    let pointsRight: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if pointsRight {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}
