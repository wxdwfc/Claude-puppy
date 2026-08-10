import AppKit

// 不用 @main + SwiftUI App lifecycle:无边框 nonactivating panel 跟它配合很别扭,
// 而且 headless 模式需要在 NSApplication 起来之前就分流。
let arguments = Set(CommandLine.arguments.dropFirst())

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    puppy — Claude Code 桌面宠物

      (无参数)   启动悬浮吉祥物
      --list     打印当前 session 表后退出
      --watch    持续打印 session 变化(FSEvents 驱动)
      --focus <pid>   单独验证 pid → tty → iTerm2 跳转
      --render <dir> [--skin <id>]  把每个状态的每一帧渲染成 PNG(目视检查;可指定皮肤)
      --export-skin <dir>  把内置皮肤按皮肤格式导出,拿来当自制皮肤的模板
      --skins    列出所有能用的皮肤(读不了的会说明原因)
    """)
    exit(0)
}

if arguments.contains("--skins") {
    MainActor.assumeIsolated { CLI.skins() }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--export-skin") {
    let directory = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : "."
    let target = URL(fileURLWithPath: directory, isDirectory: true)
    do {
        try MainActor.assumeIsolated { try SkinExporter.export(Sprites.builtIn, to: target) }
        print("已导出到 \(target.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("导出失败:\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if arguments.contains("--list") {
    MainActor.assumeIsolated { CLI.list() }
    exit(0)
}

if arguments.contains("--watch") {
    MainActor.assumeIsolated { CLI.watch() }
}

if let index = CommandLine.arguments.firstIndex(of: "--focus"),
   CommandLine.arguments.count > index + 1,
   let pid = Int32(CommandLine.arguments[index + 1]) {
    MainActor.assumeIsolated { CLI.focus(pid: pid) }
}

if let index = CommandLine.arguments.firstIndex(of: "--render") {
    let directory = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : "."
    let skinIndex = CommandLine.arguments.firstIndex(of: "--skin")
    let skinID = skinIndex.flatMap { CommandLine.arguments.count > $0 + 1 ? CommandLine.arguments[$0 + 1] : nil }
    MainActor.assumeIsolated { Preview.renderAll(to: directory, skinID: skinID) }
    exit(0)
}

// 顶层代码在 SwiftPM 里是 nonisolated 的,但这里确实就是主线程。
let app = MainActor.assumeIsolated { () -> NSApplication in
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)     // 无 Dock 图标、不抢激活
    app.delegate = AppDelegate.shared
    return app
}
app.run()
