#if os(macOS)
import Foundation
import CoreServices

/// macOS keeps a journal of which directories changed on each volume (FSEvents). Backup HQ uses it two ways:
/// replaying the journal since the last scan so a rescan only visits directories that changed, and watching
/// tracked folders live so a new file is noticed within seconds instead of at the next scheduled look.
public enum FSEventsJournal {
    public struct Change: Sendable, Hashable {
        public var path: String
        /// Everything underneath changed too (the journal lost detail); walk it recursively.
        public var deep: Bool
    }
    public struct Replay: Sendable {
        public var changes: [Change]
        /// The journal id to store for next time; captured before the replay so nothing can fall between two scans.
        public var cursor: UInt64
    }

    public static func currentEventId() -> UInt64 { FSEventsGetCurrentEventId() }

    /// Identifies the journal of the volume holding `path`. Journal ids are only meaningful while this stays the same.
    public static func deviceUUID(forPath path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Directories under `root` touched since journal id `since`. nil means the journal cannot be trusted for this
    /// span (events were dropped, the journal was reset, or it did not answer in time) and a full walk is needed.
    public static func replay(root: String, since: UInt64, timeout: TimeInterval = 90) async -> Replay? {
        let cursor = currentEventId()
        guard since != 0, since <= cursor else { return nil }
        let collector = Collector(root: root)
        let paths = [root] as CFArray
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(collector).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, historyCallback, &ctx, paths, since, 0.1, flags) else { return nil }
        let queue = DispatchQueue(label: "bhq.fsevents.replay")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); return nil }
        let finished = await collector.wait(timeout: timeout)
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        guard finished, collector.reliable else { return nil }
        return Replay(changes: Array(collector.changes), cursor: cursor)
    }

    /// Collects history events until the journal says it has caught up.
    final class Collector: @unchecked Sendable {
        let root: String
        var changes = Set<Change>()
        var reliable = true
        private let done = DispatchSemaphore(value: 0)
        private var finished = false
        private let lock = NSLock()
        init(root: String) { self.root = root }

        func add(path: String, flags: FSEventStreamEventFlags) {
            lock.lock(); defer { lock.unlock() }
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 {
                if !finished { finished = true; done.signal() }
                return
            }
            let bad = kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
            if flags & FSEventStreamEventFlags(bad) != 0 { reliable = false }
            let deep = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
            var p = path
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            changes.insert(Change(path: p, deep: deep))
        }

        func wait(timeout: TimeInterval) async -> Bool {
            await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .utility).async {
                    cont.resume(returning: self.done.wait(timeout: .now() + timeout) == .success)
                }
            }
        }
    }
}

private let historyCallback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
    guard let info else { return }
    let collector = Unmanaged<FSEventsJournal.Collector>.fromOpaque(info).takeUnretainedValue()
    let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
    for i in 0..<min(numEvents, paths.count) { collector.add(path: paths[i], flags: eventFlags[i]) }
}

/// Live watch over a set of folders. Reports which folder ids saw activity, a couple of seconds after it settles.
public final class FolderWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (Set<Int64>) -> Void
    public struct Root: Sendable {
        public var id: Int64; public var path: String; public var ignore: IgnoreRules
        public init(id: Int64, path: String, ignore: IgnoreRules = IgnoreRules([])) { self.id = id; self.path = path; self.ignore = ignore }
    }
    private var stream: FSEventStreamRef?
    private let roots: [Root]
    private let handler: Handler
    private let queue = DispatchQueue(label: "bhq.fsevents.watch")

    /// Starts watching immediately; returns nil if nothing could be watched. Activity inside an ignored directory is not reported.
    public init?(roots: [Root], latency: TimeInterval = 2, handler: @escaping Handler) {
        self.roots = roots.map { var r = $0; if r.path.hasSuffix("/") && r.path.count > 1 { r.path.removeLast() }; return r }.sorted { $0.path.count > $1.path.count }
        self.handler = handler
        guard !roots.isEmpty else { return nil }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, liveCallback, &ctx, self.roots.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else { FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil; return nil }
    }

    public var watchedIds: Set<Int64> { Set(roots.map(\.id)) }

    fileprivate func report(paths: [String]) {
        var ids = Set<Int64>()
        for p in paths {
            // Every folder the path falls inside (tracked folders can nest); skip ones whose rules cover it.
            for r in roots where p == r.path || p.hasPrefix(r.path + "/") {
                let rel = p == r.path ? "" : String(p.dropFirst(r.path.count + 1))
                if !rel.isEmpty, r.ignore.shouldSkip(relPath: rel) { continue }
                ids.insert(r.id)
            }
        }
        if !ids.isEmpty { handler(ids) }
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}

private let liveCallback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
    guard let info else { return }
    let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
    let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
    watcher.report(paths: Array(paths.prefix(numEvents)))
}
#endif
