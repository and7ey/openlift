import Foundation
import CoreServices

/// Watches a directory for changes using FSEvents.
///
/// Updates are coalesced with a short debounce so a burst of writes (an
/// unarchive, a build, a `git checkout`) triggers one reload instead of
/// hundreds. Callbacks are delivered on a background queue; callers are
/// responsible for hopping to their own isolation domain.
///
/// FSEvents is recursive, so a stream on a home directory would otherwise fire
/// for every write in `~/Library`. Only changes to the directory itself and to
/// its immediate children are reported, because that is exactly what a
/// one-level listing shows.
///
/// Stream creation runs on its own control queue: `FSEventStreamCreate` talks
/// to `fseventsd` and can block for a noticeable moment, which must never
/// happen on the main thread during navigation.
public final class DirectoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private var watchedPath: String?
    private let controlQueue = DispatchQueue(label: "dev.openlift.fsevents.control")
    private let eventQueue = DispatchQueue(label: "dev.openlift.fsevents.events", qos: .utility)
    private let debounceInterval: TimeInterval
    private let onChange: @Sendable () -> Void

    private var pendingWorkItem: DispatchWorkItem?
    private let stateLock = NSLock()

    public init(debounceInterval: TimeInterval = 0.25, onChange: @escaping @Sendable () -> Void) {
        self.debounceInterval = debounceInterval
        self.onChange = onChange
    }

    deinit {
        // Every queued closure captures `self` weakly, so once deallocation has
        // begun nothing else can touch the stream and it is safe to drop here.
        stopWatching()
    }

    /// Starts watching `url`. Restarts the stream only when the URL changes.
    public func watch(_ url: URL) {
        controlQueue.async { [weak self] in
            self?.startWatching(url)
        }
    }

    public func stop() {
        controlQueue.async { [weak self] in
            self?.stopWatching()
        }
    }

    /// True for events on the watched directory itself or on a direct child.
    public static func isRelevantChange(_ path: String, for watchedPath: String) -> Bool {
        let candidate = normalized(path)
        let watched = normalized(watchedPath)
        if candidate == watched { return true }
        return (candidate as NSString).deletingLastPathComponent == watched
    }

    /// FSEvents reports `/private/var/...` where URLs standardise to `/var/...`.
    static func normalized(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    // MARK: - Control queue

    private func startWatching(_ url: URL) {
        let standardized = url.standardizedFileURL

        stateLock.lock()
        let alreadyWatching = watchedPath == standardized.path && stream != nil
        stateLock.unlock()
        if alreadyWatching { return }

        stopWatching()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagUseCFTypes
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, eventPaths, _, _ in
                guard let info, count > 0 else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
                watcher.noteEvents(paths)
            },
            &context,
            [standardized.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            FSEventStreamCreateFlags(flags)
        ) else {
            return
        }

        stateLock.lock()
        self.stream = stream
        watchedPath = standardized.path
        stateLock.unlock()

        FSEventStreamSetDispatchQueue(stream, eventQueue)
        FSEventStreamStart(stream)
    }

    private func stopWatching() {
        stateLock.lock()
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        let stream = self.stream
        self.stream = nil
        watchedPath = nil
        stateLock.unlock()

        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func noteEvents(_ paths: [String]) {
        stateLock.lock()
        let watched = watchedPath
        stateLock.unlock()

        guard let watched else { return }
        guard paths.contains(where: { Self.isRelevantChange($0, for: watched) }) else { return }
        scheduleChange()
    }

    private func scheduleChange() {
        stateLock.lock()
        pendingWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        pendingWorkItem = item
        stateLock.unlock()

        eventQueue.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }
}
