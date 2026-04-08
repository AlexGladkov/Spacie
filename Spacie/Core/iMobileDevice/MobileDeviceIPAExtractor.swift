import Foundation

// MARK: - MobileDeviceIPAExtractor
//
// Extracts IPA files from connected iOS devices using Apple's private
// MobileDevice.framework (the same API used by iMazing / Apple Configurator 2).
//
// Primary function: AMDeviceSecureArchiveApplication — the *signed-protocol*
// variant that works on iOS 7+, unlike the legacy instproxy_archive which Apple
// disabled client-side in iOS 7.
//
// Pipeline:
//   1. AMDeviceNotificationSubscribe  → get AMDeviceRef for target UDID
//   2. AMDeviceConnect + AMDeviceStartSession
//   3. AMDeviceSecureArchiveApplication → device creates
//      ApplicationArchives/<bundleID>.zip via AFC
//   4. AMDeviceStartService("com.apple.afc") → AFCConnectionOpen → download file
//   5. Return local .ipa URL

actor MobileDeviceIPAExtractor {

    // MARK: - Singleton

    static let shared = MobileDeviceIPAExtractor()

    // MARK: - Framework Handle

    // nonisolated(unsafe): the handle is written once at startup before any
    // concurrent access; safe to share as a read-only pointer thereafter.
    nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? = {
        dlopen(
            "/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice",
            RTLD_NOW | RTLD_GLOBAL
        )
    }()

    nonisolated static var isAvailable: Bool { handle != nil }

    private static func sym<T>(_ name: String) -> T? {
        guard let h = handle, let ptr = dlsym(h, name) else { return nil }
        return unsafeBitCast(ptr, to: T.self)
    }

    // MARK: - C Type Aliases (raw pointer types for C function signatures)

    typealias AMDeviceRef   = OpaquePointer
    typealias AMNotifRef    = OpaquePointer
    typealias ServiceSocket = Int32
    typealias AFCConnRef    = OpaquePointer
    typealias AFCDirRef     = OpaquePointer
    typealias AFCFileRef    = UInt64

    private static let kConnected:    UInt32 = 1
    private static let kDisconnected: UInt32 = 2
    private static let AFC_RDONLY:    UInt64 = 0x0000_0001

    // MARK: - Sendable wrappers for C pointer types
    //
    // Swift 6 region-based isolation tracks where values originate from.
    // Pointers loaded from C callbacks are in the "non-transferable region"
    // and cannot be passed into Task {} or continuation.resume() directly.
    // Wrapping them in @unchecked Sendable structs explicitly acknowledges
    // the transfer is intentional and safe (these are MobileDevice.framework
    // managed objects with well-defined lifetimes).

    struct SendableDevice: @unchecked Sendable {
        let ref: AMDeviceRef
        init(_ ref: AMDeviceRef) { self.ref = ref }
    }

    private struct SendableNotifRef: @unchecked Sendable {
        let ref: AMNotifRef?
    }

    // MARK: - C Function Signatures

    // Notification callback receives an opaque pointer whose first two fields
    // are (AMDeviceRef dev, UInt32 msg). Using UnsafeRawPointer avoids the
    // Swift struct representability restriction on @convention(c).
    typealias NotifCB    = @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void
    typealias StatusCB   = @convention(c) (CFDictionary?,     UnsafeMutableRawPointer?) -> Void

    typealias SubscribeFn   = @convention(c) (NotifCB,  Int32, Int32, UnsafeMutableRawPointer?, UnsafeMutablePointer<AMNotifRef?>?) -> Int32
    typealias UnsubscribeFn = @convention(c) (AMNotifRef) -> Int32
    typealias CopyIDFn      = @convention(c) (AMDeviceRef) -> Unmanaged<CFString>?
    typealias ConnectFn     = @convention(c) (AMDeviceRef) -> Int32
    typealias StartSessFn   = @convention(c) (AMDeviceRef) -> Int32
    typealias StopSessFn    = @convention(c) (AMDeviceRef) -> Int32
    typealias DisconnFn     = @convention(c) (AMDeviceRef) -> Int32
    typealias ArchiveFn     = @convention(c) (Int32, AMDeviceRef, CFString, CFDictionary?, StatusCB, UnsafeMutableRawPointer?) -> Int32
    typealias StartSvcFn    = @convention(c) (AMDeviceRef, CFString, UnsafeMutablePointer<ServiceSocket>?, UnsafeMutableRawPointer?) -> Int32
    typealias AFCOpenFn     = @convention(c) (ServiceSocket, Int32, UnsafeMutablePointer<AFCConnRef?>?) -> Int32
    typealias AFCCloseFn    = @convention(c) (AFCConnRef) -> Int32
    typealias AFCFInfoFn    = @convention(c) (AFCConnRef, UnsafePointer<CChar>, UnsafeMutablePointer<AFCDirRef?>?) -> Int32
    typealias AFCKVReadFn   = @convention(c) (AFCDirRef, UnsafeMutablePointer<UnsafePointer<CChar>?>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
    typealias AFCKVCloseFn  = @convention(c) (AFCDirRef) -> Int32
    typealias AFCFOpenFn    = @convention(c) (AFCConnRef, UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<AFCFileRef>?) -> Int32
    typealias AFCFReadFn    = @convention(c) (AFCConnRef, AFCFileRef, UnsafeMutableRawPointer, UnsafeMutablePointer<UInt32>) -> Int32
    typealias AFCFCloseFn   = @convention(c) (AFCConnRef, AFCFileRef) -> Int32

    // MARK: - Resolved Symbols

    private static var _subscribe:   SubscribeFn?   { sym("AMDeviceNotificationSubscribe") }
    private static var _unsubscribe: UnsubscribeFn? { sym("AMDeviceNotificationUnsubscribe") }
    private static var _copyID:      CopyIDFn?      { sym("AMDeviceCopyDeviceIdentifier") }
    private static var _connect:     ConnectFn?     { sym("AMDeviceConnect") }
    private static var _startSess:   StartSessFn?   { sym("AMDeviceStartSession") }
    private static var _stopSess:    StopSessFn?    { sym("AMDeviceStopSession") }
    private static var _disconnect:  DisconnFn?     { sym("AMDeviceDisconnect") }
    private static var _archive:     ArchiveFn?     { sym("AMDeviceSecureArchiveApplication") }
    private static var _startSvc:    StartSvcFn?    { sym("AMDeviceStartService") }
    private static var _afcOpen:     AFCOpenFn?     { sym("AFCConnectionOpen") }
    private static var _afcClose:    AFCCloseFn?    { sym("AFCConnectionClose") }
    private static var _afcFInfo:    AFCFInfoFn?    { sym("AFCFileInfoOpen") }
    private static var _afcKVRead:   AFCKVReadFn?   { sym("AFCKeyValueRead") }
    private static var _afcKVClose:  AFCKVCloseFn?  { sym("AFCKeyValueClose") }
    private static var _afcFOpen:    AFCFOpenFn?    { sym("AFCFileRefOpen") }
    private static var _afcFRead:    AFCFReadFn?    { sym("AFCFileRefRead") }
    private static var _afcFClose:   AFCFCloseFn?   { sym("AFCFileRefClose") }

    // MARK: - Errors

    enum ExtractorError: Error, LocalizedError {
        case frameworkUnavailable
        case deviceNotFound(String)
        case connectionFailed(Int32)
        case sessionFailed(Int32)
        case archiveFailed(String)
        case ipaNotFoundOnDevice(String)
        case afcFailed(String)

        var errorDescription: String? {
            switch self {
            case .frameworkUnavailable:       return "MobileDevice.framework unavailable"
            case .deviceNotFound(let u):      return "Device \(u) not seen after 5 s"
            case .connectionFailed(let c):    return "AMDeviceConnect failed (err \(c))"
            case .sessionFailed(let c):       return "AMDeviceStartSession failed (err \(c))"
            case .archiveFailed(let r):       return "Archive failed: \(r)"
            case .ipaNotFoundOnDevice(let p): return "IPA not found on device at \(p)"
            case .afcFailed(let r):           return "AFC error: \(r)"
            }
        }
    }

    // MARK: - Actor State

    /// UDID → SendableDevice for devices seen by the notification callback.
    private var registry: [String: SendableDevice] = [:]
    /// Handlers waiting for a specific UDID to appear in the registry.
    private var waiters:  [String: [CheckedContinuation<SendableDevice, Error>]] = [:]

    private var notifThread: Thread?
    private var notifRef:    AMNotifRef?

    private init() {}

    // MARK: - Notification Thread

    /// Starts the MobileDevice notification run loop (idempotent).
    func startListening() {
        guard notifThread == nil, Self.isAvailable else { return }

        let thread = Thread { [weak self] in
            guard let self else { return }

            // Bridge: pass actor reference as unretained opaque pointer.
            // The run loop keeps the thread alive; the actor outlives the thread.
            let ctx = Unmanaged.passUnretained(self).toOpaque()

            let cb: NotifCB = { rawInfo, userData in
                guard let rawInfo, let userData else { return }
                // Layout: AMDeviceRef (8 bytes) | UInt32 msg (4 bytes)
                let rawDev = rawInfo.load(as: OpaquePointer.self)
                let msg = rawInfo.load(fromByteOffset: MemoryLayout<UnsafeRawPointer>.size,
                                       as: UInt32.self)
                let me = Unmanaged<MobileDeviceIPAExtractor>.fromOpaque(userData).takeUnretainedValue()
                // Wrap in @unchecked Sendable to cross the C→Swift isolation boundary.
                let dev = MobileDeviceIPAExtractor.SendableDevice(rawDev)
                Task { await me.handleEvent(dev: dev, msg: msg) }
            }

            var rawRef: AMNotifRef?
            _ = Self._subscribe?(cb, 0, 0, ctx, &rawRef)
            // Wrap optional OpaquePointer in @unchecked Sendable before crossing to actor.
            let notifBundle = SendableNotifRef(ref: rawRef)
            Task { await self.setNotifRef(notifBundle.ref) }

            CFRunLoopRun()
        }
        thread.name = "MobileDeviceIPAExtractor"
        thread.qualityOfService = .userInitiated
        thread.start()
        notifThread = thread
    }

    private func setNotifRef(_ ref: AMNotifRef?) {
        notifRef = ref
    }

    // MARK: - Event Handler (actor-isolated)

    private func handleEvent(dev: SendableDevice, msg: UInt32) {
        guard let udidCF = Self._copyID?(dev.ref)?.takeRetainedValue() else { return }
        let udid = udidCF as String

        if msg == Self.kConnected {
            registry[udid] = dev
            let pending = waiters.removeValue(forKey: udid) ?? []
            pending.forEach { $0.resume(returning: dev) }
        } else if msg == Self.kDisconnected {
            registry.removeValue(forKey: udid)
        }
    }

    // MARK: - Wait for Device

    /// Returns the SendableDevice for the given UDID, waiting up to `timeout` seconds.
    private func waitForDevice(udid: String, timeout: TimeInterval = 5) async throws -> SendableDevice {
        if let dev = registry[udid] { return dev }

        return try await withCheckedThrowingContinuation { cont in
            // Re-check under actor isolation.
            if let dev = registry[udid] {
                cont.resume(returning: dev)
                return
            }
            waiters[udid, default: []].append(cont)

            // Timeout.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self else { return }
                await self.cancelWaiter(udid: udid, continuation: cont)
            }
        }
    }

    private func cancelWaiter(
        udid: String,
        continuation: CheckedContinuation<SendableDevice, Error>
    ) {
        guard waiters[udid] != nil else { return }
        waiters.removeValue(forKey: udid)
        continuation.resume(throwing: ExtractorError.deviceNotFound(udid))
    }

    // MARK: - Public: extractIPA

    func extractIPA(
        udid: String,
        bundleID: String,
        destinationDir: URL,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard Self.isAvailable else { throw ExtractorError.frameworkUnavailable }

        startListening()

        let device = try await waitForDevice(udid: udid)

        let cErr = Self._connect?(device.ref) ?? -1
        guard cErr == 0 else { throw ExtractorError.connectionFailed(cErr) }

        let sErr = Self._startSess?(device.ref) ?? -1
        guard sErr == 0 else {
            _ = Self._disconnect?(device.ref)
            throw ExtractorError.sessionFailed(sErr)
        }

        let ipaURL: URL
        do {
            ipaURL = try await archive(
                device: device,
                bundleID: bundleID,
                destinationDir: destinationDir,
                progressHandler: progressHandler
            )
        } catch {
            _ = Self._stopSess?(device.ref)
            _ = Self._disconnect?(device.ref)
            throw error
        }

        _ = Self._stopSess?(device.ref)
        _ = Self._disconnect?(device.ref)
        return ipaURL
    }

    // MARK: - Archive

    private func archive(
        device: SendableDevice,
        bundleID: String,
        destinationDir: URL,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let bridge = ArchiveBridge(
                continuation: cont,
                progressHandler: progressHandler,
                device: device,
                bundleID: bundleID,
                destinationDir: destinationDir
            )
            let ptr = Unmanaged.passRetained(bridge).toOpaque()

            let cb: StatusCB = { dictRef, userData in
                guard let userData else { return }
                let b = Unmanaged<ArchiveBridge>.fromOpaque(userData).takeUnretainedValue()
                guard !b.done else { return }

                let dict: [String: Any]
                if let cf = dictRef {
                    dict = (cf as AnyObject as? [String: Any]) ?? [:]
                } else {
                    dict = [:]
                }

                if let pct = (dict["PercentComplete"] as? NSNumber)?.doubleValue {
                    b.progressHandler(pct / 100.0)
                }

                let status   = dict["Status"] as? String ?? ""
                let errorStr = dict["Error"]  as? String

                if let errorStr {
                    b.done = true
                    b.continuation.resume(throwing: ExtractorError.archiveFailed(errorStr))
                    Unmanaged<ArchiveBridge>.fromOpaque(userData).release()
                } else if status == "Complete" {
                    b.done = true
                    let bundleID       = b.bundleID
                    let destinationDir = b.destinationDir
                    let device         = b.device
                    let cont           = b.continuation
                    Unmanaged<ArchiveBridge>.fromOpaque(userData).release()

                    Task.detached(priority: .high) {
                        do {
                            let url = try MobileDeviceIPAExtractor.downloadViaAFC(
                                device: device,
                                bundleID: bundleID,
                                destinationDir: destinationDir
                            )
                            cont.resume(returning: url)
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
            }

            let cfBundleID = bundleID as CFString
            let ret = Self._archive?(0, device.ref, cfBundleID, nil, cb, ptr) ?? -1

            if ret != 0 {
                Unmanaged<ArchiveBridge>.fromOpaque(ptr).release()
                cont.resume(throwing: ExtractorError.archiveFailed(
                    "AMDeviceSecureArchiveApplication returned \(ret)"
                ))
            }
        }
    }

    // MARK: - AFC Download

    /// Downloads `ApplicationArchives/<bundleID>.zip` from the device via AFC
    /// and saves it as `<destinationDir>/<bundleID>.ipa`.
    private static func downloadViaAFC(
        device: SendableDevice,
        bundleID: String,
        destinationDir: URL
    ) throws -> URL {
        guard
            let startSvc = _startSvc,
            let afcOpen  = _afcOpen,
            let afcClose = _afcClose,
            let fInfo    = _afcFInfo,
            let kvRead   = _afcKVRead,
            let kvClose  = _afcKVClose,
            let fOpen    = _afcFOpen,
            let fRead    = _afcFRead,
            let fClose   = _afcFClose
        else {
            throw ExtractorError.afcFailed("One or more AFC symbols missing")
        }

        // 1. Start AFC service.
        var socket: ServiceSocket = -1
        let svcErr = startSvc(device.ref, "com.apple.afc" as CFString, &socket, nil)
        guard svcErr == 0, socket >= 0 else {
            throw ExtractorError.afcFailed("StartService afc failed (\(svcErr))")
        }

        // 2. Open AFC connection.
        var conn: AFCConnRef?
        guard afcOpen(socket, 0, &conn) == 0, let conn else {
            Darwin.close(socket)
            throw ExtractorError.afcFailed("AFCConnectionOpen failed")
        }
        defer { _ = afcClose(conn) }

        // 3. Find the archive on the device.
        //    AMDeviceSecureArchiveApplication stores at ApplicationArchives/<id>.zip
        let remotePath = "ApplicationArchives/\(bundleID).zip"
        var fileSize: UInt64 = 0

        try remotePath.withCString { cPath throws in
            var infoDict: AFCDirRef?
            if fInfo(conn, cPath, &infoDict) == 0, let infoDict {
                var key: UnsafePointer<CChar>?
                var val: UnsafePointer<CChar>?
                while kvRead(infoDict, &key, &val) == 0 {
                    guard let key, let val else { break }
                    if String(cString: key) == "st_size" {
                        fileSize = UInt64(String(cString: val)) ?? 0
                    }
                }
                _ = kvClose(infoDict)
            }
        }

        guard fileSize > 0 else {
            throw ExtractorError.ipaNotFoundOnDevice(remotePath)
        }

        // 4. Open remote file for reading.
        var fileRef: AFCFileRef = 0
        let openErr: Int32 = try remotePath.withCString { cPath throws -> Int32 in
            fOpen(conn, cPath, AFC_RDONLY, &fileRef)
        }
        guard openErr == 0, fileRef != 0 else {
            throw ExtractorError.afcFailed("AFCFileRefOpen failed (\(openErr)) for \(remotePath)")
        }
        defer { _ = fClose(conn, fileRef) }

        // 5. Stream to local file.
        let localURL = destinationDir.appendingPathComponent("\(bundleID).ipa")
        guard let stream = OutputStream(url: localURL, append: false) else {
            throw ExtractorError.afcFailed("Cannot create output stream at \(localURL.path)")
        }
        stream.open()
        defer { stream.close() }

        let bufSize = 65_536
        let buffer  = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 1)
        defer { buffer.deallocate() }

        var written: UInt64 = 0
        while written < fileSize {
            var chunk = UInt32(min(UInt64(bufSize), fileSize - written))
            let readErr = fRead(conn, fileRef, buffer, &chunk)
            if readErr != 0 || chunk == 0 { break }
            stream.write(buffer.assumingMemoryBound(to: UInt8.self), maxLength: Int(chunk))
            written += UInt64(chunk)
        }

        guard written > 0 else {
            throw ExtractorError.afcFailed("Zero bytes read from \(remotePath)")
        }

        return localURL
    }
}

// MARK: - ArchiveBridge

/// Heap-allocated context bridging Swift continuation through the C callback.
private final class ArchiveBridge: @unchecked Sendable {
    let continuation:    CheckedContinuation<URL, Error>
    let progressHandler: @Sendable (Double) -> Void
    let device:          MobileDeviceIPAExtractor.SendableDevice
    let bundleID:        String
    let destinationDir:  URL
    var done = false

    init(
        continuation:    CheckedContinuation<URL, Error>,
        progressHandler: @escaping @Sendable (Double) -> Void,
        device:          MobileDeviceIPAExtractor.SendableDevice,
        bundleID:        String,
        destinationDir:  URL
    ) {
        self.continuation    = continuation
        self.progressHandler = progressHandler
        self.device          = device
        self.bundleID        = bundleID
        self.destinationDir  = destinationDir
    }
}
