import Foundation
import CoreServices

/// Watches a directory for changes using FSEvents.
///
/// Updates are coalesced with a short debounce so a burst of writes (an
/// unarchive, a build, a `git checkout`) triggers one reload instead of
/// hundreds. Callbacks are delivered on a background queue; callers are
/// responsible for hopping to their own isolation domain.
///
/// Stream creation runs on its own control queue: `FSEventStreamCreate` talks
/// to `fseventsd` and can block for a noticeable moment, which must never
/// happen on the main thread during navigation.
public final class DirectoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private var watchedURL: URL?
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

    // MARK: - Control queue

    private func startWatching(_ url: URL) {
        let standardized = url.standardizedFileURL
        if watchedURL == standardized, stream != nil { return }
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
            kFSEventStreamCreateFlagWatchRoot
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.scheduleChange()
            },
            &context,
            [standardized.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            FSEventStreamCreateFlags(flags)
        ) else {
            return
        }

        self.stream = stream
        watchedURL = standardized
        FSEventStreamSetDispatchQueue(stream, eventQueue)
        FSEventStreamStart(stream)
    }

    private func stopWatching() {
        stateLock.lock()
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        let stream = self.stream
        self.stream = nil
        watchedURL = nil
        stateLock.unlock()

        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
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
