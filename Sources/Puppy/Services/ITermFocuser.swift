import AppKit
import Foundation

/// pid → tty → iTerm2 里对应的 session,选中并激活。
///
/// 用 AppleScript 而不是 iTerm2 的 Python API:后者要用户去偏好设置里手动打开。
/// 用 NSAppleScript **进程内**执行,这样 TCC 的 Automation 授权归属于 Puppy.app
/// 本身,而不是启动它的那个终端。
final class ITermFocuser {

    enum Outcome {
        case focused            // 精确定位到了那个 session
        case activatedOnly      // tty 匹配不上(tmux / ssh / 别的终端),只把 iTerm 提到前台
        case notAuthorized      // 用户拒绝了 Automation 授权
        case failed(String)
    }

    /// Apple Events 可能阻塞好几秒(比如 iTerm 正在启动),绝不能放主线程。
    private let queue = DispatchQueue(label: "dev.wxd.puppy.applescript", qos: .userInitiated)
    private var compiled: NSAppleScript?

    /// TCC 拒绝授权时的错误码。
    private static let errAEEventNotPermitted = -1743

    // OSA 的这几个常量没有桥接到 Swift,只能写字面值。
    private static let suiteAppleScript = AEEventClass(0x6173_6372)  // 'ascr'
    private static let eventSubroutine  = AEEventID(0x7073_6272)     // 'psbr'
    private static let keySubroutineName = AEKeyword(0x736E_616D)    // 'snam'

    func focus(pid: Int32, completion: @escaping (Outcome) -> Void) {
        queue.async { [self] in
            let outcome = run(pid: pid)
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    // MARK: - 内部

    private func run(pid: Int32) -> Outcome {
        let tty = Self.tty(for: pid)
        let script = compiledScript()

        let event = Self.callEvent(handler: "focusTTY", argument: tty ?? "")
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)

        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == Self.errAEEventNotPermitted {
                return .notAuthorized
            }
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "AppleScript 错误 \(code)"
            return .failed(message)
        }

        // 脚本返回 true 表示按 tty 找到了具体 session。
        return result.booleanValue ? .focused : .activatedOnly
    }

    private func compiledScript() -> NSAppleScript {
        if let compiled { return compiled }
        let script = NSAppleScript(source: Self.source)!
        var error: NSDictionary?
        script.compileAndReturnError(&error)
        compiled = script
        return script
    }

    /// `ps -o tty=` 给出的是 `ttys004` 这种(带右侧空格),非终端进程给 `??`。
    /// 结果要拼进 AppleScript,所以必须严格校验形状。
    static func tty(for pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "tty=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.range(of: "^ttys[0-9]+$", options: .regularExpression) != nil else { return nil }
        return "/dev/" + raw
    }

    /// 用 handler + 参数的形式调用,这样 tty 是真正的参数而不是拼进源码的字符串。
    private static func callEvent(handler: String, argument: String) -> NSAppleEventDescriptor {
        let target = NSAppleEventDescriptor(descriptorType: typeProcessSerialNumber,
                                            bytes: &currentProcess,
                                            length: MemoryLayout<ProcessSerialNumber>.size)!
        let event = NSAppleEventDescriptor(
            eventClass: suiteAppleScript,
            eventID: eventSubroutine,
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: keySubroutineName)
        let args = NSAppleEventDescriptor.list()
        args.insert(NSAppleEventDescriptor(string: argument), at: 0)
        event.setParam(args, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    private nonisolated(unsafe) static var currentProcess =
        ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))

    private static let source = """
    on focusTTY(targetTTY)
      tell application "iTerm2"
        if targetTTY is not "" then
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is targetTTY then
                  select s
                  select t
                  set index of w to 1
                  activate
                  return true
                end if
              end repeat
            end repeat
          end repeat
        end if
        -- 兜底:tty 对不上(tmux / ssh / 非 iTerm 终端),至少把 iTerm 提到前台
        activate
        return false
      end tell
    end focusTTY
    """

    /// 授权被拒时把用户直接送到对应的设置面板。
    @MainActor
    static func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }
}
