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
      --render <dir>  把每个状态的每一帧渲染成 PNG(开发期目视检查)
    """)
    exit(0)
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
    MainActor.assumeIsolated { Preview.renderAll(to: directory) }
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
