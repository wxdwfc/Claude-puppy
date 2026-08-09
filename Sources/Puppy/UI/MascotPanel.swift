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
        backgroundColor = .clear
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
        guard let visible = NSScreen.main?.visibleFrame else { return }
        let margin: CGFloat = 24
        setFrameOrigin(NSPoint(x: visible.maxX - frame.width - margin,
                               y: visible.minY + margin))
        saveFrame(usingName: "PuppyMascot")
    }
}

/// SwiftUI 的 hosting view 会吞掉 mouseDown,所以 `isMovableByWindowBackground` 在这里不管用。
/// 干脆自己接管:位移 < 4pt 算点击,否则算拖窗口。
final class MascotHostingView<Content: View>: NSHostingView<Content> {
    var onClick: (() -> Void)?

    private var dragOrigin: NSPoint?          // 按下时的鼠标屏幕坐标
    private var windowOrigin: NSPoint?        // 按下时的窗口原点
    private var didDrag = false

    private static var clickSlop: CGFloat { 4 }

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
        } else {
            onClick?()
        }
    }
}
