import SwiftUI

/// 悬浮吉祥物本体。像素风要「snap」,所以状态切换直接换帧组,不做任何淡入淡出。
///
/// 尺寸相关的量一律从 `store.skin` 现算,不写死 —— 换一套 48 格的皮肤,
/// 起伏幅度和气泡落点会自己跟上。
struct MascotView: View {
    @ObservedObject var store: SessionStore

    /// 画布边长(点)。内置皮肤 32 格 → 每格 3pt。
    static let canvas: CGFloat = 96
    /// 窗口边长:给气泡和跳动留出余量。
    static let side: CGFloat = 112
    /// 画布在窗口里的内缩。
    static let inset: CGFloat = (side - canvas) / 2

    private var skin: MascotSkin { store.skin }
    private var sprite: Sprite { skin.sprite(for: store.mascot) }
    private var cell: CGFloat { Self.canvas / CGFloat(max(skin.side, 1)) }

    /// 身体动画已经在演 celebrating 时,气泡自己就是 ✓,不用再挂一个。
    private var showsDoneBadge: Bool { store.celebrating && store.mascot != .celebrating }

    var body: some View {
        // 鼠标事件全归 MascotContainerView 管,这里一律不参与命中测试。
        ZStack(alignment: .topLeading) {
            if store.mascotVisible {
                TimelineView(.periodic(from: .now, by: 1.0 / max(sprite.fps, 0.1))) { context in
                    frameBody(index: frameIndex(at: context.date))
                }
                // 帧率随状态和皮肤变,必须让 TimelineView 整个重建才能换 schedule。
                .id("\(skin.id)/\(store.mascot.rawValue)")
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
        ZStack(alignment: .topLeading) {
            PixelCanvas(image: sprite.image(at: index), smooth: skin.smooth)
                .frame(width: Self.canvas, height: Self.canvas)
                .offset(x: Self.inset, y: Self.inset + sprite.yOffset(at: index) * cell)

            if let bubble = sprite.bubble {
                MascotBubbleText(bubble, color: sprite.bubbleColor, skin: skin)
            }

            if showsDoneBadge {
                // 跟着帧号点一下头,静止的小勾在余光里太容易漏。
                MascotDoneBadge(bobbing: !index.isMultiple(of: 2), skin: skin)
            }
        }
        .allowsHitTesting(false)
    }

    private func frameIndex(at date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate * sprite.fps) % sprite.frameCount
    }
}

/// 状态气泡("z" / "!")。摊在皮肤指定的那段头顶空地上,文字在里头居中 ——
/// 定宽的框才能保证换个字形也不跑偏。
///
/// 位置由皮肤给,不是写死的角落:皮卡丘的长耳朵把两个上角都占了,挂角上就是
/// 灰 z 压在黑耳尖上,谁也读不出来。
struct MascotBubbleText: View {
    let text: String
    let color: Color
    let skin: MascotSkin

    init(_ text: String, color: Color, skin: MascotSkin) {
        self.text = text
        self.color = color
        self.skin = skin
    }

    var body: some View {
        let cell = MascotView.canvas / CGFloat(max(skin.side, 1))
        let cells = skin.bubbleCells
        Text(text)
            .font(.system(size: 22, weight: .heavy, design: .rounded))
            .foregroundStyle(color)
            .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
            .frame(width: CGFloat(cells.count) * cell, height: 28)
            // 贴着窗口上沿放。画布本身还内缩了 8pt,所以这一格正好落在耳朵最开的那几行之间。
            .offset(x: MascotView.inset + CGFloat(cells.lowerBound) * cell, y: 0)
    }
}

/// ✓ 徽标。要和状态气泡分开挂,两个同时出现时才不打架。
struct MascotDoneBadge: View {
    var bobbing: Bool
    let skin: MascotSkin

    var body: some View {
        let cell = MascotView.canvas / CGFloat(max(skin.side, 1))
        Text("✓")
            .font(.system(size: 18, weight: .heavy, design: .rounded))
            .foregroundStyle(Sprites.doneColor)
            .shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 1)
            .offset(x: MascotView.inset + CGFloat(skin.badgeCell) * cell, y: bobbing ? -3 : 0)
    }
}

/// 画一帧已经烤好的位图。像素皮肤用 `.none` 保证放大后仍是硬边像素;
/// 卡通等高分辨率皮肤(skin.json 里 `"smooth": true`)换平滑插值,缩小时才不出锯齿。
struct PixelCanvas: View {
    let image: CGImage?
    var smooth: Bool = false

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .interpolation(smooth ? .high : .none)
                .antialiased(smooth)
                .resizable()
        }
    }
}
