import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()

    let store = SessionStore()
    private let focuser = ITermFocuser()
    private var mascotPanel: MascotPanel!
    private var listController: SessionListController!
    private var bubbleController: BubbleController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()

        listController = SessionListController(store: store) { [weak self] row in
            self?.focus(row)
        }

        let hosting = MascotHostingView(rootView: MascotView(store: store))
        hosting.onClick = { [weak self] in self?.toggleList() }
        hosting.menu = buildMenu()

        mascotPanel = MascotPanel(contentView: hosting)
        mascotPanel.placeDefaultIfNeeded()
        mascotPanel.orderFrontRegardless()

        // 气泡贴着小狗放,所以锚点每次现取 —— 小狗被拖走了也跟得上。
        bubbleController = BubbleController(
            store: store,
            anchor: { [weak self] in self?.mascotPanel.frame ?? .zero },
            onSelect: { [weak self] pid in self?.focus(pid: pid) }
        )
        bubbleController.start()

        // 被别的窗口完全盖住时停掉动画时钟 —— 这是省电的最后一环。
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: mascotPanel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.mascotVisible = self.mascotPanel.occlusionState.contains(.visible)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    // MARK: - 交互

    private func toggleList() {
        listController.toggle(anchoredTo: mascotPanel.frame)
    }

    private func focus(_ row: SessionRow) {
        listController.close()
        focus(pid: row.info.pid)
    }

    private func focus(pid: Int32) {
        focuser.focus(pid: pid) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .focused, .activatedOnly:
                break   // activatedOnly 是 tmux/ssh 场景的正常降级,不当失败处理
            case .notAuthorized:
                ITermFocuser.openAutomationSettings()
                self.store.shake()
            case .failed:
                // 用户明确要求过:不要弹窗、不要声音。失败就让小狗抖一下。
                self.store.shake()
            }
        }
    }

    // MARK: - 右键菜单(没有 Dock 图标,这是唯一的退出入口)

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "刷新", action: #selector(refreshNow), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "回到默认位置", action: #selector(resetPosition), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Puppy", action: #selector(quit), keyEquivalent: "")
            .target = self
        return menu
    }

    @objc private func refreshNow() { store.refresh() }

    @objc private func resetPosition() {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        let margin: CGFloat = 24
        mascotPanel.setFrameOrigin(NSPoint(x: visible.maxX - mascotPanel.frame.width - margin,
                                           y: visible.minY + margin))
        mascotPanel.saveFrame(usingName: "PuppyMascot")
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
