import AppKit
import Combine
import SwiftUI

/// 列表面板。刻意不用 NSPopover —— 锚在无边框 nonactivating panel 上的 popover
/// 有一堆焦点/自动消失的怪癖。自己开第二个 panel 更可控。
///
/// 跟气泡栈一样,窗口从头到尾 ordered in,开合只改 alpha —— 理由见 `BubbleStackController.start()`。
@MainActor
final class SessionListController {
    private let store: SessionStore
    private let onSelect: (SessionRow) -> Void
    private let panel: NSPanel
    private let hosting: NSHostingView<SessionListView>
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var cancellable: AnyCancellable?
    private var anchor: NSRect = .zero

    /// 开合都要通知外面 —— 关闭有一半是内部的 event monitor 触发的,调用方看不见。
    var onOpenChange: ((Bool) -> Void)?

    /// 显式状态,不从 `panel.isVisible` 反推:窗口现在一直是 visible 的,
    /// 而且「以为开着其实没开」会让气泡栈被永久压住(`isSuppressed` 再也回不去 false)。
    private(set) var isOpen = false

    init(store: SessionStore, onSelect: @escaping (SessionRow) -> Void) {
        self.store = store
        self.onSelect = onSelect
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: SessionListView.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        // 关着的时候是一块透明浮空窗:别挡住底下 iTerm 的点击。
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        hosting = NSHostingView(rootView: Self.view(store: store, onSelect: onSelect, live: false))
        hosting.sizingOptions = []      // 窗口尺寸只由 layout() 说了算
        panel.contentView = hosting
        panel.orderFrontRegardless()
    }

    /// 关着的时候用**冻结**版:`SessionListView` 里那个每秒刷新的 `TimelineView` 只在开着时存在,
    /// 常驻状态下不会有任何定时唤醒。
    private static func view(store: SessionStore,
                             onSelect: @escaping (SessionRow) -> Void,
                             live: Bool) -> SessionListView {
        SessionListView(store: store, onSelect: onSelect, frozenNow: live ? nil : Date())
    }

    func toggle(anchoredTo anchorFrame: NSRect) {
        isOpen ? close() : open(anchoredTo: anchorFrame)
    }

    func open(anchoredTo anchorFrame: NSRect) {
        guard !isOpen else { return }
        isOpen = true
        anchor = anchorFrame
        hosting.rootView = Self.view(store: store, onSelect: onSelect, live: true)
        layout()
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
        if !panel.isVisible { panel.orderFrontRegardless() }    // 兜底,正常情况下一直是 visible
        onOpenChange?(true)

        // 面板开着时行数会变(session 来去),高度得跟着变。
        cancellable = store.$rows
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layout() }

        // global monitor 收不到本 app 的事件,所以还要一个 local 的。
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            // 点在面板或小狗身上不关 —— 小狗的开合由它自己的 onClick 负责。
            if event.window !== self.panel && !(event.window is MascotPanel) {
                self.close()
            }
            return event
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        hosting.rootView = Self.view(store: store, onSelect: onSelect, live: false)
        cancellable?.cancel(); cancellable = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        onOpenChange?(false)
    }

    /// 贴着小狗放;顶到屏幕边缘就翻到另一侧。
    private func layout() {
        let height = SessionListView.height(rowCount: store.rows.count)
        let width = SessionListView.width
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 6

        // 默认开在小狗下方;下方放不下就翻到上方。
        var y = anchor.minY - gap - height
        if y < visible.minY {
            y = anchor.maxY + gap
            if y + height > visible.maxY {
                y = max(visible.minY, min(anchor.midY - height / 2, visible.maxY - height))
            }
        }

        var x = anchor.midX - width / 2
        x = max(visible.minX + 4, min(x, visible.maxX - width - 4))

        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}
