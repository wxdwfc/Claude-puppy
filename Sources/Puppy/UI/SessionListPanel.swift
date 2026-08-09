import AppKit
import Combine
import SwiftUI

/// 列表面板。刻意不用 NSPopover —— 锚在无边框 nonactivating panel 上的 popover
/// 有一堆焦点/自动消失的怪癖。自己开第二个 panel 更可控。
@MainActor
final class SessionListController {
    private let store: SessionStore
    private let panel: NSPanel
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var cancellable: AnyCancellable?
    private var anchor: NSRect = .zero

    /// 开合都要通知外面 —— 关闭有一半是内部的 event monitor 触发的,调用方看不见。
    var onOpenChange: ((Bool) -> Void)?

    var isOpen: Bool { panel.isVisible }

    init(store: SessionStore, onSelect: @escaping (SessionRow) -> Void) {
        self.store = store
        let hosting = NSHostingView(rootView: SessionListView(store: store, onSelect: onSelect))
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
        panel.contentView = hosting
    }

    func toggle(anchoredTo anchorFrame: NSRect) {
        isOpen ? close() : open(anchoredTo: anchorFrame)
    }

    func open(anchoredTo anchorFrame: NSRect) {
        guard !isOpen else { return }
        anchor = anchorFrame
        layout()
        panel.orderFrontRegardless()
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
        guard panel.isVisible else { return }
        panel.orderOut(nil)
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
