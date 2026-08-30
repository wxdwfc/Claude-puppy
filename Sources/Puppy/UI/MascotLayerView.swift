import AppKit
import Combine
import SwiftUI

/// 吉祥物窗口里那点尺寸常量。视图和面板布局都从这儿取,不各写各的。
enum MascotMetrics {
    /// 画布边长(点)。内置皮肤 32 格 → 每格 3pt。
    static let canvas: CGFloat = 96
    /// 窗口边长:给气泡和跳动留出余量。
    static let side: CGFloat = 112
    /// 画布在窗口里的内缩。
    static let inset: CGFloat = (side - canvas) / 2

    /// 一格是多少点。跟着皮肤走,不写死 —— 换一套 48 格的皮肤,起伏幅度会自己跟上。
    static func cell(_ skin: MascotSkin) -> CGFloat { canvas / CGFloat(max(skin.side, 1)) }
}

/// 悬浮吉祥物本体。像素风要「snap」,所以状态切换直接换帧组,不做任何淡入淡出。
///
/// **这里是 CALayer + CAKeyframeAnimation,不是 SwiftUI —— 纯粹为了省电。**
/// 上一版用 `TimelineView(.periodic)` 逐帧驱动:每一帧都要重求值整棵 SwiftUI 树、
/// 跑一遍 `NSHostingView.layout()`(连带整个 window 的 AutoLayout subtree)、提交一次
/// CA transaction。实测 working 态(5fps)下常驻 2.4% CPU、~35 次/秒 idle wakeup,
/// 而 `sample` 出来的热点 100% 在这条路径上,一点没花在扫目录 / 读 JSON 上。
///
/// 但这个动画恰恰是最适合交给 CA 的那一类:帧图在构造 `Sprite` 时就烤成了 CGImage,
/// 偏移量是定死的数组,循环无限长,不依赖任何运行时数据。所以把整段循环一次性声明给
/// CA,之后由 render server 自己播 —— app 进程完全不参与逐帧,唤醒降到 0。
///
/// 代价是所有摆位得手写:CA 用的是 y 向上的坐标系(view 没 flip),
/// 而原来的 SwiftUI 代码是 topLeading + y 向下,两边的换算都在 `rebuild` 里标了。
@MainActor
final class MascotLayerView: NSView {

    private let store: SessionStore
    private var cancellables: Set<AnyCancellable> = []

    /// 所有内容都挂在这一层上,而不是直接挂 backing layer:
    /// 抖动动的是这一层的 position,动 backing layer 会被 AppKit 的布局重置掉。
    private let contentLayer = CALayer()
    private let bodyLayer = CALayer()
    private var bubbleLayer: CATextLayer?
    private var badgeLayer: CATextLayer?

    /// 重建的去重键。`sync` 每次变更都会被叫到,但只有这几样真变了才值得重排动画 ——
    /// 重排会把循环拨回第 0 帧,虽然看不出来,也没必要白做。
    private struct Signature: Equatable {
        let skinID: String
        let state: MascotState
        let badge: Bool
        let animating: Bool
        let fps: Double
    }
    private var signature: Signature?

    init(store: SessionStore) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: MascotMetrics.side, height: MascotMetrics.side))
        wantsLayer = true
        layer?.masksToBounds = false
        contentLayer.frame = bounds
        contentLayer.masksToBounds = false
        layer?.addSublayer(contentLayer)
        contentLayer.addSublayer(bodyLayer)

        subscribe()
        sync(force: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 用不到") }

    /// 鼠标事件全归 MascotContainerView 管,这里一律不参与命中测试。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard contentLayer.frame != bounds else { return }   // 别去动正在抖的那一层
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.frame = bounds
        CATransaction.commit()
    }

    /// 挪到 Retina / 非 Retina 屏之间时字和位图都要重烤。
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        sync(force: true)
    }

    // MARK: - 订阅

    private func subscribe() {
        // `@Published` 的 sink 是在 willSet 里发的,直接读 store 会拿到旧值 ——
        // 绕一圈 RunLoop.main 再读,跟 BubblePanel / SessionListPanel 的做法一致。
        Publishers.MergeMany(
            store.$mascot.map { _ in () }.eraseToAnyPublisher(),
            store.$celebrating.map { _ in () }.eraseToAnyPublisher(),
            store.$skin.map { _ in () }.eraseToAnyPublisher(),
            store.$mascotVisible.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.sync() }
        .store(in: &cancellables)

        store.$shakeToken
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.shake() }
            .store(in: &cancellables)

        // 低电量模式下把帧率压到 2 —— 进程这边已经不花 CPU 了,但每一帧仍要 WindowServer
        // 重合成一次悬浮窗,省下来的是那一份。
        NotificationCenter.default
            .publisher(for: NSNotification.Name.NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
    }

    private static let lowPowerFPSCap: Double = 2

    private func effectiveFPS(_ fps: Double) -> Double {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? min(fps, Self.lowPowerFPSCap) : fps
    }

    // MARK: - 重建

    private func sync(force: Bool = false) {
        let skin = store.skin
        let state = store.mascot
        let sprite = skin.sprite(for: state)
        // 身体动画已经在演 celebrating 时,气泡自己就是 ✓,不用再挂一个。
        let badge = store.celebrating && state != .celebrating
        let fps = effectiveFPS(sprite.fps)
        // 窗口被完全盖住(息屏 / 锁屏也算)就一帧静态图,连 CA 的循环都不挂。
        let animating = store.mascotVisible && sprite.frameCount > 1

        let next = Signature(skinID: skin.id, state: state, badge: badge, animating: animating, fps: fps)
        guard force || next != signature else { return }
        signature = next
        rebuild(skin: skin, sprite: sprite, badge: badge, animating: animating, fps: fps)
    }

    private func rebuild(skin: MascotSkin, sprite: Sprite, badge: Bool, animating: Bool, fps: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let cell = MascotMetrics.cell(skin)
        let scale = window?.backingScaleFactor ?? 2
        let duration = Double(sprite.frameCount) / max(fps, 0.1)

        // --- 身体 ---
        bodyLayer.removeAllAnimations()
        bodyLayer.contentsScale = scale
        // 像素皮肤要硬边;卡通等高分辨率皮肤(skin.json 里 "smooth": true)缩小时才不出锯齿。
        bodyLayer.magnificationFilter = skin.smooth ? .linear : .nearest
        bodyLayer.minificationFilter = skin.smooth ? .linear : .nearest
        bodyLayer.allowsEdgeAntialiasing = skin.smooth
        bodyLayer.bounds = CGRect(x: 0, y: 0, width: MascotMetrics.canvas, height: MascotMetrics.canvas)
        bodyLayer.contents = sprite.image(at: 0)
        bodyLayer.position = bodyPosition(yOffset: sprite.yOffset(at: 0), cell: cell)

        if animating {
            let frames = (0..<sprite.frameCount).compactMap { sprite.image(at: $0) }
            if frames.count == sprite.frameCount {
                bodyLayer.add(Self.discrete("contents", values: frames, duration: duration), forKey: "frames")
            }
            let positions = (0..<sprite.frameCount).map {
                NSValue(point: bodyPosition(yOffset: sprite.yOffset(at: $0), cell: cell))
            }
            if Set(positions).count > 1 {
                bodyLayer.add(Self.discrete("position", values: positions, duration: duration), forKey: "bob")
            }
        }

        // --- 头顶状态气泡("z" / "!" / "✓")---
        bubbleLayer?.removeFromSuperlayer()
        bubbleLayer = nil
        if let text = sprite.bubble {
            // 摊在皮肤指定的那段头顶空地上,定宽居中 —— 皮卡丘的长耳朵把两个上角都占了,
            // 挂角上就是灰 z 压在黑耳尖上,谁也读不出来。
            let cells = skin.bubbleCells
            let box = CGRect(x: MascotMetrics.inset + CGFloat(cells.lowerBound) * cell,
                             y: MascotMetrics.side - 28,
                             width: CGFloat(cells.count) * cell,
                             height: 28)
            let layer = Self.textLayer(text, size: 22, color: sprite.bubbleColor,
                                       shadowOpacity: 0.35, centeredIn: box, scale: scale)
            contentLayer.addSublayer(layer)
            bubbleLayer = layer
        }

        // --- ✓ 徽标 ---
        badgeLayer?.removeFromSuperlayer()
        badgeLayer = nil
        if badge {
            let layer = Self.textLayer("✓", size: 18, color: Sprites.doneColor,
                                       shadowOpacity: 0.45,
                                       topLeftAt: CGPoint(x: MascotMetrics.inset + CGFloat(skin.badgeCell) * cell,
                                                          y: MascotMetrics.side),
                                       scale: scale)
            contentLayer.addSublayer(layer)
            badgeLayer = layer

            // 跟着帧号点一下头,静止的小勾在余光里太容易漏。
            if animating {
                let base = layer.position
                let bobs = (0..<sprite.frameCount).map { index -> NSValue in
                    NSValue(point: CGPoint(x: base.x, y: base.y + (index.isMultiple(of: 2) ? 0 : 3)))
                }
                if Set(bobs).count > 1 {
                    layer.add(Self.discrete("position", values: bobs, duration: duration), forKey: "bob")
                }
            }
        }
    }

    /// SwiftUI 那版是 topLeading + `.offset(y: inset + yOffset * cell)`,y 向下为正;
    /// 这里是 y 向上,所以 yOffset 要反号。
    private func bodyPosition(yOffset: Double, cell: CGFloat) -> CGPoint {
        CGPoint(x: MascotMetrics.side / 2,
                y: MascotMetrics.side / 2 - CGFloat(yOffset) * cell)
    }

    // MARK: - 抖一下

    /// iTerm 跳转失败时的无声反馈 —— 用户要求过不要弹窗、不要声音。
    /// 一次性动画,跑完就没了,不留常驻时钟。
    private static let shakePhases: [CGFloat] = [0, -7, 7, -5, 5, 0]

    private func shake() {
        let base = contentLayer.position
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = Self.shakePhases.map { base.x + $0 }
        animation.keyTimes = (0..<Self.shakePhases.count).map {
            NSNumber(value: Double($0) / Double(Self.shakePhases.count - 1))
        }
        animation.calculationMode = .linear
        animation.duration = 0.05 * Double(Self.shakePhases.count - 1)
        contentLayer.add(animation, forKey: "shake")
    }

    // MARK: - 小工具

    /// 无限循环的逐帧动画。`.discrete` 下 keyTimes 要比 values 多一个 —— 每个值管一段区间。
    private static func discrete(_ keyPath: String, values: [Any], duration: Double) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = (0...values.count).map { NSNumber(value: Double($0) / Double(values.count)) }
        animation.calculationMode = .discrete
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }

    private static func attributed(_ text: String, size: CGFloat, color: Color) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: size, weight: .heavy)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor(color),
        ])
    }

    private static func makeTextLayer(_ string: NSAttributedString, shadowOpacity: Float,
                                      scale: CGFloat) -> CATextLayer {
        let layer = CATextLayer()
        layer.string = string
        layer.contentsScale = scale
        layer.alignmentMode = .center
        layer.isWrapped = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = shadowOpacity
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: -1)   // SwiftUI 的 y:1 是向下
        return layer
    }

    /// 在 `box` 里居中(横竖都居中,SwiftUI 的 `.frame(width:height:)` 默认就是这个)。
    private static func textLayer(_ text: String, size: CGFloat, color: Color, shadowOpacity: Float,
                                  centeredIn box: CGRect, scale: CGFloat) -> CATextLayer {
        let string = attributed(text, size: size, color: color)
        let layer = makeTextLayer(string, shadowOpacity: shadowOpacity, scale: scale)
        let measured = string.size()
        layer.frame = CGRect(x: box.midX - measured.width / 2,
                             y: box.midY - measured.height / 2,
                             width: ceil(measured.width),
                             height: ceil(measured.height))
        return layer
    }

    /// 左上角对齐到 `topLeft`(y 是**上边沿**,对应 SwiftUI 的 topLeading)。
    private static func textLayer(_ text: String, size: CGFloat, color: Color, shadowOpacity: Float,
                                  topLeftAt topLeft: CGPoint, scale: CGFloat) -> CATextLayer {
        let string = attributed(text, size: size, color: color)
        let layer = makeTextLayer(string, shadowOpacity: shadowOpacity, scale: scale)
        let measured = string.size()
        layer.frame = CGRect(x: topLeft.x,
                             y: topLeft.y - ceil(measured.height),
                             width: ceil(measured.width),
                             height: ceil(measured.height))
        return layer
    }
}
