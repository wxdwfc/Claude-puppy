import AppKit
import Combine
import SwiftUI

/// 气泡栈面板。跟列表面板一样是独立的 nonactivating panel —— 点它不会把焦点从 iTerm 抢走。
///
/// 显示与否完全由 `store.bubbles` 驱动:有待办就在,没了就收。这里不持有任何定时器 ——
/// 气泡什么时候该消失是数据层的事(见 `BubbleItem`),UI 只负责画。
///
/// 整摞用**一个** panel 而不是每条一个:条目增删的重排交给 SwiftUI,
/// 透明区域的 hit-test 返回 nil 会自然穿透到下面的窗口。
@MainActor
final class BubbleStackController {
    private let store: SessionStore
    private let panel: NSPanel
    private let anchor: () -> NSRect
    private let onSelect: (Int32) -> Void
    private let onOverflow: () -> Void
    private var cancellable: AnyCancellable?
    private var hosting: FirstMouseHostingView<BubbleStackView>?

    /// 列表面板开着时整摞让位 —— 列表里本来就含了栈的全部信息,而且默认位置下必然互相盖住。
    var isSuppressed = false {
        didSet { if isSuppressed != oldValue { sync() } }
    }

    init(store: SessionStore,
         anchor: @escaping () -> NSRect,
         onSelect: @escaping (Int32) -> Void,
         onOverflow: @escaping () -> Void) {
        self.store = store
        self.anchor = anchor
        self.onSelect = onSelect
        self.onOverflow = onOverflow

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: BubbleStackView.width, height: BubbleStackView.rowHeight),
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
        cancellable = store.$bubbles
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
        sync()
    }

    /// 小狗被拖走了 —— 重新贴上去。
    func relayout() { sync() }

    private func sync() {
        let count = store.bubbles.count
        guard !isSuppressed, count > 0 else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }

        let frame = anchor()
        let tailOnRight = prefersLeftSide(of: frame)
        let view = BubbleStackView(
            store: store,
            tailOnRight: tailOnRight,
            onSelect: onSelect,
            onOverflow: onOverflow
        )
        // hosting view 只建一次。每次重建的话 onAppear 会对**所有**条目重跑,
        // 整摞每分钟(时长标签跳字时)集体弹一次,像抽风。
        if let hosting {
            hosting.rootView = view
        } else {
            let created = FirstMouseHostingView(rootView: view)
            hosting = created
            panel.contentView = created
        }

        layout(tailOnRight: tailOnRight, anchor: frame, itemCount: count)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// 小狗默认蹲在屏幕右下角,所以优先开在左边;左边挤不下才翻到右边。
    private func prefersLeftSide(of anchorFrame: NSRect) -> Bool {
        let visible = screen(for: anchorFrame).visibleFrame
        return anchorFrame.minX - BubbleStackView.width - 4 >= visible.minX
    }

    private func layout(tailOnRight: Bool, anchor anchorFrame: NSRect, itemCount: Int) {
        let visible = screen(for: anchorFrame).visibleFrame
        let width = BubbleStackView.width
        let height = BubbleStackView.height(itemCount: itemCount)
        let overlap: CGFloat = 2      // 尾巴稍微探进小狗一点,看着才是连着的

        var x = tailOnRight
            ? anchorFrame.minX - width + overlap
            : anchorFrame.maxX - overlap
        x = max(visible.minX + 4, min(x, visible.maxX - width - 4))

        // panel 的 y 是底边,所以最下面那条(= 最紧急的)对着脸,整摞往上长。
        // 对着眼睛那一行,不是窗口正中 —— 正中会落到肚子上。
        let headTop = anchorFrame.maxY - MascotView.inset
        let headCenter = headTop - MascotView.canvas * CGFloat(store.skin.headRow) / CGFloat(max(store.skin.side, 1))
        var y = headCenter - BubbleStackView.rowHeight / 2
        // 往上顶出屏幕就整摞下移(小狗被拖到屏幕顶部时)。
        y = max(visible.minY + 4, min(y, visible.maxY - height - 4))

        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private func screen(for rect: NSRect) -> NSScreen {
        NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

/// app 不在前台时也要一下就点中,不能要求先点一下激活。
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
