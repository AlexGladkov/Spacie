import Foundation
import CryptoKit
import Darwin

// MARK: - DuplicateEngineError

enum DuplicateEngineError: Error {
    case readFailed(String)
    case cancelled
}

// MARK: - DuplicateEngineEvent

enum DuplicateEngineEvent: Sendable {
    case sizeGroupingStarted
    case sizeGroupingCompleted(groupCount: Int)
    case hashingProgress(DuplicateScanProgress)
    case hashingCompleted(groups: [DuplicateGroup])
    case error(String)
    case completed(stats: DuplicateStats)
}

// MARK: - DuplicateEngine

/// Actor responsible for progressive duplicate file detection.
///
/// Algorithm:
/// 1. Group files by size (instant, from tree data via `buildSizeBuckets`)
/// 2. For each size group with count > 1: compute partial SHA-256 (first 16KB + last 16KB)
/// 3. Full hash: on-demand when user requests confirmation for a group
actor DuplicateEngine {

    // MARK: Constants

    private let partialHashHeadSize: Int = 16_384   // 16KB
    private let partialHashTailSize: Int = 16_384   // 16KB
    private let fullHashChunkSize: Int = 131_072     // 128KB
    private let maxConcurrentPartialIO: Int = 8
    private let maxConcurrentFullIO: Int = 4

    // MARK: Progressive Duplicate Finding

    /// Scans the file tree for duplicates using progressive hashing.
    /// Emits events through an AsyncStream for UI updates.
    func findDuplicates(
        in tree: FileTree,
        filterOptions: DuplicateFilterOptions
    ) -> AsyncStream<DuplicateEngineEvent> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                let startTime = CFAbsoluteTimeGetCurrent()

                // Step 1: Group by size
                continuation.yield(.sizeGroupingStarted)

                let sizeBuckets = tree.buildSizeBuckets(
                    minSize: filterOptions.minFileSize,
                    excludeHardLinks: filterOptions.excludeHardLinks
                )
                let candidateGroupCount = sizeBuckets.count
                continuation.yield(.sizeGroupingCompleted(groupCount: candidateGroupCount))

                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }

                // Step 2: Partial hash for each size group
                let totalFilesForHashing = sizeBuckets.values.reduce(0) { $0 + $1.count }
                var allGroups: [DuplicateGroup] = []
                var completedFiles = 0
                var totalBytesHashed: UInt64 = 0

                for (_, entries) in sizeBuckets {
                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
                    }

                    let partialGroups = await self.computePartialHashGroups(
                        entries: entries,
                        tree: tree
                    )
                    allGroups.append(contentsOf: partialGroups)

                    completedFiles += entries.count
                    for entry in entries {
                        let info = tree.nodeInfo(at: entry.index)
                        totalBytesHashed += info.logicalSize
                    }

                    let currentFile = entries.last.flatMap { tree.nodeInfo(at: $0.index).name } ?? ""
                    continuation.yield(.hashingProgress(DuplicateScanProgress(
                        filesHashed: completedFiles,
                        totalFiles: totalFilesForHashing,
                        bytesHashed: totalBytesHashed,
                        currentFile: currentFile
                    )))
                }

                // Sort by wasted space descending
                allGroups.sort { $0.wastedSpace > $1.wastedSpace }

                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                let stats = DuplicateStats(
                    groupCount: allGroups.count,
                    totalDuplicateFiles: allGroups.reduce(0) { $0 + $1.fileCount },
                    totalWastedSpace: allGroups.reduce(0) { $0 + $1.wastedSpace },
                    scanDuration: elapsed
                )

                continuation.yield(.hashingCompleted(groups: allGroups))
                continuation.yield(.completed(stats: stats))
                continuation.finish()
            }
        }
    }

    /// Computes full SHA-256 hash for a group of files to confirm duplicates.
    /// Returns refined duplicate groups with full hash confirmation.
    func computeFullHash(for group: DuplicateGroup) async throws -> [DuplicateGroup] {
        var hashMap: [Data: [DuplicateFile]] = [:]

        try await withThrowingTaskGroup(of: (DuplicateFile, Data)?.self) { taskGroup in
            var pending = 0
            var fileIterator = group.files.makeIterator()

            func addNextTask() -> Bool {
                guard let file = fileIterator.next() else { return false }
                taskGroup.addTask { [weak self] in
                    guard let self else { return nil }
                    guard !Task.isCancelled else { throw DuplicateEngineError.cancelled }
                    let hash = try await self.fullHash(path: file.path, fileSize: file.size)
                    return (file, hash)
                }
                return true
            }

            // Start initial batch
            for _ in 0..<min(maxConcurrentFullIO, group.files.count) {
                if addNextTask() {
                    pending += 1
                }
            }

            for try await result in taskGroup {
                pending -= 1
                if let (file, hash) = result {
                    hashMap[hash, default: []].append(file)
                }
                if addNextTask() {
                    pending += 1
                }
            }
        }

        // Convert to DuplicateGroups, only groups with > 1 file
        return hashMap.compactMap { (hash, files) -> DuplicateGroup? in
            guard files.count > 1 else { return nil }
            let hashHex = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
            return DuplicateGroup(
                id: "full-\(hashHex)",
                fileSize: files[0].size,
                files: files,
                hashLevel: .fullHash
            )
        }
    }

    // MARK: - Private: Partial Hash Groups

    private func computePartialHashGroups(
        entries: [(index: UInt32, inode: UInt64)],
        tree: FileTree
    ) async -> [DuplicateGroup] {
        var hashMap: [Data: [DuplicateFile]] = [:]

        await withTaskGroup(of: (Data, DuplicateFile)?.self) { group in
            var pending = 0
            var entryIterator = entries.makeIterator()

            func addNext() -> Bool {
                guard let entry = entryIterator.next() else { return false }
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    guard !Task.isCancelled else { return nil }
                    let info = tree.nodeInfo(at: entry.index)
                    guard let hash = try? await self.partialHash(
                        path: info.fullPath,
                        fileSize: info.logicalSize
                    ) else { return nil }
                    let dupFile = DuplicateFile(
                        id: info.fullPath,
                        url: URL(fileURLWithPath: info.fullPath),
                        name: info.name,
                        path: info.fullPath,
                        size: info.logicalSize,
                        modificationDate: info.modificationDate,
                        treeIndex: entry.index
                    )
                    return (hash, dupFile)
                }
                return true
            }

            for _ in 0..<min(maxConcurrentPartialIO, entries.count) {
                if addNext() { pending += 1 }
            }

            for await result in group {
                pending -= 1
                if let (hash, dupFile) = result {
                    hashMap[hash, default: []].append(dupFile)
                }
                if addNext() { pending += 1 }
            }
        }

        // Convert to DuplicateGroup, only groups with > 1 file
        return hashMap.compactMap { (hash, files) -> DuplicateGroup? in
            guard files.count > 1 else { return nil }
            let hashHex = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
            return DuplicateGroup(
                id: "partial-\(hashHex)",
                fileSize: files[0].size,
                files: files,
                hashLevel: .partialHash
            )
        }
    }

    // MARK: - Private: Hashing via pread(2)

    /// Computes partial SHA-256: first 16KB head + last 16KB tail + file size.
    /// Uses pread(2) with O_NOFOLLOW and F_NOCACHE for safe, efficient I/O.
    private func partialHash(path: String, fileSize: UInt64) throws -> Data {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw DuplicateEngineError.readFailed(path) }
        defer { Darwin.close(fd) }
        _ = Darwin.fcntl(fd, F_NOCACHE, 1)

        var hasher = SHA256()

        let headSize = Int(min(fileSize, UInt64(partialHashHeadSize)))
        var headBuf = [UInt8](repeating: 0, count: headSize)
        let headRead = pread(fd, &headBuf, headSize, 0)
        guard headRead > 0 else { throw DuplicateEngineError.readFailed(path) }
        hasher.update(data: headBuf[..<headRead])

        if fileSize > UInt64(partialHashHeadSize) {
            let tailSize = Int(min(fileSize, UInt64(partialHashTailSize)))
            var tailBuf = [UInt8](repeating: 0, count: tailSize)
            let tailOffset = off_t(fileSize) - off_t(tailSize)
            let tailRead = pread(fd, &tailBuf, tailSize, max(tailOffset, 0))
            if tailRead > 0 { hasher.update(data: tailBuf[..<tailRead]) }
        }

        var sizeBytes = fileSize
        withUnsafeBytes(of: &sizeBytes) { hasher.update(bufferPointer: $0) }
        return Data(hasher.finalize())
    }

    /// Computes full SHA-256 by reading the file in 128KB chunks via pread(2).
    /// Checks Task.isCancelled after each chunk for cooperative cancellation.
    private func fullHash(path: String, fileSize: UInt64) async throws -> Data {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw DuplicateEngineError.readFailed(path) }
        defer { Darwin.close(fd) }
        _ = Darwin.fcntl(fd, F_NOCACHE, 1)

        var hasher = SHA256()
        var offset: off_t = 0
        var buf = [UInt8](repeating: 0, count: fullHashChunkSize)

        while UInt64(offset) < fileSize {
            guard !Task.isCancelled else { throw DuplicateEngineError.cancelled }

            let toRead = min(fullHashChunkSize, Int(fileSize - UInt64(offset)))
            let bytesRead = pread(fd, &buf, toRead, offset)
            guard bytesRead > 0 else { break }
            hasher.update(data: buf[..<bytesRead])
            offset += off_t(bytesRead)
        }

        return Data(hasher.finalize())
    }
}
