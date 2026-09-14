import Foundation
import Darwin

/// Hooks are children of the local CLI (sometimes via its app-server child).
/// Walk upwards, never search unrelated processes or infer identity from cwd.
enum CodexProcess {
    struct Identity: Codable, Equatable {
        let pid: Int32
        let startedSeconds: UInt64
        let startedMicros: UInt64
    }

    static func info(_ pid: Int32) -> proc_bsdinfo? {
        var value = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, size) == size else { return nil }
        return value
    }

    static func identity(_ pid: Int32) -> Identity? {
        guard let value = info(pid) else { return nil }
        return Identity(pid: pid, startedSeconds: value.pbi_start_tvsec,
                        startedMicros: value.pbi_start_tvusec)
    }

    static func arguments(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return nil }
        var cursor = 4
        while cursor < size && bytes[cursor] != 0 { cursor += 1 } // executable path
        while cursor < size && bytes[cursor] == 0 { cursor += 1 }
        var result: [String] = []
        for _ in 0..<argc {
            let start = cursor
            while cursor < size && bytes[cursor] != 0 { cursor += 1 }
            guard cursor < size else { return nil }
            result.append(String(decoding: bytes[start..<cursor], as: UTF8.self))
            cursor += 1
        }
        return result
    }

    /// Fail closed for headless commands and remote/shared-server CLI modes.
    /// Options taking values are skipped so a prompt/path named "exec" isn't a command.
    static func isInteractive(_ args: [String]) -> Bool {
        let takesValue: Set<String> = ["-c", "--config", "--enable", "--disable", "-i", "--image",
            "-m", "--model", "--local-provider", "-p", "--profile", "-s", "--sandbox",
            "-C", "--cd", "--add-dir", "-a", "--ask-for-approval", "--remote-auth-token-env"]
        let commands: Set<String> = ["exec", "e", "review", "login", "logout", "mcp", "plugin",
            "app-server", "remote-control", "app", "completion", "update", "doctor", "sandbox",
            "debug", "apply", "a", "queue", "archive", "delete", "migrate-rollouts", "unarchive",
            "cloud", "exec-server", "features", "help", "agents"]
        var index = 1
        while index < args.count {
            let arg = args[index]
            if arg == "--remote" || arg.hasPrefix("--remote=") { return false }
            if takesValue.contains(arg) { index += 2; continue }
            if arg == "--" { return true }
            if arg.hasPrefix("-") { index += 1; continue }
            return !commands.contains(arg)
        }
        return true
    }

    static func findCLI(startingAt start: Int32 = getppid()) -> Identity? {
        var pid = start
        for _ in 0..<32 {
            guard pid > 1, let value = info(pid) else { return nil }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0,
               URL(fileURLWithPath: String(cString: path)).lastPathComponent == "codex" {
                guard let args = arguments(pid) else { return nil }
                if isInteractive(args) {
                    guard value.e_tdev != UInt32.max, value.e_tdev != 0 else { return nil }
                    return identity(pid)
                }
                // Only the CLI's local app-server child may bridge to a parent CLI.
                // An `exec` launched as a tool must not report into its ancestor's row.
                guard args.dropFirst().first == "app-server" else { return nil }
            }
            let parent = Int32(value.pbi_ppid)
            guard parent != pid else { return nil }
            pid = parent
        }
        return nil
    }
}
