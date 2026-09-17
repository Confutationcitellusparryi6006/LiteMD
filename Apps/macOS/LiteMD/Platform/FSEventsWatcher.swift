import CoreServices
import Foundation
import LiteMDDomain

/// macOS 文件监控（spec §31）：FSEvents，文件级事件 + inode 扩展数据。
/// 只产生事件，不做任何决策。
@MainActor
final class FSEventsWatcher: FileWatching {
    var eventHandler: (([FileEvent]) -> Void)?

    private var stream: FSEventStreamRef?
    private var watched: Set<URL> = []
    private let queue = DispatchQueue(label: "app.litemd.fsevents")
    private var box: CallbackBox?

    /// 以 `Unmanaged` 传给 C 回调的桥接对象。
    private final class CallbackBox: @unchecked Sendable {
        /// (真实路径, 应用使用的路径)。FSEvents 报告的是真实路径（例如 `/private/tmp`），
        /// 而应用中的 URL 可能经过符号链接（例如 `/tmp`），需要映射回去才能匹配。
        let pathMappings: [(real: String, logical: String)]
        let deliver: @Sendable ([FileEvent]) -> Void

        init(pathMappings: [(real: String, logical: String)], deliver: @escaping @Sendable ([FileEvent]) -> Void) {
            self.pathMappings = pathMappings
            self.deliver = deliver
        }

        func logicalPath(_ path: String) -> String {
            for mapping in pathMappings where mapping.real != mapping.logical {
                if path == mapping.real { return mapping.logical }
                if path.hasPrefix(mapping.real + "/") {
                    return mapping.logical + path.dropFirst(mapping.real.count)
                }
            }
            return path
        }
    }

    func setWatchedDirectories(_ urls: Set<URL>) {
        let normalized = Set(urls.map { $0.standardizedFileURL })
        guard normalized != watched else { return }
        watched = normalized
        restart()
    }

    private func restart() {
        stop()
        guard !watched.isEmpty else { return }

        let mappings = watched.map { url in
            (real: Self.realPath(url.path), logical: url.path)
        }
        let box = CallbackBox(pathMappings: mappings) { [weak self] events in
            Task { @MainActor in
                self?.eventHandler?(events)
            }
        }
        self.box = box

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            let items = unsafeBitCast(paths, to: NSArray.self)
            var events: [FileEvent] = []
            events.reserveCapacity(count)

            for index in 0..<count {
                let raw = flags[index]
                var path: String?
                var inode: UInt64?
                if let dictionary = items[index] as? NSDictionary {
                    path = dictionary["path"] as? String
                    inode = (dictionary["fileID"] as? NSNumber)?.uint64Value
                } else {
                    path = items[index] as? String
                }
                guard let path else { continue }
                let logical = box.logicalPath(path)
                events.append(FileEvent(url: URL(fileURLWithPath: logical), flags: FSEventsWatcher.flags(from: raw), inode: inode))
            }
            box.deliver(events)
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseExtendedData
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
        )
        let paths = watched.map(\.path) as CFArray
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        box = nil
    }

    /// POSIX realpath。注意 `URL.resolvingSymlinksInPath()` 会去掉 `/private` 前缀，不能用于这里。
    nonisolated static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    nonisolated static func flags(from raw: FSEventStreamEventFlags) -> FileEvent.Flags {
        var result: FileEvent.Flags = []
        func has(_ flag: Int) -> Bool { raw & FSEventStreamEventFlags(flag) != 0 }
        if has(kFSEventStreamEventFlagItemCreated) { result.insert(.created) }
        if has(kFSEventStreamEventFlagItemModified) || has(kFSEventStreamEventFlagItemInodeMetaMod) { result.insert(.modified) }
        if has(kFSEventStreamEventFlagItemRenamed) { result.insert(.renamed) }
        if has(kFSEventStreamEventFlagItemRemoved) { result.insert(.removed) }
        if has(kFSEventStreamEventFlagItemIsDir) { result.insert(.isDirectory) }
        if has(kFSEventStreamEventFlagMustScanSubDirs) || has(kFSEventStreamEventFlagUserDropped)
            || has(kFSEventStreamEventFlagKernelDropped) || has(kFSEventStreamEventFlagRootChanged) {
            result.insert(.mustRescan)
        }
        return result
    }
}
