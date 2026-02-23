import Foundation

// MARK: - TrashError

/// Errors specific to trash operations in Spacie.
enum TrashError: LocalizedError, Sendable {
    /// The file at the given path is protected by the blocklist and cannot be deleted.
    case blocked(path: String, reason: String)
    /// The file requires user confirmation before deletion.
    case requiresConfirmation(path: String, reason: String)
    /// The file was not found at the expected path.
    case fileNotFound(path: String)
    /// An underlying file system error occurred.
    case fileSystemError(path: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .blocked(let path, let reason):
            "Cannot delete \(path): \(reason)"
        case .requiresConfirmation(let path, let reason):
            "Confirmation required for \(path): \(reason)"
        case .fileNotFound(let path):
            "File not found: \(path)"
        case .fileSystemError(let path, let underlying):
            "Error deleting \(path): \(underlying)"
        }
    }
}

// MARK: - TrashResult

/// The outcome of attempting to move a single file or directory to Trash.
struct TrashResult: Sendable {
    /// The original URL of the item.
    let url: URL
    /// Whether the move to Trash succeeded.
    let success: Bool
    /// The error that occurred, if any.
    let error: TrashError?
    /// The URL in the Trash where the item was moved, if successful.
    let trashURL: URL?
}

// MARK: - TrashManager

/// Manages safe deletion of files by moving them to the macOS Trash.
///
/// Before each deletion, the ``BlocklistManager`` is consulted to ensure
/// the target path is not protected (SIP, critical user paths, user blocklist)
/// or flagged for warning. Files that are blocked will not be moved.
///
/// ## Safety
/// - Uses `FileManager.trashItem(at:resultingItemURL:)` exclusively.
/// - Never performs permanent deletion.
/// - Never requests elevated privileges.
///
/// ## Usage
/// ```swift
/// let manager = TrashManager()
/// let trashURL = try await manager.moveToTrash(url: fileURL)
/// ```
struct TrashManager: Sendable {

    // MARK: - Single Item

    /// Moves a single file or directory to the macOS Trash.
    ///
    /// Checks the ``BlocklistManager`` before proceeding. If the path is
    /// blocked, throws ``TrashError/blocked``. If it requires a warning,
    /// throws ``TrashError/requiresConfirmation`` so the UI layer can
    /// present a confirmation dialog before retrying.
    ///
    /// - Parameter url: The file URL to move to Trash.
    /// - Returns: The URL of the item in the Trash after the move.
    /// - Throws: ``TrashError`` if the operation is not permitted or fails.
    func moveToTrash(url: URL) async throws -> URL {
        let path = url.path

        // Pre-check blocklist
        let permission = BlocklistManager.checkPermission(for: path)
        switch permission {
        case .blocked(let reason):
            throw TrashError.blocked(path: path, reason: reason)
        case .warning(let reason):
            throw TrashError.requiresConfirmation(path: path, reason: reason)
        case .allowed:
            break
        }

        // Verify file exists
        guard FileManager.default.fileExists(atPath: path) else {
            throw TrashError.fileNotFound(path: path)
        }

        // Perform the move on a background thread to avoid blocking the caller.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var resultURL: NSURL?
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: &resultURL)
                    if let trashURL = resultURL as URL? {
                        continuation.resume(returning: trashURL)
                    } else {
                        continuation.resume(returning: url)
                    }
                } catch {
                    continuation.resume(throwing: TrashError.fileSystemError(
                        path: path,
                        underlying: error.localizedDescription
                    ))
                }
            }
        }
    }

    // MARK: - Batch

    /// Moves multiple files or directories to the macOS Trash.
    ///
    /// Each item is processed independently. Items that are blocked or
    /// fail will have their error recorded in the corresponding
    /// ``TrashResult`` without preventing other items from being processed.
    ///
    /// - Parameter urls: The file URLs to move to Trash.
    /// - Returns: An array of ``TrashResult`` in the same order as the input.
    func moveToTrash(urls: [URL]) async throws -> [TrashResult] {
        var results: [TrashResult] = []
        results.reserveCapacity(urls.count)

        for url in urls {
            do {
                let trashURL = try await moveToTrash(url: url)
                results.append(TrashResult(
                    url: url,
                    success: true,
                    error: nil,
                    trashURL: trashURL
                ))
            } catch let trashError as TrashError {
                results.append(TrashResult(
                    url: url,
                    success: false,
                    error: trashError,
                    trashURL: nil
                ))
            } catch {
                results.append(TrashResult(
                    url: url,
                    success: false,
                    error: .fileSystemError(path: url.path, underlying: error.localizedDescription),
                    trashURL: nil
                ))
            }
        }

        return results
    }

    // MARK: - Trash Size

    /// Calculates the total size of the current user's Trash directory.
    ///
    /// Enumerates `~/.Trash/` recursively and sums allocated file sizes.
    /// Returns 0 if the Trash directory does not exist or cannot be read.
    ///
    /// - Returns: The total size in bytes of all items in Trash.
    func trashSize() async -> UInt64 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let trashURL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".Trash")

                guard FileManager.default.fileExists(atPath: trashURL.path) else {
                    continuation.resume(returning: 0)
                    return
                }

                do {
                    let size = try FileManager.default.allocatedSizeOfDirectory(at: trashURL)
                    continuation.resume(returning: size)
                } catch {
                    continuation.resume(returning: 0)
                }
            }
        }
    }
}
