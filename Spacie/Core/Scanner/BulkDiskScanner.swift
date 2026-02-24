import Foundation
import Darwin

// MARK: - BulkDiskScanner

/// High-performance macOS file system scanner using `getattrlistbulk()`.
///
/// Unlike ``DiskScanner`` which calls `fts_read` once per entry (one syscall per
/// file), `BulkDiskScanner` retrieves attributes for hundreds of entries in a
/// single `getattrlistbulk` call. This dramatically reduces syscall overhead and
/// is the key optimization for scanning 9M+ files quickly on APFS volumes.
///
/// Falls back to ``DiskScanner`` for individual directories on file systems that
/// do not support `getattrlistbulk` (e.g. certain network volumes).
///
/// ## Performance Targets
/// - 1M files in < 5 seconds on SSD
/// - 9M files in < 60 seconds on SSD
///
/// ## Usage
/// ```swift
/// let scanner = BulkDiskScanner()
/// let stream = scanner.scan(configuration: config)
/// for await event in stream {
///     switch event { ... }
/// }
/// ```
final class BulkDiskScanner: Sendable {

    // MARK: - Initialization

    init() {}

    // MARK: - Public API

    /// Starts scanning the file system at the configured root path.
    ///
    /// Returns an `AsyncStream` of ``ScanEvent`` that emits file discoveries,
    /// progress updates, errors, and a final completion event. Supports
    /// cooperative cancellation via `Task.isCancelled`.
    ///
    /// - Parameter configuration: Scan parameters including root path, batch size, etc.
    /// - Returns: An asynchronous stream of scan events.
    func scan(configuration: ScanConfiguration) -> AsyncStream<ScanEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(4096)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                Self.performScan(configuration: configuration, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Work Item

    /// Represents a directory waiting to be scanned on the explicit DFS stack.
    private struct WorkItem {
        /// File descriptor of the parent directory, or `-1` if this item
        /// should be opened by absolute path (e.g. the root).
        let dirFD: Int32
        /// Absolute path of the directory.
        let path: String
        /// Depth relative to the scan root (root = 0).
        let depth: Int
        /// Base name of the directory (used for `openat`).
        let name: String
    }

    // MARK: - Constants

    /// Size of the attribute buffer passed to `getattrlistbulk`.
    /// 256 KB accommodates hundreds of entries per call.
    private static let bufferSize = 256 * 1024

    // vtype raw values from <sys/vnode.h> — avoid Swift bridging issues with C enums
    private static let vtypeReg: UInt32 = 1   // VREG
    private static let vtypeDir: UInt32 = 2   // VDIR
    private static let vtypeLnk: UInt32 = 5   // VLNK

    // MARK: - Core Scan Implementation

    /// Performs the actual file tree scan synchronously on the calling thread.
    ///
    /// This method is intentionally non-async to avoid unnecessary suspension points
    /// in the hot loop. It runs on a detached task with `.userInitiated` priority.
    private static func performScan(
        configuration: ScanConfiguration,
        continuation: AsyncStream<ScanEvent>.Continuation
    ) {
        let rootPath = configuration.rootPath.path(percentEncoded: false)

        // --- Counters ---
        var filesScanned: UInt64 = 0
        var directoriesScanned: UInt64 = 0
        var totalLogicalSize: UInt64 = 0
        var totalPhysicalSize: UInt64 = 0
        var restrictedDirectories: UInt64 = 0
        var skippedDirectories: UInt64 = 0

        // Hard link dedup: track seen inodes to avoid double-counting sizes.
        // Only files with link count > 1 are checked, keeping this set small.
        var seenInodes = Set<UInt64>()

        // Batch accumulation for throttled progress reporting
        var batchCount = 0
        let batchSize = configuration.batchSize

        // Timing
        let startTime = ContinuousClock.now
        var lastProgressTime = startTime

        // --- Determine root device for cross-mount-point filtering ---
        var rootDev: dev_t = 0
        if !configuration.crossMountPoints {
            var rootStat = stat()
            if lstat(rootPath, &rootStat) == 0 {
                rootDev = rootStat.st_dev
            }
        }

        // --- Attribute list configuration ---
        // Configured once, reused for every getattrlistbulk call.
        var attrList = attrlist()
        attrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        let commonAttrs: attrgroup_t = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_FLAGS)
            | attrgroup_t(ATTR_CMN_FILEID)
            | attrgroup_t(ATTR_CMN_MODTIME)
        attrList.commonattr = commonAttrs
        let fileAttrs: attrgroup_t = attrgroup_t(ATTR_FILE_LINKCOUNT)
            | attrgroup_t(ATTR_FILE_DATALENGTH)
            | attrgroup_t(ATTR_FILE_DATAALLOCSIZE)
        attrList.fileattr = fileAttrs

        // --- Allocate reusable buffer ---
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferSize,
            alignment: MemoryLayout<UInt64>.alignment
        )
        defer { buffer.deallocate() }

        // --- Explicit DFS stack ---
        var stack: [WorkItem] = []
        stack.reserveCapacity(256)
        stack.append(WorkItem(dirFD: -1, path: rootPath, depth: 0, name: ""))

        // --- Fallback scanner (lazy) ---
        // Created only if getattrlistbulk is unsupported for some directory.
        var fallbackScanner: DiskScanner?

        // --- Main DFS loop ---
        while let workItem = stack.popLast() {
            if Task.isCancelled { break }

            let dirPath = workItem.path
            let depth = workItem.depth

            // --- Open directory ---
            let dirFD: Int32
            if workItem.dirFD == -1 || workItem.name.isEmpty {
                // Open by absolute path (root or fallback case)
                dirFD = open(dirPath, O_RDONLY | O_DIRECTORY)
            } else {
                // Open relative to parent FD for efficiency
                dirFD = workItem.name.withCString { nameCStr in
                    openat(workItem.dirFD, nameCStr, O_RDONLY | O_DIRECTORY)
                }
            }

            if dirFD == -1 {
                let code = errno
                if code == EACCES || code == EPERM {
                    restrictedDirectories &+= 1
                    continuation.yield(.restricted(path: dirPath))

                    let name = Self.basename(of: dirPath)
                    let rawNode = RawFileNode(
                        name: name,
                        path: dirPath,
                        logicalSize: 0,
                        physicalSize: 0,
                        flags: [.isDirectory, .isRestricted],
                        fileType: .system,
                        modTime: 0,
                        inode: 0,
                        depth: depth,
                        parentPath: Self.parentPath(of: dirPath)
                    )
                    continuation.yield(.fileFound(node: rawNode))
                } else {
                    continuation.yield(.error(
                        path: dirPath,
                        code: code,
                        message: String(cString: strerror(code))
                    ))
                }
                continue
            }

            // --- Cross mount-point check ---
            if !configuration.crossMountPoints && depth > 0 {
                var dirStat = Darwin.stat()
                if fstat(dirFD, &dirStat) == 0 && dirStat.st_dev != rootDev {
                    close(dirFD)
                    skippedDirectories &+= 1
                    continuation.yield(.directorySkipped(path: dirPath, depth: depth))
                    continue
                }
            }

            directoriesScanned &+= 1
            continuation.yield(.directoryEntered(path: dirPath, depth: depth))

            // --- Accumulated directory size ---
            var directoryTotalSize: UInt64 = 0

            // NOTE: No subdirectory recursion — DeepScanner already has ALL
            // directories from the shallow tree. Each BulkDiskScanner call
            // processes exactly one directory level.

            // --- getattrlistbulk loop ---
            var bulkFailed = false
            var entryLoop = true
            while entryLoop {
                if Task.isCancelled { break }

                let count = getattrlistbulk(
                    dirFD,
                    &attrList,
                    buffer,
                    bufferSize,
                    0
                )

                if count == 0 {
                    // No more entries
                    break
                }

                if count == -1 {
                    let code = errno
                    if code == ENOTSUP || code == EINVAL {
                        // File system does not support getattrlistbulk.
                        // Fall back to DiskScanner for this single directory.
                        bulkFailed = true
                        break
                    }
                    // Transient error — report and stop this directory
                    continuation.yield(.error(
                        path: dirPath,
                        code: code,
                        message: String(cString: strerror(code))
                    ))
                    entryLoop = false
                    break
                }

                // --- Parse entries from buffer ---
                var offset = 0
                for _ in 0..<count {
                    if Task.isCancelled { break }

                    let entryBase = buffer.advanced(by: offset)

                    // Entry length (first UInt32)
                    let entryLength = Int(entryBase.load(as: UInt32.self))
                    guard entryLength > 0 else { break }
                    defer { offset += entryLength }

                    var fieldPtr = entryBase.advanced(by: MemoryLayout<UInt32>.size)

                    // --- ATTR_CMN_RETURNED_ATTRS (attribute_set_t) ---
                    // Always first when requested.
                    let returnedAttrs = fieldPtr.load(as: attribute_set_t.self)
                    fieldPtr = fieldPtr.advanced(by: MemoryLayout<attribute_set_t>.size)

                    // -------------------------------------------------------
                    // IMPORTANT: Attributes are packed in bit-value order from
                    // sys/attr.h, NOT in the order we listed them in attrList.
                    // RETURNED_ATTRS is special (always first).
                    // The remaining common attrs follow bit order:
                    //   NAME(0x01) → OBJTYPE(0x08) → MODTIME(0x400)
                    //   → FLAGS(0x40000) → FILEID(0x2000000) → ERROR(0x20000000)
                    // -------------------------------------------------------

                    // ---------------------------------------------------------------
                    // CRITICAL: getattrlistbulk only includes data in the buffer
                    // for attributes whose bit IS set in returned_attrs.
                    // If an attribute is NOT returned, its bytes are NOT in the
                    // buffer — no "holes". We must only advance fieldPtr when
                    // the attribute is actually present.
                    // ---------------------------------------------------------------

                    // --- 1. ATTR_CMN_NAME (bit 0, attrreference_t) ---
                    let hasName = (returnedAttrs.commonattr & attrgroup_t(ATTR_CMN_NAME)) != 0
                    var nameString = ""
                    if hasName {
                        let nameRefPtr = fieldPtr
                        let nameRef = fieldPtr.load(as: attrreference_t.self)
                        let nameCStr = nameRefPtr
                            .advanced(by: Int(nameRef.attr_dataoffset))
                            .assumingMemoryBound(to: CChar.self)
                        nameString = String(cString: nameCStr)
                        fieldPtr = fieldPtr.advanced(by: MemoryLayout<attrreference_t>.size)
                    }

                    // --- 2. ATTR_CMN_OBJTYPE (bit 3, UInt32) ---
                    var objType: UInt32 = 0
                    if (returnedAttrs.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE)) != 0 {
                        objType = fieldPtr.load(as: UInt32.self)
                        fieldPtr = fieldPtr.advanced(by: MemoryLayout<UInt32>.size)
                    }

                    // --- 3. ATTR_CMN_MODTIME (bit 10, timespec) ---
                    var modTimeSec: UInt32 = 0
                    if (returnedAttrs.commonattr & attrgroup_t(ATTR_CMN_MODTIME)) != 0 {
                        let tvSec = fieldPtr.loadUnaligned(as: Int.self)
                        modTimeSec = UInt32(truncatingIfNeeded: tvSec)
                        fieldPtr = fieldPtr.advanced(by: MemoryLayout<timespec>.size)
                    }

                    // --- 4. ATTR_CMN_FLAGS (bit 18, UInt32) ---
                    var bsdFlags: UInt32 = 0
                    if (returnedAttrs.commonattr & attrgroup_t(ATTR_CMN_FLAGS)) != 0 {
                        bsdFlags = fieldPtr.load(as: UInt32.self)
                        fieldPtr = fieldPtr.advanced(by: MemoryLayout<UInt32>.size)
                    }

                    // --- 5. ATTR_CMN_FILEID (bit 25, UInt64) ---
                    var inode: UInt64 = 0
                    if (returnedAttrs.commonattr & attrgroup_t(ATTR_CMN_FILEID)) != 0 {
                        inode = fieldPtr.loadUnaligned(as: UInt64.self)
                        fieldPtr = fieldPtr.advanced(by: MemoryLayout<UInt64>.size)
                    }

                    // --- 6. ATTR_CMN_ERROR (bit 29, UInt32) ---
                    // Only present when the entry has an error; absent for normal entries.
                    var entryError: Int32 = 0
                    if (returnedAttrs.commonattr & attrgroup_t(ATTR_CMN_ERROR)) != 0 {
                        entryError = fieldPtr.load(as: Int32.self)
                        fieldPtr = fieldPtr.advanced(by: MemoryLayout<Int32>.size)
                    }

                    // If this entry had an error, skip it
                    if entryError != 0 {
                        continue
                    }

                    // --- File-specific attributes (bit order: LINKCOUNT → DATALENGTH → DATAALLOCSIZE) ---
                    var linkCount: UInt32 = 1
                    var dataLength: Int64 = 0
                    var dataAllocSize: Int64 = 0

                    // ATTR_FILE_LINKCOUNT (bit 0, UInt32)
                    if (returnedAttrs.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT)) != 0 {
                        linkCount = fieldPtr.load(as: UInt32.self)
                        fieldPtr = fieldPtr.advanced(by: MemoryLayout<UInt32>.size)
                    }

                    // ATTR_FILE_DATALENGTH (bit 9, off_t / Int64) — use loadUnaligned
                    if (returnedAttrs.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH)) != 0 {
                        dataLength = fieldPtr.loadUnaligned(as: Int64.self)
                        fieldPtr = fieldPtr.advanced(by: MemoryLayout<Int64>.size)
                    }

                    // ATTR_FILE_DATAALLOCSIZE (bit 10, off_t / Int64) — use loadUnaligned
                    if (returnedAttrs.fileattr & attrgroup_t(ATTR_FILE_DATAALLOCSIZE)) != 0 {
                        dataAllocSize = fieldPtr.loadUnaligned(as: Int64.self)
                        fieldPtr = fieldPtr.advanced(by: MemoryLayout<Int64>.size)
                    }

                    // --- Skip . and .. ---
                    if nameString == "." || nameString == ".." {
                        continue
                    }

                    // --- Hidden check: first character is '.' ---
                    let isHidden: Bool
                    if hasName, !nameString.isEmpty {
                        isHidden = nameString.utf8.first == 0x2E // '.'
                    } else {
                        isHidden = false
                    }

                    // --- Skip hidden if not including hidden ---
                    if isHidden && !configuration.includeHidden {
                        continue
                    }

                    // --- Build child path ---
                    let childPath: String
                    if dirPath == "/" {
                        childPath = "/" + nameString
                    } else {
                        childPath = dirPath + "/" + nameString
                    }

                    let childDepth = depth + 1

                    // --- Process by object type ---
                    switch objType {
                    case Self.vtypeDir:
                        // Directory entry — emit node but do NOT recurse.
                        // DeepScanner handles all directories from the shallow tree.
                        var dirNodeFlags: FileNodeFlags = [.isDirectory]
                        if isHidden { dirNodeFlags.insert(.isHidden) }

                        // Check exclusion rules
                        if configuration.exclusionRules.shouldExclude(
                            name: nameString,
                            path: childPath
                        ) {
                            skippedDirectories &+= 1
                            dirNodeFlags.insert(.isExcluded)

                            let rawNode = RawFileNode(
                                name: nameString,
                                path: childPath,
                                logicalSize: 0,
                                physicalSize: 0,
                                flags: dirNodeFlags,
                                fileType: .other,
                                modTime: modTimeSec,
                                inode: inode,
                                depth: childDepth,
                                parentPath: dirPath,
                                dirMtime: UInt64(modTimeSec)
                            )
                            continuation.yield(.fileFound(node: rawNode))
                            continuation.yield(.directorySkipped(
                                path: childPath,
                                depth: childDepth
                            ))
                            continue
                        }

                        if Self.isPackageExtension(nameString) {
                            dirNodeFlags.insert(.isPackage)
                        }
                        // Don't increment directoriesScanned here — each child
                        // directory will be counted at line 216 when DeepScanner
                        // processes it as a root of its own BulkDiskScanner scan.

                        let rawNode = RawFileNode(
                            name: nameString,
                            path: childPath,
                            logicalSize: 0,
                            physicalSize: 0,
                            flags: dirNodeFlags,
                            fileType: Self.isPackageExtension(nameString) ? .application : .other,
                            modTime: modTimeSec,
                            inode: inode,
                            depth: childDepth,
                            parentPath: dirPath,
                            dirMtime: UInt64(modTimeSec)
                        )
                        continuation.yield(.fileFound(node: rawNode))
                        continuation.yield(.directoryEntered(
                            path: childPath,
                            depth: childDepth
                        ))

                    case Self.vtypeReg:
                        // Regular file
                        var flags: FileNodeFlags = []
                        if isHidden { flags.insert(.isHidden) }
                        if (bsdFlags & UInt32(UF_COMPRESSED)) != 0 {
                            flags.insert(.isCompressed)
                        }

                        var effectiveLogical = UInt64(max(0, dataLength))
                        var effectivePhysical = UInt64(max(0, dataAllocSize))

                        // Hard link deduplication
                        if linkCount > 1 {
                            flags.insert(.isHardLink)
                            if !seenInodes.insert(inode).inserted {
                                effectiveLogical = 0
                                effectivePhysical = 0
                            }
                        }

                        totalLogicalSize &+= effectiveLogical
                        totalPhysicalSize &+= effectivePhysical
                        directoryTotalSize &+= effectiveLogical
                        filesScanned &+= 1
                        batchCount &+= 1

                        let ext = Self.fileExtension(from: nameString)
                        let fileType = FileType.from(extension: ext)

                        let rawNode = RawFileNode(
                            name: nameString,
                            path: childPath,
                            logicalSize: effectiveLogical,
                            physicalSize: effectivePhysical,
                            flags: flags,
                            fileType: fileType,
                            modTime: modTimeSec,
                            inode: inode,
                            depth: childDepth,
                            parentPath: dirPath
                        )
                        continuation.yield(.fileFound(node: rawNode))

                    case Self.vtypeLnk:
                        // Symbolic link
                        var flags: FileNodeFlags = [.isSymlink]
                        if isHidden { flags.insert(.isHidden) }
                        filesScanned &+= 1

                        let rawNode = RawFileNode(
                            name: nameString,
                            path: childPath,
                            logicalSize: 0,
                            physicalSize: 0,
                            flags: flags,
                            fileType: .other,
                            modTime: modTimeSec,
                            inode: inode,
                            depth: childDepth,
                            parentPath: dirPath
                        )
                        continuation.yield(.fileFound(node: rawNode))

                    default:
                        // Other object types (VBLK, VCHR, VFIFO, VSOCK, etc.) — skip
                        break
                    }

                    // --- Throttled progress emission ---
                    if batchCount >= batchSize {
                        batchCount = 0
                        let now = ContinuousClock.now
                        let sinceLastProgress = now - lastProgressTime
                        let throttleNanos = Int(
                            configuration.throttleInterval * 1_000_000_000
                        )
                        if sinceLastProgress >= .nanoseconds(throttleNanos) {
                            lastProgressTime = now
                            let totalElapsed = now - startTime
                            let elapsedSeconds = Double(
                                totalElapsed.components.seconds
                            ) + Double(totalElapsed.components.attoseconds) / 1e18

                            continuation.yield(.progress(ScanProgress(
                                filesScanned: filesScanned,
                                directoriesScanned: directoriesScanned,
                                skippedDirectories: skippedDirectories,
                                totalLogicalSizeScanned: totalLogicalSize,
                                totalPhysicalSizeScanned: totalPhysicalSize,
                                currentPath: dirPath,
                                elapsedTime: elapsedSeconds,
                                estimatedTotalFiles: nil
                            )))
                        }
                    }
                }
            }

            // --- Capture directory mtime before closing FD ---
            var dirMtimeValue: UInt64 = 0
            var dirStat = Darwin.stat()
            if fstat(dirFD, &dirStat) == 0 {
                dirMtimeValue = UInt64(dirStat.st_mtimespec.tv_sec)
            }

            // --- Close directory FD ---
            close(dirFD)

            // --- Fallback for unsupported file systems ---
            if bulkFailed {
                if fallbackScanner == nil {
                    fallbackScanner = DiskScanner()
                }
                // Create a sub-configuration rooted at this directory.
                // The fallback DiskScanner will scan this one directory tree
                // and emit events. We forward them but NOTE: this is a full
                // subtree scan via fts, so we skip pushing subdirs.
                let subConfig = ScanConfiguration(
                    rootPath: URL(filePath: dirPath),
                    volumeId: configuration.volumeId,
                    followSymlinks: configuration.followSymlinks,
                    crossMountPoints: configuration.crossMountPoints,
                    includeHidden: configuration.includeHidden,
                    batchSize: configuration.batchSize,
                    throttleInterval: configuration.throttleInterval,
                    exclusionRules: configuration.exclusionRules
                )
                // Synchronously consume fallback events on this same thread.
                // We use a semaphore to bridge async → sync since we are
                // already on a detached task.
                let fallbackStream = fallbackScanner!.scan(configuration: subConfig)
                let statsBox = FallbackStatsBox()
                let semaphore = DispatchSemaphore(value: 0)

                Task { @Sendable in
                    for await event in fallbackStream {
                        switch event {
                        case .completed(let stats):
                            statsBox.stats = stats
                        default:
                            continuation.yield(event)
                        }
                    }
                    semaphore.signal()
                }
                semaphore.wait()

                if let stats = statsBox.stats {
                    filesScanned &+= stats.totalFiles
                    directoriesScanned &+= stats.totalDirectories
                    totalLogicalSize &+= stats.totalLogicalSize
                    totalPhysicalSize &+= stats.totalPhysicalSize
                    restrictedDirectories &+= stats.restrictedDirectories
                    skippedDirectories &+= stats.skippedDirectories
                }

                // Do NOT push subdirs — fallback already scanned the subtree
                continue
            }

            // --- Emit directory completion ---
            continuation.yield(.directoryCompleted(
                path: dirPath,
                totalSize: directoryTotalSize
            ))

            // --- Emit directory node itself ---
            let dirName = Self.basename(of: dirPath)
            var dirFlags: FileNodeFlags = [.isDirectory]
            if !dirName.isEmpty && dirName.utf8.first == 0x2E {
                dirFlags.insert(.isHidden)
            }
            if isPackageExtension(dirName) {
                dirFlags.insert(.isPackage)
            }

            let dirNode = RawFileNode(
                name: dirName,
                path: dirPath,
                logicalSize: 0,
                physicalSize: 0,
                flags: dirFlags,
                fileType: isPackageExtension(dirName) ? .application : .other,
                modTime: UInt32(truncatingIfNeeded: dirMtimeValue),
                inode: dirStat.st_ino,
                depth: depth,
                parentPath: Self.parentPath(of: dirPath),
                dirMtime: dirMtimeValue
            )
            continuation.yield(.fileFound(node: dirNode))

            // No subdirectory push — single-level scan only.
        }

        // --- Completion ---
        let totalDuration = ContinuousClock.now - startTime
        let durationSeconds = Double(totalDuration.components.seconds)
            + Double(totalDuration.components.attoseconds) / 1e18

        continuation.yield(.completed(stats: ScanStats(
            totalFiles: filesScanned,
            totalDirectories: directoriesScanned,
            totalLogicalSize: totalLogicalSize,
            totalPhysicalSize: totalPhysicalSize,
            restrictedDirectories: restrictedDirectories,
            skippedDirectories: skippedDirectories,
            scanDuration: durationSeconds,
            volumeId: configuration.volumeId
        )))
    }

    // MARK: - Path Utilities

    /// Extracts the file extension from a filename by scanning backwards.
    ///
    /// Uses manual character scanning for performance in the hot loop,
    /// avoiding `NSString.pathExtension` overhead.
    private static func fileExtension(from name: String) -> String {
        guard let dotIndex = name.lastIndex(of: ".") else { return "" }
        let afterDot = name.index(after: dotIndex)
        guard afterDot < name.endIndex else { return "" }
        return String(name[afterDot...])
    }

    /// Returns the parent path by trimming the last path component.
    private static func parentPath(of path: String) -> String {
        guard let lastSlash = path.lastIndex(of: "/") else { return "/" }
        if lastSlash == path.startIndex {
            return "/"
        }
        return String(path[path.startIndex..<lastSlash])
    }

    /// Returns the last path component (basename) of a path.
    private static func basename(of path: String) -> String {
        guard let lastSlash = path.lastIndex(of: "/") else { return path }
        let afterSlash = path.index(after: lastSlash)
        guard afterSlash < path.endIndex else {
            // Path ends with "/" — trim and retry
            let trimmed = String(path[path.startIndex..<lastSlash])
            return basename(of: trimmed)
        }
        return String(path[afterSlash...])
    }

    // MARK: - Package Detection

    /// Determines whether a name represents a macOS package directory.
    ///
    /// Package directories (`.app`, `.framework`, etc.) are treated as opaque
    /// bundles in the visualization rather than drillable directories.
    private static func isPackageExtension(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasSuffix(".app")
            || lowered.hasSuffix(".framework")
            || lowered.hasSuffix(".bundle")
            || lowered.hasSuffix(".plugin")
            || lowered.hasSuffix(".kext")
            || lowered.hasSuffix(".prefpane")
            || lowered.hasSuffix(".xpc")
            || lowered.hasSuffix(".qlgenerator")
            || lowered.hasSuffix(".mdimporter")
            || lowered.hasSuffix(".appex")
            || lowered.hasSuffix(".saver")
    }
}

// MARK: - Fallback Stats Box

/// Sendable container for collecting fallback DiskScanner stats
/// across the async/sync boundary.
private final class FallbackStatsBox: @unchecked Sendable {
    var stats: ScanStats?
}
