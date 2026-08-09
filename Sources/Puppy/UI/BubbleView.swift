import SwiftUI

/// 小狗嘴边的对话气泡。尾巴朝向小狗那一侧,所以方向由外部给。
/// 点一下 = 跳到那个 session 的 iTerm 窗口。
struct BubbleView: View {
    let announcement: Announcement
    /// true = 气泡在小狗左边(尾巴朝右);false = 在右边(尾巴朝左)。
    let tailOnRight: Bool
    var onTap: () -> Void = {}

    static let bodyWidth: CGFloat = 210
    static let tailWidth: CGFloat = 8
    static let height: CGFloat = 54
    /// panel 要开多宽 —— 含尾巴。
    static var width: CGFloat { bodyWidth + tailWidth }

    /// 弹出动画。静止出现的东西在余光里跟没出现一样。
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 0) {
            if !tailOnRight { tail }
            body(for: announcement)
            if tailOnRight { tail }
        }
        .frame(width: Self.width, height: Self.height)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .scaleEffect(appeared ? 1 : 0.9, anchor: tailOnRight ? .trailing : .leading)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.65)) { appeared = true }
        }
    }

    private func body(for announcement: Announcement) -> some View {
        HStack(spacing: 9) {
            Text(announcement.kind.icon)
                .font(.system(size: 16))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(announcement.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // 正文一律用 .primary(浅色外观下就是黑):彩色小字压在毛玻璃上太糊。
                // 状态的颜色信号交给左边的图标。
                Text(announcement.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .frame(width: Self.bodyWidth, height: Self.height)
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
            .frame(width: Self.tailWidth, height: 14)
    }

    private var tint: Color {
        switch announcement.kind {
        case .waiting: return Color(red: 0.95, green: 0.45, blue: 0.30)
        case .done: return Sprites.doneColor
        }
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
