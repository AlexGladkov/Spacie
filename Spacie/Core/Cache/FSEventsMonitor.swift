import Foundation
import CoreServices

// MARK: - FSEventsMonitor

/// Monitors file system changes using the macOS FSEvents API.
///
/// Wraps `FSEventStreamCreate` to detect file-level changes on a monitored path.
/// Uses `kFSEventStreamCreateFlagFileEvents` for granular, per-file notifications
/// that allow incremental cache invalidation in ``ScanCache``.
///
/// ## Usage
/// ```swift
/// let monitor = FSEventsMonitor(path: "/Users/dev", latency: 2.0) { events in
///     for event in events {
///         print("Changed: \(event.path)")
///     }
/// }
/// monitor.start()
/// // ... later ...
/// monitor.stop()
/// ```
///
/// ## Thread Safety
/// The monitor dispatches callbacks on an internal serial queue. The `start()`
/// and `stop()` methods are safe to call from any thread.
final class FSEventsMonitor: @unchecked Sendable {

    // MARK: - Types

    /// Represents a single file system change event.
    struct Event: Sendable {
        /// The absolute path that changed.
        let path: String

        /// The FSEvents flags describing the type of change.
        let flags: FSEventStreamEventFlags

        /// The event ID from the FSEvents stream.
        let eventId: FSEventStreamEventId

        /// Whether this event indicates a file was created.
        var isCreated: Bool {
            flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0
        }

        /// Whether this event indicates a file was removed.
        var isRemoved: Bool {
            flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0
        }

        /// Whether this event indicates a file was renamed.
        var isRenamed: Bool {
            flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
        }

        /// Whether this event indicates a file's content was modified.
        var isModified: Bool {
            flags & UInt32(kFSEventStreamEventFlagItemModified) != 0
        }

        /// Whether this event indicates a change to file metadata (size, permissions).
        var isMetadataChanged: Bool {
            flags & UInt32(kFSEventStreamEventFlagItemInodeMetaMod) != 0
        }

        /// Whether the event is for a directory.
        var isDirectory: Bool {
            flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
        }

        /// Whether the event is for a regular file.
        var isFile: Bool {
            flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0
        }

        /// Whether the events must be flushed (buffer overflow).
        var mustScanSubDirs: Bool {
            flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
        }
    }

    /// Callback type for receiving batches of file system events.
    typealias EventHandler = @Sendable ([Event]) -> Void

    // MARK: - Properties

    /// The root path being monitored.
    let monitoredPath: String

    /// The coalescing latency in seconds.
    let latency: CFTimeInterval

    /// The event ID from which the stream should report events.
    ///
    /// Use `kFSEventStreamEventIdSinceNow` (the default) to receive only
    /// events that occur after the stream is started. Pass a previously
    /// persisted event ID to replay events since that point.
    let sinceWhen: FSEventStreamEventId

    /// Callback invoked when events are received.
    private let eventHandler: EventHandler

    /// The underlying FSEvent stream.
    private var stream: FSEventStreamRef?

    /// Serial dispatch queue for the FSEvent stream.
    private let queue: DispatchQueue

    /// Lock protecting stream start/stop operations.
    private let stateLock = NSLock()

    /// Whether the monitor is currently active.
    private(set) var isRunning: Bool = false

    // MARK: - Initialization

    /// Creates a new file system events monitor.
    ///
    /// - Parameters:
    ///   - path: The root path to monitor for changes.
    ///   - latency: Coalescing interval in seconds. Lower values detect changes
    ///     faster but increase CPU usage. Defaults to 2.0 seconds.
    ///   - sinceWhen: The event ID from which to report events. Pass a previously
    ///     saved event ID to replay historical events, or use the default
    ///     `kFSEventStreamEventIdSinceNow` to receive only future events.
    ///   - handler: Callback invoked on a background queue with batches of events.
    init(
        path: String,
        latency: CFTimeInterval = 2.0,
        sinceWhen: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        handler: @escaping EventHandler
    ) {
        self.monitoredPath = path
        self.latency = latency
        self.sinceWhen = sinceWhen
        self.eventHandler = handler
        self.queue = DispatchQueue(label: "com.spacie.fsevents.\(path.hashValue)", qos: .utility)
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Starts monitoring the file system for changes.
    ///
    /// If already running, this method does nothing. The FSEvents stream is
    /// configured with `kFSEventStreamCreateFlagFileEvents` for file-level
    /// granularity and `kFSEventStreamCreateFlagNoDefer` for immediate
    /// notification of the first change after a quiet period.
    func start() {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard !isRunning else { return }

        let pathsToWatch = [monitoredPath] as CFArray

        // We use an Unmanaged reference to self to bridge into the C callback.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagFileEvents) |
            UInt32(kFSEventStreamCreateFlagNoDefer) |
            UInt32(kFSEventStreamCreateFlagUseCFTypes)

        guard let eventStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.streamCallback,
            &context,
            pathsToWatch,
            sinceWhen,
            latency,
            flags
        ) else {
            return
        }

        stream = eventStream
        FSEventStreamSetDispatchQueue(eventStream, queue)
        FSEventStreamStart(eventStream)
        isRunning = true
    }

    /// Stops monitoring and releases the FSEvents stream.
    ///
    /// Safe to call even if not currently running.
    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard isRunning, let eventStream = stream else { return }

        FSEventStreamStop(eventStream)
        FSEventStreamInvalidate(eventStream)
        FSEventStreamRelease(eventStream)

        // Balance the passRetained from start()
        Unmanaged<FSEventsMonitor>.fromOpaque(
            Unmanaged.passUnretained(self).toOpaque()
        ).release()

        stream = nil
        isRunning = false
    }

    /// Requests that the FSEvents stream flush any pending events immediately.
    ///
    /// Useful before saving cache to ensure all recent changes are captured.
    func flushSync() {
        stateLock.lock()
        let eventStream = stream
        stateLock.unlock()

        if let eventStream {
            FSEventStreamFlushSync(eventStream)
        }
    }

    // MARK: - Event IDs

    /// Returns the latest event ID processed by the active stream.
    ///
    /// If the stream is not running, returns `kFSEventStreamEventIdSinceNow`.
    /// Use this value to persist the stream position before stopping the monitor,
    /// then pass it as `sinceWhen` on the next launch to replay missed events.
    func currentEventId() -> FSEventStreamEventId {
        stateLock.lock()
        let eventStream = stream
        stateLock.unlock()

        if let eventStream {
            return FSEventStreamGetLatestEventId(eventStream)
        }
        return FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
    }

    /// Returns the system-wide current FSEvents event ID.
    ///
    /// This represents the most recent event ID across all volumes. Useful for
    /// capturing a baseline event ID before starting a scan, so that on the next
    /// launch you can pass it as `sinceWhen` to detect changes that occurred
    /// while the app was not running.
    static func currentSystemEventId() -> UInt64 {
        FSEventsGetCurrentEventId()
    }

    // MARK: - Stream Callback

    /// The C function pointer callback for FSEventStreamCreate.
    ///
    /// This bridges from the C callback into Swift by recovering the
    /// `FSEventsMonitor` instance from the context info pointer.
    private static let streamCallback: FSEventStreamCallback = {
        (
            streamRef: ConstFSEventStreamRef,
            clientCallbackInfo: UnsafeMutableRawPointer?,
            numEvents: Int,
            eventPaths: UnsafeMutableRawPointer,
            eventFlags: UnsafePointer<FSEventStreamEventFlags>,
            eventIds: UnsafePointer<FSEventStreamEventId>
        ) in

        guard let info = clientCallbackInfo else { return }
        let monitor = Unmanaged<FSEventsMonitor>.fromOpaque(info).takeUnretainedValue()

        // eventPaths is a CFArray of CFString when kFSEventStreamCreateFlagUseCFTypes is set
        guard let pathArray = unsafeBitCast(eventPaths, to: CFArray?.self) else { return }

        var events = [Event]()
        events.reserveCapacity(numEvents)

        for i in 0..<numEvents {
            let cfPath = unsafeBitCast(CFArrayGetValueAtIndex(pathArray, i), to: CFString.self)
            let path = cfPath as String
            let flags = eventFlags[i]
            let eventId = eventIds[i]

            events.append(Event(path: path, flags: flags, eventId: eventId))
        }

        if !events.isEmpty {
            monitor.eventHandler(events)
        }
    }
}
