import AppKit
import Combine
import SwiftUI

/// 气泡面板。跟列表面板一样是独立的 nonactivating panel —— 点它不会把焦点从 iTerm 抢走。
///
/// 显示与否完全由 `store.announcement` 驱动:store 说话就弹,说完(到期)就收。
/// 这里不持有任何定时器,免得跟数据层的到期逻辑各算各的。
@MainActor
final class BubbleController {
    private let store: SessionStore
    private let panel: NSPanel
    private let anchor: () -> NSRect
    private let onSelect: (Int32) -> Void
    private var cancellable: AnyCancellable?

    init(store: SessionStore, anchor: @escaping () -> NSRect, onSelect: @escaping (Int32) -> Void) {
        self.store = store
        self.anchor = anchor
        self.onSelect = onSelect

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: BubbleView.width, height: BubbleView.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
    }

    func start() {
        cancellable = store.$announcement
            .removeDuplicates { $0?.id == $1?.id }
            .receive(on: RunLoop.main)
            .sink { [weak self] announcement in
                guard let self else { return }
                if let announcement { self.show(announcement) } else { self.hide() }
            }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func show(_ announcement: Announcement) {
        let frame = anchor()
        let tailOnRight = prefersLeftSide(of: frame)
        let view = BubbleView(announcement: announcement, tailOnRight: tailOnRight) { [weak self] in
            guard let self else { return }
            self.store.dismissAnnouncement()
            self.onSelect(announcement.pid)
        }
        // 每次重建 hosting view,而不是换 rootView:这样 onAppear 会再跑一遍,
        // 弹出动画每一句话都有。反正一句话才建一次,不心疼。
        panel.contentView = FirstMouseHostingView(rootView: view)
        layout(tailOnRight: tailOnRight, anchor: frame)
        panel.orderFrontRegardless()
    }

    /// 小狗默认蹲在屏幕右下角,所以优先开在左边;左边挤不下才翻到右边。
    private func prefersLeftSide(of anchorFrame: NSRect) -> Bool {
        let visible = screen(for: anchorFrame).visibleFrame
        return anchorFrame.minX - BubbleView.width - 4 >= visible.minX
    }

    private func layout(tailOnRight: Bool, anchor anchorFrame: NSRect) {
        let visible = screen(for: anchorFrame).visibleFrame
        let overlap: CGFloat = 2      // 尾巴稍微探进小狗一点,看着才是连着的

        var x = tailOnRight
            ? anchorFrame.minX - BubbleView.width + overlap
            : anchorFrame.maxX - overlap
        x = max(visible.minX + 4, min(x, visible.maxX - BubbleView.width - 4))

        // 对着狗头的高度,不是窗口正中 —— 16 格里头大概在第 5 格。
        let headTop = anchorFrame.maxY - (MascotView.side - MascotView.canvas) / 2
        let headCenter = headTop - MascotView.canvas * 5 / CGFloat(Sprites.side)
        var y = headCenter - BubbleView.height / 2
        y = max(visible.minY + 4, min(y, visible.maxY - BubbleView.height - 4))

        panel.setFrame(NSRect(x: x, y: y, width: BubbleView.width, height: BubbleView.height), display: true)
    }

    private func screen(for rect: NSRect) -> NSScreen {
        NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

/// app 不在前台时也要一下就点中,不能要求先点一下激活。
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
