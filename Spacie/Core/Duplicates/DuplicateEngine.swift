import Foundation
import CryptoKit

// MARK: - DuplicateEngineEvent

enum DuplicateEngineEvent: Sendable {
    case sizeGroupingStarted
    case sizeGroupingCompleted(groupCount: Int)
    case partialHashStarted(totalFiles: Int)
    case partialHashProgress(completed: Int, total: Int)
    case partialHashCompleted(groups: [DuplicateGroup])
    case fullHashStarted(groupId: String, fileCount: Int)
    case fullHashProgress(groupId: String, completed: Int, total: Int)
    case fullHashCompleted(groupId: String, groups: [DuplicateGroup])
    case error(String)
    case completed(stats: DuplicateStats)
}

// MARK: - DuplicateEngine

/// Actor responsible for progressive duplicate file detection.
///
/// Algorithm:
/// 1. Group files by size (instant, from tree data)
/// 2. For each size group with count > 1: compute partial SHA-256 (first 4KB + last 4KB)
/// 3. Full hash: on-demand when user opens a group detail
actor DuplicateEngine {

    // MARK: Constants

    private let partialHashSize: Int = 4096
    private let readChunkSize: Int = 65_536 // 64KB chunks for full hashing
    private let maxConcurrentIO: Int = 4

    // MARK: State

    private var isCancelled = false

    // MARK: Cancel

    func cancel() {
        isCancelled = true
    }

    func reset() {
        isCancelled = false
    }

    // MARK: Progressive Duplicate Finding

    /// Scans the file tree for duplicates using progressive hashing.
    /// Emits events through an AsyncStream for UI updates.
    func findDuplicates(in tree: FileTree) -> AsyncStream<DuplicateEngineEvent> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.reset()
                let startTime = CFAbsoluteTimeGetCurrent()

                // Step 1: Group by size
                continuation.yield(.sizeGroupingStarted)

                let sizeGroups = await self.groupBySize(tree: tree)
                let candidateGroupCount = sizeGroups.count
                continuation.yield(.sizeGroupingCompleted(groupCount: candidateGroupCount))

                guard await self.checkCancelled() == false else {
                    continuation.finish()
                    return
                }

                // Step 2: Partial hash for each size group
                let totalFilesForPartialHash = sizeGroups.values.reduce(0) { $0 + $1.count }
                continuation.yield(.partialHashStarted(totalFiles: totalFilesForPartialHash))

                var allGroups: [DuplicateGroup] = []
                var completedFiles = 0

                for (_, fileInfos) in sizeGroups {
                    guard await self.checkCancelled() == false else {
                        continuation.finish()
                        return
                    }

                    let partialGroups = await self.computePartialHashGroups(
                        files: fileInfos,
                        tree: tree
                    )
                    allGroups.append(contentsOf: partialGroups)

                    completedFiles += fileInfos.count
                    continuation.yield(.partialHashProgress(
                        completed: completedFiles,
                        total: totalFilesForPartialHash
                    ))
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

                continuation.yield(.partialHashCompleted(groups: allGroups))
                continuation.yield(.completed(stats: stats))
                continuation.finish()
            }
        }
    }

    /// Computes full SHA-256 hash for a set of file URLs.
    /// Returns a dictionary mapping hash string to file URLs.
    func computeFullHash(for files: [URL]) async throws -> [String: [URL]] {
        var hashMap: [String: [URL]] = [:]

        try await withThrowingTaskGroup(of: (URL, String)?.self) { group in
            // Use semaphore-like pattern to limit concurrency
            var pending = 0
            var fileIterator = files.makeIterator()

            func addNextTask() -> Bool {
                guard let url = fileIterator.next() else { return false }
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    let hash = try await self.fullSHA256(of: url)
                    return (url, hash)
                }
                return true
            }

            // Start initial batch
            for _ in 0..<min(maxConcurrentIO, files.count) {
                if addNextTask() {
                    pending += 1
                }
            }

            for try await result in group {
                pending -= 1
                if let (url, hash) = result {
                    hashMap[hash, default: []].append(url)
                }
                // Add next task to keep concurrency at max
                if addNextTask() {
                    pending += 1
                }
            }
        }

        // Only keep groups with duplicates
        return hashMap.filter { $0.value.count > 1 }
    }

    // MARK: - Private: Grouping

    private func groupBySize(tree: FileTree) -> [UInt64: [(index: UInt32, info: FileNodeInfo)]] {
        var sizeMap: [UInt64: [(index: UInt32, info: FileNodeInfo)]] = [:]

        for i in 0..<UInt32(tree.nodeCount) {
            let node = tree[i]
            // Skip directories, symlinks, and zero-size files
            guard !node.isDirectory, !node.isSymlink, node.logicalSize > 0 else { continue }

            let info = tree.nodeInfo(at: i)
            sizeMap[node.logicalSize, default: []].append((index: i, info: info))
        }

        // Only keep groups with potential duplicates (count > 1)
        return sizeMap.filter { $0.value.count > 1 }
    }

    private func computePartialHashGroups(
        files: [(index: UInt32, info: FileNodeInfo)],
        tree: FileTree
    ) async -> [DuplicateGroup] {
        var hashMap: [String: [DuplicateFile]] = [:]

        await withTaskGroup(of: (String, DuplicateFile)?.self) { group in
            var pending = 0
            var fileIterator = files.makeIterator()

            func addNext() -> Bool {
                guard let entry = fileIterator.next() else { return false }
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    let url = URL(fileURLWithPath: entry.info.fullPath)
                    guard let hash = try? await self.partialSHA256(of: url) else { return nil }
                    let dupFile = DuplicateFile(
                        id: entry.info.fullPath,
                        url: url,
                        name: entry.info.name,
                        path: entry.info.fullPath,
                        size: entry.info.logicalSize,
                        modificationDate: entry.info.modificationDate,
                        isSelected: false
                    )
                    return (hash, dupFile)
                }
                return true
            }

            for _ in 0..<min(maxConcurrentIO, files.count) {
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
            return DuplicateGroup(
                id: hash,
                fileSize: files[0].size,
                files: files,
                hashLevel: .partialHash
            )
        }
    }

    // MARK: - Private: Hashing

    /// Computes SHA-256 of first 4096 bytes + last 4096 bytes.
    private func partialSHA256(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()

        // Read first 4096 bytes
        let headData = handle.readData(ofLength: partialHashSize)
        hasher.update(data: headData)

        // Seek to last 4096 bytes
        let fileSize = handle.seekToEndOfFile()
        if fileSize > UInt64(partialHashSize) {
            let tailOffset = fileSize - UInt64(partialHashSize)
            handle.seek(toFileOffset: tailOffset)
            let tailData = handle.readData(ofLength: partialHashSize)
            hasher.update(data: tailData)
        }

        // Include file size in hash to reduce collisions
        var sizeBytes = fileSize
        withUnsafeBytes(of: &sizeBytes) { hasher.update(bufferPointer: $0) }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Computes full SHA-256 by reading the file in 64KB chunks.
    private func fullSHA256(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()

        while true {
            let chunk = handle.readData(ofLength: readChunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Private: Cancellation

    private func checkCancelled() -> Bool {
        isCancelled
    }
}
