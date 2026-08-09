import AppKit
import SwiftUI

/// 用 NSPanel 而不是 NSWindow,关键是 `.nonactivatingPanel`:
/// 点小狗不会把焦点从 iTerm 抢走。
final class MascotPanel: NSPanel {
    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: MascotView.side, height: MascotView.side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        // 不能用 .clear:窗口服务器按**画出来的 alpha** 做命中测试,全透明的像素点不到,
        // 会直接穿透到下面那个 app 去 —— 小狗是稀疏的像素画,那样就只有身上几块能点。
        // 铺一层肉眼看不见但 alpha 非零的底,整个 112×112 才都是它的地盘。
        backgroundColor = NSColor(white: 0, alpha: 0.002)
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isFloatingPanel = true
        self.contentView = contentView
        setFrameAutosaveName("PuppyMascot")   // 位置持久化
    }

    // 永远不成为 key/main —— 否则点它就会抢焦点,整个设计就废了。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 没有保存过位置时,默认落在主屏右下角。
    func placeDefaultIfNeeded() {
        if setFrameUsingName("PuppyMascot") { return }
        setFrameOrigin(perches.first ?? .zero)
        saveFrame(usingName: "PuppyMascot")
    }

    // MARK: - 换窝

    private static let perchMargin: CGFloat = 24
    /// 离某个落点多近算「已经蹲在那儿」。拖到中间时不算,这样第一下点击是归位而不是跳过一个角。
    private static let perchSlop: CGFloat = 8

    /// 点击轮转的落点:当前所在屏幕的四角,逆时针从右下角起。
    /// 只在当前屏幕里转 —— 跨屏还是拖过去,免得一下点到看不见的地方。
    var perches: [NSPoint] {
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let m = Self.perchMargin
        let right = visible.maxX - frame.width - m
        let left = visible.minX + m
        let bottom = visible.minY + m
        let top = visible.maxY - frame.height - m
        return [
            NSPoint(x: right, y: bottom),
            NSPoint(x: left, y: bottom),
            NSPoint(x: left, y: top),
            NSPoint(x: right, y: top),
        ]
    }

    /// 蹲到下一个角去。已经被拖到半空中时,先归位到最近的角。
    func hopToNextPerch(completion: @escaping () -> Void) {
        let spots = perches
        guard !spots.isEmpty else { return }
        let here = frame.origin
        let nearest = spots.indices.min {
            hypot(spots[$0].x - here.x, spots[$0].y - here.y) < hypot(spots[$1].x - here.x, spots[$1].y - here.y)
        } ?? 0
        let onPerch = hypot(spots[nearest].x - here.x, spots[nearest].y - here.y) <= Self.perchSlop
        move(to: onPerch ? spots[(nearest + 1) % spots.count] : spots[nearest],
             duration: 0.26,
             completion: completion)
    }

    /// 带动画地挪窝,落地后存位置。动画过程中 didMove 会照常发,气泡栈自己跟得上。
    func move(to origin: NSPoint, duration: TimeInterval, completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrameOrigin(origin)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.saveFrame(usingName: "PuppyMascot")
                completion()
            }
        }
    }
}

/// 小狗的鼠标交互全在这里,SwiftUI 那边一点不掺和 —— NSHostingView 有自己的一套手势/命中测试,
/// 混着用只会让「这一下到底谁收了」变得不可预测。这里就一个普通 NSView 接原始事件:
/// 位移 < 4pt 算点击,否则算拖窗口。
final class MascotContainerView: NSView {
    var onClick: (() -> Void)?
    /// 双击的第一下会先当成单击发出去 —— 处理方要负责把那一下的效果收回来。
    var onDoubleClick: (() -> Void)?

    init<Content: View>(rootView: Content) {
        super.init(frame: NSRect(x: 0, y: 0, width: MascotView.side, height: MascotView.side))
        let hosting = PassthroughHostingView(rootView: rootView)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) 用不到") }

    private var dragOrigin: NSPoint?          // 按下时的鼠标屏幕坐标
    private var windowOrigin: NSPoint?        // 按下时的窗口原点
    private var didDrag = false

    private static let clickSlop: CGFloat = 4

    // app 不在前台时也要第一下就响应,否则每次都得先点一下激活。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = NSEvent.mouseLocation
        windowOrigin = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin, let windowOrigin, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - dragOrigin.x
        let dy = now.y - dragOrigin.y
        if !didDrag && hypot(dx, dy) < Self.clickSlop { return }
        didDrag = true
        window.setFrameOrigin(NSPoint(x: windowOrigin.x + dx, y: windowOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil; windowOrigin = nil }
        if didDrag {
            window?.saveFrame(usingName: "PuppyMascot")
        } else if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            onClick?()
        }
    }
}

/// 只负责画,不接鼠标:命中测试直接返回 nil,事件落到父视图上。
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
