import Foundation

/// FSEvents 目录监听。回调不解析事件内容 —— 只说「该重扫了」。
///
/// 只监听 `~/.claude/sessions`,**绝不**往上监听 `~/.claude`:
/// FSEvents 是递归的,而 `~/.claude/projects` 里的 transcript jsonl 会疯狂写入,
/// 那样等于给这个常驻 app 装了个唤醒发生器。
final class DirectoryWatcher {
    private let path: String
    private let latency: CFTimeInterval
    private let handler: () -> Void
    private let queue = DispatchQueue(label: "dev.wxd.puppy.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?

    init(path: String, latency: CFTimeInterval = 0.3, handler: @escaping () -> Void) {
        self.path = path
        self.latency = latency
        self.handler = handler
    }

    deinit { stop() }

    @discardableResult
    func start() -> Bool {
        guard stream == nil else { return true }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handler()
        }

        // latency 0.3s 让内核帮我们把连续写入合并成一次唤醒。
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return false }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
