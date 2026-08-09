import SwiftUI

/// 悬浮小狗本体。像素风要「snap」,所以状态切换直接换帧组,不做任何淡入淡出。
struct MascotView: View {
    @ObservedObject var store: SessionStore

    /// 画布边长(点)。16 格 → 每格 6pt。
    static let canvas: CGFloat = 96
    /// 窗口边长:给气泡和跳动留出余量。
    static let side: CGFloat = 112

    private var sprite: Sprite { Sprites.sprite(for: store.mascot) }

    /// 身体动画已经在演 celebrating 时,气泡自己就是 ✓,不用再挂一个。
    private var showsDoneBadge: Bool { store.celebrating && store.mascot != .celebrating }

    var body: some View {
        // 鼠标事件全归 MascotContainerView 管,这里一律不参与命中测试。
        ZStack(alignment: .topLeading) {
            if store.mascotVisible {
                TimelineView(.periodic(from: .now, by: 1.0 / sprite.fps)) { context in
                    frameBody(index: frameIndex(at: context.date))
                }
                // 帧率随状态变,必须让 TimelineView 整个重建才能换 schedule。
                .id(store.mascot)
            } else {
                // 窗口被完全遮挡:画一帧静态图,彻底停掉动画时钟。
                frameBody(index: 0)
            }
        }
        .frame(width: Self.side, height: Self.side)
        // iTerm 跳转失败时抖一下 —— 用户要求过不要弹窗、不要声音。
        // phaseAnimator 只在 trigger 变化时跑一轮,跑完就静止,不留常驻时钟。
        .phaseAnimator(Self.shakePhases, trigger: store.shakeToken) { content, offset in
            content.offset(x: offset)
        } animation: { _ in .linear(duration: 0.05) }
    }

    private static let shakePhases: [CGFloat] = [0, -7, 7, -5, 5, 0]

    private func frameBody(index: Int) -> some View {
        let yOffset = sprite.yOffset(at: index)
        return ZStack(alignment: .topLeading) {
            PixelCanvas(image: sprite.image(at: index))
                .frame(width: Self.canvas, height: Self.canvas)
                .offset(x: (Self.side - Self.canvas) / 2,
                        y: (Self.side - Self.canvas) / 2 + yOffset * (Self.canvas / CGFloat(Sprites.side)))

            if let bubble = sprite.bubble {
                // 左上角:基础姿势那一片是空的,不会盖住狗。
                Text(bubble)
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(sprite.bubbleColor)
                    .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                    .offset(x: 6, y: 2)
            }

            if showsDoneBadge {
                // 右上角:左上角归状态气泡("!"/"z"),两边分开挂才不会叠在一起。
                // 跟着帧号点一下头,静止的小勾在余光里太容易漏。
                Text("✓")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(Sprites.doneColor)
                    .shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 1)
                    .offset(x: Self.side - 22, y: index.isMultiple(of: 2) ? 0 : -3)
            }
        }
        .allowsHitTesting(false)
    }

    private func frameIndex(at date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate * sprite.fps) % max(1, sprite.frames.count)
    }
}

/// 画一帧已经烤好的位图。`.interpolation(.none)` 保证放大后仍是硬边像素。
struct PixelCanvas: View {
    let image: CGImage?

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .antialiased(false)
                .resizable()
        }
    }
}
