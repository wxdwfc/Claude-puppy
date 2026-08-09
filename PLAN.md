# Puppy — Claude Code 桌面宠物监控 App 实现计划

> 本文件是完整的实现计划,由规划 session 产出。实现时按里程碑 M1→M4 顺序执行,每步有验证标准。

## 1. 背景与目标

做一个类似 OpenAI Codex 桌面吉祥物的 macOS app:一只像素风小狗悬浮在桌面上,实时反映 iTerm2 中各个 Claude Code session 的状态。

**用户确认的需求**:
- 形态:桌面宠物(悬浮无边框小狗)+ 点击展开的 session 列表面板
- 提醒方式:**只靠吉祥物动画/表情**(明确不要系统通知、不要声音)
- 面板中点击某个 session 行 → 跳转激活对应的 iTerm2 window/tab
- 技术栈:Swift/SwiftUI 原生
- 能耗:用户明确要求**事件驱动而非轮询**(FSEvents + 批量合并),常驻 app 要近零唤醒

**本机环境**(已验证):Xcode 26.6、Swift 6.3.3、arm64 (macOS 26)、iTerm2 3.6.11、Claude Code CLI v2.1.226(native 单文件构建,进程名就是 `claude`)。

## 2. 核心机制(已实测验证,这是整个方案的地基)

### 2.1 Session 状态来源:`~/.claude/sessions/<pid>.json`
Claude Code CLI 自带的**实时注册表**——每个运行中的 CLI 进程一个文件,进程退出即删除。实测样例:

```json
{"pid":63806,"sessionId":"c72ce9c6-...","cwd":"/Users/wxd/lab/personal/puppy",
 "startedAt":1786240925018,"version":"2.1.226","peerProtocol":1,
 "kind":"interactive","entrypoint":"cli",
 "messagingSocketPath":"/tmp/cc-socks/63806.sock",
 "name":"puppy-aa","nameSource":"derived",
 "status":"waiting","updatedAt":1786241000000,"statusUpdatedAt":1786241000000,
 "waitingFor":"input needed"}
```

- 观察到的 `status` 值:`busy` / `idle` / `waiting`;`waiting` 时附 `waitingFor`(见过 `"input needed"`、`"permission prompt"`)。时间戳为 epoch ms。状态变化实时写入。
- **"完成"语义**:注册表没有 "done" 状态。`busy → idle` 转变 = 一轮任务完成;`→ waiting` = 需要用户介入。由 app diff 快照推导。
- **不要解析 transcript jsonl**(`~/.claude/projects/.../<sessionId>.jsonl` 可达 16MB)。
- **Schema 未文档化、随 CLI 版本可能漂移**:解码必须全字段 Optional、未知字段忽略、坏文件跳过;残留死文件用 `kill(pid_t(pid), 0) == 0 || errno == EPERM` 过滤;`kind` 过滤为 `interactive`(或 nil 宽容处理),排除 headless/子代理进程。目录不存在时显示"无 session",绝不崩溃、绝不创建该目录。

### 2.2 iTerm2 跳转链路
`sessions/*.json` 给 pid → `ps -o tty= -p <pid>`(经 `Process` 调 `/bin/ps`)得 `ttysNNN` → iTerm2 AppleScript 字典暴露每个 session 的 `tty`,遍历匹配后 select/activate。**不用 iTerm2 Python API**(本机未启用,启用需要用户改偏好设置)。tty 插入脚本前须用 `^ttys[0-9]+$` 校验;`tty=??`(tmux/ssh/非 iTerm 终端)降级为仅 `activate` iTerm。

AppleScript 模板:

```applescript
tell application "iTerm2"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if tty of s is "/dev/ttys004" then
          select s
          select t
          set index of w to 1
          activate
          return
        end if
      end repeat
    end repeat
  end repeat
  activate -- 兜底:没找到匹配 session,至少把 iTerm 提到前台
end tell
```

用 `NSAppleScript` **进程内执行**(TCC Automation 授权才归属 Puppy.app 而非终端),放后台队列(Apple Events 可能阻塞),lazy 编译。错误 -1743(用户拒绝授权)→ 打开 `x-apple.systempreferences:com.apple.preference.security?Privacy_Automation`。失败反馈用吉祥物抖一下,不弹 alert。

### 2.3 App 约束
- **不能开 sandbox**(需要 ps、读 `~/.claude`、发 Apple Events)。无需 entitlements 文件、无需 hardened runtime(个人使用)。
- `Info.plist` 必须有:`LSUIElement=true`(无 Dock 图标)、`NSAppleEventsUsageDescription`、`CFBundleIdentifier=dev.wxd.puppy`、`NSHighResolutionCapable`、`LSMinimumSystemVersion=14.0`。
- **签名**:M1–M2 用 ad-hoc(`codesign -s -`);M3 起必须换 Keychain 自签证书(建议名 `puppy-dev`,用 Keychain Access 创建一次)——因为 ad-hoc 签名每次重编译都变,会导致 Automation 授权反复弹窗失效。

## 3. 工程脚手架

纯 SwiftPM,**无 .xcodeproj、无 XcodeGen/Tuist**,全程 CLI 可构建。之所以要组装 .app bundle:TCC Automation 弹窗和 `NSAppleEventsUsageDescription` 都从 bundle 的 Info.plist 读取,裸 `swift run` 二进制的授权会错误归属到父终端。

```
puppy/
├── Package.swift                # swift-tools-version 6.x, 单 executable target "Puppy", platforms: [.macOS(.v14)]
├── Makefile                     # make app → swift build -c release + bundle + codesign; make run → open .app
├── scripts/build-app.sh
├── Support/Info.plist
└── Sources/Puppy/
    ├── main.swift
    ├── AppDelegate.swift
    ├── Model/
    │   ├── SessionInfo.swift        # lenient Codable + 派生 DisplayState
    │   ├── SessionStore.swift       # ObservableObject; FSEvents 触发重扫; 快照 diff
    │   └── MascotState.swift        # 聚合状态机
    ├── Services/
    │   ├── SessionRegistryReader.swift
    │   └── ITermFocuser.swift
    └── UI/
        ├── MascotPanel.swift        # 悬浮吉祥物 NSPanel
        ├── MascotView.swift         # SwiftUI sprite 渲染 + 动画驱动
        ├── Sprites.swift            # 像素帧数据(字符串位图 + 调色板)
        ├── SessionListPanel.swift
        └── SessionListView.swift
```

`scripts/build-app.sh` 核心:

```bash
swift build -c release
APP=.build/Puppy.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Puppy "$APP/Contents/MacOS/Puppy"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "puppy-dev" "$APP"   # M3 前可用 "-"(ad-hoc)
```

**入口不用 `@main` SwiftUI lifecycle**(与无边框窗口配合不好),用 `main.swift`:

```swift
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// M1 headless 模式:--list / --watch 打印 session 表后退出,先于 app.run() 判断
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

## 4. 关键实现要点

### 4.1 数据流
`SessionStore` 是唯一 source of truth(`@Published var sessions: [SessionInfo]`、`@Published var mascot: MascotState`),两个 SwiftUI 视图都观察它;`ITermFocuser` 由行点击调用。

### 4.2 事件驱动扫描(省电设计,用户明确要求)
- **FSEvents** 监听 `~/.claude/sessions/`,带 `kFSEventStreamCreateFlagFileEvents`,`latency = 0.3s`(内核级批量合并写入事件)。
- **事件只当作"该重扫了"的触发器**:回调不解析事件细节,直接重读目录内全部小 JSON(幂等)。原子写/rename/事件合并等边缘情况因此全部无关紧要;半写文件 decode 失败跳过,下次事件自愈。
- **30s 低频兜底重扫**:`DispatchSourceTimer` 配大 leeway(允许系统合并唤醒),防漏事件 + 清理死 pid 残留。
- 面板"已等待 X 分钟"计时标签只在**面板打开时**起 1s UI tick;关闭即停。
- 吉祥物窗口 `occlusionState` 不可见时暂停 TimelineView 动画。
- 目标:无状态变化时 app 近零唤醒,不阻碍 App Nap。

### 4.3 吉祥物窗口(精确配方)
`NSPanel` 子类——用 panel 而非 window,为了 `.nonactivatingPanel`(点击小狗**不抢 iTerm 焦点**):

```swift
final class MascotPanel: NSPanel {
    init(contentView: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 96, height: 96),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true      // 拖动 = 移动窗口
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        self.contentView = contentView          // NSHostingView(rootView: MascotView(store:))
        setFrameAutosaveName("PuppyMascot")     // 位置持久化
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
```

- 点击 vs 拖动:先试 SwiftUI `.onTapGesture`;若与 `isMovableByWindowBackground` 冲突,改 override `mouseDown/mouseDragged/mouseUp`,位移 <4pt 算点击。
- **右键菜单必须有 Quit**(无 Dock 图标,这是唯一退出路径)。

### 4.4 列表面板
第二个 NSPanel,同样 `[.borderless, .nonactivatingPanel]` + `.floating` + 透明背景。**不用 NSPopover**(锚在 nonactivating 无边框 panel 上的 popover 有长期焦点/消失怪癖)。
- 位置贴着吉祥物 frame,靠近屏幕边缘时用 `NSScreen.visibleFrame` 翻转方向。
- 吉祥物点击开合;外部点击关闭用 `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown])` + local monitor(global 监听不到本 app 事件)。
- 内容:`NSHostingView` + SwiftUI 画 `.regularMaterial` 圆角背景。
- 行内容:项目名(`name` 字段)、cwd、状态图标(⏳ busy / ✋ waiting(附 waitingFor)/ ✅ 刚完成 / 💤 idle)、当前状态持续时长(由 `statusUpdatedAt` 算)。
- 键盘焦点在 never-key panel 里永远不可用——面板保持纯点击交互。

### 4.5 状态推导与排序
Store 保留上一次扫描的 `[pid: status]` 快照,每次重扫 diff:
- `busy → idle` ⇒ 记 `completedAt`;✅ 徽标显示 60s(期间再变 busy/waiting 立即清除)。这是唯一的派生状态,其余全部直读文件。
- 吉祥物庆祝动画 10s,被更高优先级状态立即打断。
- 优先级:**waiting > busy > celebrating > sleeping**。1s 内多次变化由 FSEvents latency 自然合并,不预建防抖,观察到抖动再加。
- 排序:waiting(等最久优先)→ busy(`statusUpdatedAt` 最新优先)→ idle/done;同级按 pid 稳定排序防跳动。
- 文件消失或 pid 死 ⇒ 行移除(busy 中消失也直接移除,v1 不做 "crashed" 状态)。

### 4.6 像素小狗渲染
**程序化 sprite,不依赖美术资源**:每帧是 `[String]` 位图(16×16),字符→颜色调色板,SwiftUI `Canvas` 逐格填矩形(每格 5–6px)。

```swift
enum Palette { static let map: [Character: Color] = [
    ".": .clear, "B": .brown, "D": Color(red:0.4,green:0.25,blue:0.1),
    "W": .white, "K": .black, "P": .pink ] }
struct Sprite { let frames: [[String]]; let fps: Double }
```

动画驱动:`TimelineView(.periodic(from:by:))` 按当前 sprite 的 fps 取 `frames[Int(t * fps) % frames.count]`;状态切换直接换帧组(像素风要"snap",不做淡入淡出)。气泡("!"、"✓"、"z")作为 sprite 上层的小 Text/图层。

| MascotState | 聚合条件 | 动画 |
|---|---|---|
| `.alert` | 任一 session waiting | 上下跳动(offset ±2px)+ "!" 气泡,~4fps,最高优先级 |
| `.working` | 否则任一 busy | 小跑/摇尾 3 帧循环,~5fps |
| `.celebrating` | 否则有 <10s 前完成的 | 跳跃 2 帧 + "✓" 气泡,随后衰减到 sleeping |
| `.sleeping` | 其余(全 idle/无 session) | 呼吸 2 帧 1fps + 飘 "z" |

以后换真 PNG 美术只需替换 `Sprites.swift`,渲染改 `Image(...).interpolation(.none)`。

## 5. 里程碑(按序执行,每步验证)

**M1 — CLI 原型(无 UI)**:`Package.swift` + `SessionInfo` + `SessionRegistryReader` + `SessionStore` diff 逻辑;`swift run Puppy --list` 打印 session 表(name/cwd/status/waitingFor/时长),`--watch` 用 FSEvents 持续输出变化。
*验证*:对照真实运行中的 Claude session;人为驱动一个 session 走 busy/idle/waiting 确认转变检测(含 busy→idle 的"完成"推导);拷贝一个 sessions 文件改成假 pid,确认被活性过滤丢弃。

**M2 — 窗口 UI**:`MascotPanel` + 静态 sprite 的 `MascotView` + 列表 panel + bundle 脚本 + `LSUIElement` + 右键 Quit。
*验证*:`make run` 后小狗浮于所有 app 和空间之上、可拖动、位置重启保留、点击开合实时列表、无 Dock 图标、点击不抢 iTerm 焦点。

**M3 — iTerm 跳转**:`ITermFocuser` + `NSAppleEventsUsageDescription` + 切换 `puppy-dev` 自签证书。
*验证*:首次点击行恰好弹一次 Automation 授权;之后点不同 window/tab 的 session 均正确选中并激活;`tty=??` 的 session 优雅降级(仅激活 iTerm)。

**M4 — 动画打磨**:全套 sprite + 状态机接线 + 徽标/庆祝时效 + 面板边缘翻转 + 排序 + 遮挡暂停动画。
*验证*:驱动一个 session 走 idle→busy→waiting→busy→idle,动画依次 睡觉→小跑→跳动!→小跑→跳跃✓→睡觉;两个 session 混合状态时优先级正确;Activity Monitor 确认空闲时 CPU ~0%。

**明确不做进 v1**(记录备将来):开机自启(`SMAppService.mainApp.register()`)、真 PNG 美术、基于 Claude Code hooks 的 push 更新(用户 settings.json 目前无任何 hooks,这个通道是空闲的,若未来注册表 schema 变了可作为更稳定的契约)。

## 6. 风险清单
- **注册表 schema 漂移**(未文档化,`peerProtocol:1`):全 Optional 解码、未知 status 映射为中性态、单文件损坏不影响整体、目录缺失不崩溃。
- **Automation 授权**:首个 Apple Event 由用户点击触发(时机自然);务必在 M3 换稳定签名身份,否则每次重编译授权失效。
- **tty 不匹配**(tmux/ssh/VS Code 终端):只降级激活 iTerm,不假装能深度定位。
- **nonactivating panel 怪癖**:tap 手势基本可用,键盘焦点永远不可用;M2 尽早实测 tap-vs-drag,备好 mouseDown override 方案。
