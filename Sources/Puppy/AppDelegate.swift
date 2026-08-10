import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()

    let store = SessionStore()
    private let focuser = ITermFocuser()
    private var mascotPanel: MascotPanel!
    private var listController: SessionListController!
    private var bubbleStack: BubbleStackController!
    /// 单击跳走前的位置 —— 双击的第一下要能撤回。
    private var hopOrigin: NSPoint?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.skin = SkinLibrary.saved()
        store.start()

        listController = SessionListController(store: store) { [weak self] row in
            self?.focus(row)
        }
        // 列表和栈在默认位置下必然互相盖住,而列表本来就含了栈的全部信息 —— 开列表就让栈退场。
        listController.onOpenChange = { [weak self] open in
            self?.bubbleStack?.isSuppressed = open
        }

        let mascot = MascotContainerView(rootView: MascotView(store: store))
        mascot.onClick = { [weak self] in self?.hop() }
        mascot.onDoubleClick = { [weak self] in self?.undoHopThenToggleList() }
        mascot.menu = buildMenu()

        mascotPanel = MascotPanel(contentView: mascot)
        mascotPanel.placeDefaultIfNeeded()
        mascotPanel.orderFrontRegardless()

        // 气泡栈贴着小狗放,所以锚点每次现取。
        bubbleStack = BubbleStackController(
            store: store,
            anchor: { [weak self] in self?.mascotPanel.frame ?? .zero },
            onSelect: { [weak self] pid in self?.focus(pid: pid) },
            onOverflow: { [weak self] in self?.openList() }
        )
        bubbleStack.start()

        // 栈是常驻的,小狗被拖走时得整摞跟过去。
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: mascotPanel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.bubbleStack.relayout() }
        }

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

    /// 单击 = 换窝:蹲到当前屏幕的下一个角。挡住东西时一下就能把它扒拉开,不用瞄准拖。
    private func hop() {
        // 列表是锚在小狗上的,狗跑了它留在原地就成了孤儿 —— 先收起来。
        listController.close()
        hopOrigin = mascotPanel.frame.origin
        mascotPanel.hopToNextPerch { [weak self] in self?.bubbleStack.relayout() }
    }

    /// 双击 = 开列表。双击的第一下已经先跳了一格,这里把它送回去。
    private func undoHopThenToggleList() {
        if let origin = hopOrigin {
            hopOrigin = nil
            mascotPanel.move(to: origin, duration: 0.12) { [weak self] in
                guard let self else { return }
                self.bubbleStack.relayout()
                self.toggleList()   // 列表锚在小狗身上,等它落回原位再开
            }
        } else {
            toggleList()
        }
    }

    private func toggleList() {
        listController.toggle(anchoredTo: mascotPanel.frame)
    }

    /// 点栈顶那条「还有 N 个」—— 完整清单在列表里,只开不关。
    private func openList() {
        listController.open(anchoredTo: mascotPanel.frame)
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
        // 左键让给了「换窝」,列表除了双击还得有个稳的入口。
        menu.addItem(withTitle: "展开列表", action: #selector(showList), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "刷新", action: #selector(refreshNow), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "回到默认位置", action: #selector(resetPosition), keyEquivalent: "")
            .target = self

        let skins = NSMenuItem(title: "形象", action: nil, keyEquivalent: "")
        skins.submenu = skinMenu
        menu.addItem(skins)

        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Puppy", action: #selector(quit), keyEquivalent: "")
            .target = self
        return menu
    }

    /// 每次拉开都重扫磁盘 —— 用户往 ~/.puppy/skins 里丢一套新的,不该还要重启才认。
    private lazy var skinMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }()

    @objc private func chooseSkin(_ sender: NSMenuItem) {
        guard let skin = sender.representedObject as? MascotSkin else { return }
        store.skin = skin
        SkinLibrary.remember(skin)
        bubbleStack.relayout()      // 气泡对准的是脸的高度,换皮肤这个高度就变了
    }

    @objc private func revealSkinFolder() {
        try? FileManager.default.createDirectory(at: SkinLibrary.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(SkinLibrary.root)
    }

    @objc private func exportBuiltInSkin() {
        let target = SkinLibrary.root.appendingPathComponent("pikachu-template", isDirectory: true)
        do {
            try SkinExporter.export(Sprites.builtIn, to: target)
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch {
            store.shake()
        }
    }

    @objc private func showList() { openList() }

    @objc private func refreshNow() { store.refresh() }

    @objc private func resetPosition() {
        guard let home = mascotPanel.perches.first else { return }
        mascotPanel.move(to: home, duration: 0.2) { [weak self] in self?.bubbleStack.relayout() }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// 形象子菜单的内容是每次拉开时现扫的,所以只能在 delegate 里填。
extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === skinMenu else { return }
        menu.removeAllItems()
        for skin in SkinLibrary.all() {
            let item = NSMenuItem(title: skin.name, action: #selector(chooseSkin(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = skin
            item.state = skin.id == store.skin.id ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开皮肤文件夹…", action: #selector(revealSkinFolder), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "导出内置皮肤作模板…", action: #selector(exportBuiltInSkin), keyEquivalent: "")
            .target = self
    }
}
