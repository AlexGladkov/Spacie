import Foundation
import SpacieKit

// MARK: - TrashError

/// Errors specific to trash operations in Spacie.
enum TrashError: LocalizedError, Sendable {
    case blocked(path: String, reason: String)
    case requiresConfirmation(path: String, reason: String)
    case fileNotFound(path: String)
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
    let url: URL
    let success: Bool
    let error: TrashError?
    let trashURL: URL?
}

// MARK: - TrashManager

/// Manages safe deletion of files by moving them to the macOS Trash.
///
/// Blocklist checks remain in Swift. Actual trash operations delegate to KMP.
/// `@MainActor` isolated because the embedded KMP `SpaTrashService` is an
/// ObjC class without Sendable conformance — main-actor isolation lets us
/// drop the `@unchecked Sendable` hack and keeps callers safe.
@MainActor
struct TrashManager {

    private let kmpTrash = SpaTrashService()

    // MARK: - Single Item

    /// Moves a single file or directory to the macOS Trash.
    func moveToTrash(url: URL) async throws -> URL {
        let path = url.path

        // Pre-check blocklist (Swift-only)
        let permission = BlocklistManager.checkPermission(for: path)
        switch permission {
        case .blocked(let reason):
            throw TrashError.blocked(path: path, reason: reason)
        case .warning(let reason):
            throw TrashError.requiresConfirmation(path: path, reason: reason)
        case .allowed:
            break
        }

        guard FileManager.default.fileExists(atPath: path) else {
            throw TrashError.fileNotFound(path: path)
        }

        do {
            let trashPath = try await kmpTrash.moveToTrash(path: path)
            return URL(fileURLWithPath: trashPath)
        } catch {
            throw TrashError.fileSystemError(path: path, underlying: error.localizedDescription)
        }
    }

    // MARK: - Batch

    /// Moves multiple files or directories to the macOS Trash.
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
    func trashSize() async -> UInt64 {
        do {
            // KMP Long → KotlinLong (NSNumber subclass) in Swift
            let result = try await kmpTrash.trashSize()
            let size = (result as NSNumber).int64Value
            return size >= 0 ? UInt64(size) : 0
        } catch {
            return 0
        }
    }
}
