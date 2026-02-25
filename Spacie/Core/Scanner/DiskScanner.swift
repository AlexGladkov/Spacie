import Foundation
import Darwin

// MARK: - DiskScanner

/// High-performance POSIX-based file system scanner using `fts_open` / `fts_read`.
///
/// Emits ``ScanEvent`` through an `AsyncStream` as it traverses the file tree.
/// Uses direct C interop instead of Foundation's file enumeration APIs for
/// maximum throughput when scanning millions of files.
///
/// ## Performance Targets
/// - 1M files in < 10 seconds on SSD
/// - 5M files in < 60 seconds on SSD
///
/// ## Usage
/// ```swift
/// let scanner = DiskScanner()
/// let stream = scanner.scan(configuration: config)
/// for await event in stream {
///     switch event { ... }
/// }
/// ```
final class DiskScanner: Sendable {

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

    // MARK: - Core Scan Implementation

    /// Performs the actual POSIX file tree scan synchronously on the calling thread.
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
        // Only files with nlink > 1 are checked, keeping this set small.
        var seenInodes = Set<UInt64>()

        // Batch accumulation for throttled progress reporting
        var batchCount = 0
        let batchSize = configuration.batchSize

        // Timing
        let startTime = ContinuousClock.now
        var lastProgressTime = startTime

        // --- Open FTS ---
        // fts_open expects a NULL-terminated array of mutable C string pointers.
        // Returns UnsafeMutablePointer<FTS>? in Swift's Darwin overlay.
        let ftsp: UnsafeMutablePointer<FTS>? = rootPath.withCString { cPath in
            let mutablePath = UnsafeMutablePointer<Int8>(mutating: cPath)
            var pathArray: [UnsafeMutablePointer<Int8>?] = [mutablePath, nil]
            return pathArray.withUnsafeMutableBufferPointer { buffer in
                var options: Int32 = Int32(FTS_PHYSICAL | FTS_NOCHDIR)
                if !configuration.crossMountPoints {
                    options |= Int32(FTS_XDEV)
                }
                return fts_open(buffer.baseAddress!, options, nil)
            }
        }

        guard let fts = ftsp else {
            let code = errno
            continuation.yield(.error(
                path: rootPath,
                code: code,
                message: String(cString: strerror(code))
            ))
            return
        }

        defer { fts_close(fts) }

        // --- Walk the file tree ---
        while let entry = fts_read(fts) {
            // Cooperative cancellation check
            if Task.isCancelled { break }

            let ftsInfo = Int32(entry.pointee.fts_info)
            let depth = Int(entry.pointee.fts_level)
            let currentPath = String(cString: entry.pointee.fts_path!)

            switch ftsInfo {

            // ---- Pre-order directory visit ----
            case FTS_D:
                // Exclusion check — never skip the root directory (depth 0)
                if depth > 0 {
                    let nameForCheck = extractEntryName(entry)
                    if configuration.exclusionRules.shouldExclude(name: nameForCheck, path: currentPath) {
                        fts_set(fts, entry, FTS_SKIP) // skip entire subtree
                        skippedDirectories &+= 1
                        #if DEBUG
                        print("[ScanExclusion] SKIP: \(currentPath)")
                        #endif

                        // Emit a placeholder node so the tree still shows this directory
                        let st = entry.pointee.fts_statp!.pointee
                        var skipFlags: FileNodeFlags = [.isDirectory, .isExcluded]
                        if nameForCheck.hasPrefix(".") { skipFlags.insert(.isHidden) }

                        let rawNode = RawFileNode(
                            name: nameForCheck,
                            path: currentPath,
                            logicalSize: 0,
                            physicalSize: 0,
                            flags: skipFlags,
                            fileType: .other,
                            modTime: UInt32(truncatingIfNeeded: st.st_mtimespec.tv_sec),
                            inode: st.st_ino,
                            depth: depth,
                            parentPath: parentPath(of: currentPath),
                            dirMtime: UInt64(st.st_mtimespec.tv_sec)
                        )
                        continuation.yield(.fileFound(node: rawNode))
                        continuation.yield(.directorySkipped(path: currentPath, depth: depth))
                        continue // next fts_read iteration
                    }
                }

                directoriesScanned &+= 1
                continuation.yield(.directoryEntered(path: currentPath, depth: depth))

            // ---- Post-order directory visit ----
            case FTS_DP:
                let st = entry.pointee.fts_statp!.pointee
                continuation.yield(.directoryCompleted(
                    path: currentPath,
                    totalSize: UInt64(st.st_size)
                ))

                // Emit the directory as a RawFileNode so FileTree can insert it
                let name = extractEntryName(entry)
                var flags: FileNodeFlags = [.isDirectory]
                if name.hasPrefix(".") { flags.insert(.isHidden) }
                if isPackageExtension(name) { flags.insert(.isPackage) }

                let rawNode = RawFileNode(
                    name: name,
                    path: currentPath,
                    logicalSize: 0, // Aggregated later by FileTree
                    physicalSize: 0,
                    flags: flags,
                    fileType: isPackageExtension(name) ? .application : .other,
                    modTime: UInt32(truncatingIfNeeded: st.st_mtimespec.tv_sec),
                    inode: st.st_ino,
                    depth: depth,
                    parentPath: parentPath(of: currentPath),
                    dirMtime: UInt64(st.st_mtimespec.tv_sec)
                )
                continuation.yield(.fileFound(node: rawNode))

            // ---- Regular file ----
            case FTS_F:
                let st = entry.pointee.fts_statp!.pointee
                let inode = st.st_ino
                let nlink = st.st_nlink
                let logicalSize = UInt64(st.st_size)
                let physicalSize = UInt64(st.st_blocks) &* 512

                let name = extractEntryName(entry)
                var flags: FileNodeFlags = buildFileFlags(name: name, stat: st)
                var effectiveLogical = logicalSize
                var effectivePhysical = physicalSize

                // Hard link deduplication: count size only for the first encounter
                if nlink > 1 {
                    flags.insert(.isHardLink)
                    if !seenInodes.insert(inode).inserted {
                        effectiveLogical = 0
                        effectivePhysical = 0
                    }
                }

                // Detect APFS transparent compression via UF_COMPRESSED flag in st_flags.
                // Files compressed with decmpfs carry this flag; st_size reports
                // uncompressed size while st_blocks reflects compressed on-disk size.
                if (st.st_flags & UInt32(UF_COMPRESSED)) != 0 {
                    flags.insert(.isCompressed)
                }

                totalLogicalSize &+= effectiveLogical
                totalPhysicalSize &+= effectivePhysical
                filesScanned &+= 1
                batchCount &+= 1

                let ext = fileExtension(from: name)
                var fileType = FileType.from(extension: ext)
                if fileType == .other {
                    fileType = FileType.fromContext(path: currentPath)
                }

                let rawNode = RawFileNode(
                    name: name,
                    path: currentPath,
                    logicalSize: effectiveLogical,
                    physicalSize: effectivePhysical,
                    flags: flags,
                    fileType: fileType,
                    modTime: UInt32(truncatingIfNeeded: st.st_mtimespec.tv_sec),
                    inode: inode,
                    depth: depth,
                    parentPath: parentPath(of: currentPath)
                )
                continuation.yield(.fileFound(node: rawNode))

            // ---- Symbolic link ----
            case FTS_SL, FTS_SLNONE:
                let st = entry.pointee.fts_statp!.pointee
                let name = extractEntryName(entry)
                filesScanned &+= 1

                var flags: FileNodeFlags = [.isSymlink]
                if name.hasPrefix(".") { flags.insert(.isHidden) }

                let rawNode = RawFileNode(
                    name: name,
                    path: currentPath,
                    logicalSize: 0,
                    physicalSize: 0,
                    flags: flags,
                    fileType: .other,
                    modTime: UInt32(truncatingIfNeeded: st.st_mtimespec.tv_sec),
                    inode: st.st_ino,
                    depth: depth,
                    parentPath: parentPath(of: currentPath)
                )
                continuation.yield(.fileFound(node: rawNode))

            // ---- Directory not readable (EACCES or similar) ----
            case FTS_DNR:
                restrictedDirectories &+= 1
                directoriesScanned &+= 1
                continuation.yield(.restricted(path: currentPath))

                // Still emit a node so the tree reflects the restricted directory
                let st = entry.pointee.fts_statp!.pointee
                let name = extractEntryName(entry)

                let rawNode = RawFileNode(
                    name: name,
                    path: currentPath,
                    logicalSize: 0,
                    physicalSize: 0,
                    flags: [.isDirectory, .isRestricted],
                    fileType: .system,
                    modTime: UInt32(truncatingIfNeeded: st.st_mtimespec.tv_sec),
                    inode: st.st_ino,
                    depth: depth,
                    parentPath: parentPath(of: currentPath),
                    dirMtime: UInt64(st.st_mtimespec.tv_sec)
                )
                continuation.yield(.fileFound(node: rawNode))

            // ---- Errors ----
            case FTS_ERR, FTS_NS:
                let code = entry.pointee.fts_errno
                continuation.yield(.error(
                    path: currentPath,
                    code: code,
                    message: String(cString: strerror(code))
                ))

            default:
                break
            }

            // --- Throttled progress emission ---
            if batchCount >= batchSize {
                batchCount = 0
                let now = ContinuousClock.now
                let sinceLastProgress = now - lastProgressTime
                let throttleNanos = Int(configuration.throttleInterval * 1_000_000_000)
                if sinceLastProgress >= .nanoseconds(throttleNanos) {
                    lastProgressTime = now
                    let totalElapsed = now - startTime
                    let elapsedSeconds = Double(totalElapsed.components.seconds)
                        + Double(totalElapsed.components.attoseconds) / 1e18

                    continuation.yield(.progress(ScanProgress(
                        filesScanned: filesScanned,
                        directoriesScanned: directoriesScanned,
                        skippedDirectories: skippedDirectories,
                        totalLogicalSizeScanned: totalLogicalSize,
                        totalPhysicalSizeScanned: totalPhysicalSize,
                        currentPath: currentPath,
                        elapsedTime: elapsedSeconds,
                        estimatedTotalFiles: nil
                    )))
                }
            }
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

    // MARK: - Name Extraction

    /// Extracts the file/directory name from an FTSENT entry.
    ///
    /// `fts_name` is a C flexible array member (`char[1]`) that extends beyond the
    /// struct boundary. We obtain a pointer to it and read `fts_namelen` bytes.
    private static func extractEntryName(_ entry: UnsafeMutablePointer<FTSENT>) -> String {
        let nameLen = Int(entry.pointee.fts_namelen)
        guard nameLen > 0 else { return "" }
        return withUnsafePointer(to: &entry.pointee.fts_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: nameLen + 1) { cstr in
                String(cString: cstr)
            }
        }
    }

    // MARK: - Flag Construction

    /// Builds ``FileNodeFlags`` for a regular file from its name and stat info.
    private static func buildFileFlags(name: String, stat st: Darwin.stat) -> FileNodeFlags {
        var flags: FileNodeFlags = []
        if name.hasPrefix(".") {
            flags.insert(.isHidden)
        }
        return flags
    }

    // MARK: - Path Utilities

    /// Extracts the file extension from a filename.
    ///
    /// Uses manual scanning from the end for performance in the hot loop,
    /// avoiding `NSString.pathExtension` overhead.
    private static func fileExtension(from name: String) -> String {
        guard let dotIndex = name.lastIndex(of: ".") else { return "" }
        let afterDot = name.index(after: dotIndex)
        guard afterDot < name.endIndex else { return "" }
        return String(name[afterDot...])
    }

    /// Returns the parent path by trimming the last path component.
    private static func parentPath(of path: String) -> String {
        guard let lastSlash = path.lastIndex(of: "/") else { return "" }
        if lastSlash == path.startIndex {
            // Path is "/" or "/something"
            let afterSlash = path.index(after: lastSlash)
            if afterSlash >= path.endIndex {
                // Path is exactly "/" — root has no parent
                return ""
            }
            // Path is "/something" — parent is "/"
            return "/"
        }
        return String(path[path.startIndex..<lastSlash])
    }

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
