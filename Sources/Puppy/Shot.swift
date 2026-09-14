import AppKit
import SwiftUI

/// `--shot <file>`:离屏渲出 README 里那张图。
///
/// 不是屏幕截图 —— 真去截屏要 Screen Recording 授权,还会把桌面上碰巧开着的东西一起拍进去,
/// 换台机器就再也复现不了。这里直接把**真视图**(`BubbleStackView` / `SessionListView` /
/// 皮肤的某一帧)按 `BubbleStackController.layout` 和 `SessionListController.layout`
/// 算出来的同一套坐标摆进一块画布,所以它跟真窗口逐点一致,而且谁都能重跑。
@MainActor
enum Shot {

    static func render(to path: String, skinID: String? = nil) {
        _ = NSApplication.shared          // SwiftUI 离屏渲染要求 AppKit 已初始化

        let skin = skinID.flatMap { id in SkinLibrary.all().first { $0.id == id } }
            ?? SkinLibrary.saved()
        let store = SessionStore()
        store.skin = skin
        store.installPreviewRows(sampleRows())

        let renderer = ImageRenderer(content: ShotView(store: store, skin: skin))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("渲染失败\n".utf8))
            exit(1)
        }

        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try png.write(to: url)
            print("已写出 \(url.path)(\(rep.pixelsWide)×\(rep.pixelsHigh))")
        } catch {
            FileHandle.standardError.write(Data("写不出 \(url.path):\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// 两幅场景共用这一组 session —— 左边那摞是右边这张表的子集(`{ 在等你 } ∪ { 刚跑完 }`),
    /// 用同一份数据才看得出这层关系。
    private static func sampleRows() -> [SessionRow] {
        let now = Date()
        return [
            row(41207, "puppy", .waiting, "permission prompt", ago: 194, now: now),
            row(41533, "agentic-research", .waiting, "审批请求", ago: 71, now: now, provider: .codex),
            row(40988, "cse-csp-lecture", .busy, ago: 42, now: now),
            row(41890, "paper-osdi", .idle, ago: 9, now: now, completed: true,
                note: "评审意见都回完了,主要改了 §4 的实验设置", provider: .codex),
            row(39104, "dotfiles", .idle, ago: 5400, now: now),
        ]
    }

    private static func row(_ pid: Int32, _ name: String, _ status: SessionStatus,
                            _ waiting: String? = nil, ago: TimeInterval, now: Date,
                            completed: Bool = false, note: String? = nil,
                            provider: SessionProvider = .claude) -> SessionRow {
        // cwd 拼在真实 home 底下,`shortCwd` 才折得成 `~/lab/...`。
        let info = SessionInfo(
            provider: provider,
            pid: pid, sessionId: "shot-\(pid)",
            cwd: "\(NSHomeDirectory())/lab/personal/\(name)", name: name,
            kind: "interactive", entrypoint: "cli", version: "2.1.226",
            status: status, waitingFor: waiting,
            startedAt: now.addingTimeInterval(-7200),
            statusUpdatedAt: now.addingTimeInterval(-ago)
        )
        let at = now.addingTimeInterval(-ago)
        return SessionRow(
            info: info,
            completedAt: completed ? at : nil,
            note: note.map { SidecarNote(sessionId: "shot-\(pid)", summary: $0, abnormal: nil, at: at) })
    }
}

/// 一整张图:两幅「桌面右下角」并排,底边对齐 —— 两只小狗蹲在同一条地平线上。
private struct ShotView: View {
    @ObservedObject var store: SessionStore
    let skin: MascotSkin

    /// 一幅场景多宽:塞得下「气泡栈 + 小狗 + 两边留白」。
    /// 高度两幅各算各的,底边对齐 —— 两只小狗蹲在同一条地平线上。
    static let sceneWidth: CGFloat = 400
    private static let padding: CGFloat = 20
    private static let gap: CGFloat = 20
    /// 小狗离屏幕右下角的距离,跟 `MascotPanel.perchMargin` 是同一个数。
    private static let perchMargin: CGFloat = 24

    var body: some View {
        HStack(alignment: .bottom, spacing: Self.gap) {
            // 左边那幅只有气泡栈那么高,上面空出来的一块正好放状态表 ——
            // 「它在说什么」这件事本来就该看图,不该只在 README 的表格里。
            scene(caption: "平时:要你动手的事摞在旁边,一件一条") {
                VStack(spacing: 0) {
                    legend
                    Spacer(minLength: 12)
                    bubbleScene.frame(height: bubbleSceneHeight)
                }
            }
            scene(caption: "双击:全部 session,点一行跳到那个终端") {
                listScene.frame(height: listSceneHeight)
            }
        }
        .padding(Self.padding)
        .background(wallpaper)
    }

    /// 两列一样高,矮的那列上面留白(留给状态表)。
    private var contentHeight: CGFloat { max(bubbleSceneHeight, listSceneHeight) }

    /// 场景高度 = 装得下里面那件东西 + 天地留白。两边各算各的,矮的那边上面就空出来。
    private var bubbleSceneHeight: CGFloat {
        let stack = BubbleStackView.height(itemCount: store.bubbles.count)
        return max(mascotBox, stackBottomInset + stack + Self.perchMargin)
    }

    private var listSceneHeight: CGFloat {
        SessionListView.height(rowCount: store.rows.count) + 6 + mascotBox + 16
    }

    /// 小狗那一格连底边留白。
    private var mascotBox: CGFloat { MascotMetrics.side + Self.perchMargin }

    /// 眼睛离小狗窗口底边多高 —— 气泡栈的尾巴对着这条线,不是窗口正中。
    private var headCenterFromBottom: CGFloat {
        MascotMetrics.side - MascotMetrics.inset
            - MascotMetrics.canvas * CGFloat(skin.headRow) / CGFloat(max(skin.side, 1))
    }

    /// 整摞的底边离场景底边多高。
    private var stackBottomInset: CGFloat {
        Self.perchMargin + headCenterFromBottom - BubbleStackView.rowHeight / 2
    }

    // MARK: - 两幅场景

    /// 左:气泡栈。位置照抄 `BubbleStackController.layout` —— 小狗在右下角时整摞开在左边,
    /// 尾巴朝右,最下面那条(等最久的)对着眼睛。
    private var bubbleScene: some View {
        let mascot = mascotFrame(in: bubbleSceneHeight)
        let stackHeight = BubbleStackView.height(itemCount: store.bubbles.count)
        return ZStack(alignment: .topLeading) {
            BubbleStackView(store: store, tailOnRight: true, animated: false)
                .frame(width: BubbleStackView.width, height: stackHeight)
                // 尾巴探进小狗 2pt,看着才是连着的 —— 跟 BubbleStackController 的 overlap 一样。
                .place(x: mascot.minX - BubbleStackView.width + 2,
                       y: bubbleSceneHeight - stackBottomInset - stackHeight)
            mascotView(frame: 2).place(x: mascot.minX, y: mascot.minY)
        }
    }

    /// 右:列表面板。位置照抄 `SessionListController.layout` —— 小狗蹲在下边缘,
    /// 底下放不下,于是翻到上方 6pt,横向对中后被右边缘顶回来。
    private var listScene: some View {
        let mascot = mascotFrame(in: listSceneHeight)
        let height = SessionListView.height(rowCount: store.rows.count)
        let x = min(mascot.midX - SessionListView.width / 2,
                    ShotView.sceneWidth - SessionListView.width - 4)
        return ZStack(alignment: .topLeading) {
            SessionListView(store: store, onSelect: { _ in }, frozenNow: Date())
                .place(x: max(4, x), y: mascot.minY - 6 - height)
            mascotView(frame: 0).place(x: mascot.minX, y: mascot.minY)
        }
    }

    /// 小狗蹲的那个角:离右下各 `perchMargin`。y 这里朝下。
    private func mascotFrame(in sceneHeight: CGFloat) -> CGRect {
        let side = MascotMetrics.side
        return CGRect(x: ShotView.sceneWidth - side - Self.perchMargin,
                      y: sceneHeight - side - Self.perchMargin,
                      width: side, height: side)
    }

    /// 两幅场景是同一时刻的两种打开方式,所以小狗的状态也得是同一个 —— 由数据推出来,
    /// 不在这儿另选一个(有 session 在等你,它就必然在跳)。
    private func mascotView(frame index: Int) -> some View {
        let sprite = skin.sprite(for: store.mascot)
        return MascotFrameView(skin: skin, sprite: sprite,
                               index: min(index, max(sprite.frameCount - 1, 0)))
    }

    // MARK: - 版面

    private func scene<Content: View>(caption: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 10) {
            content()
                .frame(width: Self.sceneWidth, height: contentHeight)
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    /// 四个状态各摆一帧。身体动画的优先级是 `等待 > 运行 > 刚完成 > 睡觉`,
    /// 这里就按这个顺序反过来排(从最闲到最急),看图的人一眼能排出轻重。
    private var legend: some View {
        HStack(spacing: 0) {
            legendItem(.sleeping, frame: 0, label: "全闲着")
            legendItem(.working, frame: 2, label: "在跑")
            legendItem(.alert, frame: 2, label: "在等你")
            legendItem(.celebrating, frame: 2, label: "刚跑完")
        }
    }

    private func legendItem(_ state: MascotState, frame index: Int, label: String) -> some View {
        let sprite = skin.sprite(for: state)
        return VStack(spacing: 0) {
            MascotFrameView(skin: skin, sprite: sprite,
                            index: min(index, max(sprite.frameCount - 1, 0)))
                .scaleEffect(0.7)
                .frame(width: MascotMetrics.side * 0.7, height: MascotMetrics.side * 0.7)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(width: Self.sceneWidth / 4)
    }

    /// 一块壁纸似的底 —— 气泡和列表都是半透明材质,没有底就看不出它们浮在桌面上。
    /// 纯色而不是渐变:半透明材质有个底就够浮起来了,而 1720×980 的渐变会让 PNG 从
    /// 340KB 涨到 1.7MB —— 一张躺在仓库里的说明图不值这个。
    private var wallpaper: some View {
        Color(red: 0.12, green: 0.15, blue: 0.20)
    }
}

private extension View {
    /// 按左上角坐标摆到 `ZStack(alignment: .topLeading)` 里。
    /// `.offset` 而不是 `.position`:后者要先知道自己多大,而这些视图的尺寸是自己算出来的。
    func place(x: CGFloat, y: CGFloat) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .offset(x: x, y: y)
    }
}
