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

// MARK: - TrashManaging

/// Abstraction over move-to-trash behaviour so views/tests can mock deletion.
///
/// Methods are `@MainActor` individually (not the protocol) to keep
/// `EnvironmentKey.Value` conformance buildable.
protocol TrashManaging: Sendable {
    @MainActor func moveToTrash(url: URL) async throws -> URL
    @MainActor func moveToTrash(urls: [URL]) async throws -> [TrashResult]
    @MainActor func trashSize() async -> UInt64
}

// MARK: - TrashManager

/// Default implementation. Blocklist checks remain in Swift; KMP performs the
/// actual trash operation.
@MainActor
struct TrashManager: TrashManaging {

    private let kmpTrash: SpaTrashService

    init(kmpTrash: SpaTrashService = SpaSpacieFactory.shared.createTrashService()) {
        self.kmpTrash = kmpTrash
    }

    // MARK: - Single Item

    func moveToTrash(url: URL) async throws -> URL {
        let path = url.path

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

    func moveToTrash(urls: [URL]) async throws -> [TrashResult] {
        var results: [TrashResult] = []
        results.reserveCapacity(urls.count)

        for url in urls {
            do {
                let trashURL = try await moveToTrash(url: url)
                results.append(TrashResult(url: url, success: true, error: nil, trashURL: trashURL))
            } catch let trashError as TrashError {
                results.append(TrashResult(url: url, success: false, error: trashError, trashURL: nil))
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

    func trashSize() async -> UInt64 {
        do {
            let result = try await kmpTrash.trashSize()
            let size = (result as NSNumber).int64Value
            return size >= 0 ? UInt64(size) : 0
        } catch {
            return 0
        }
    }
}

// MARK: - MockTrashManager

#if DEBUG
@MainActor
final class MockTrashManager: TrashManaging {

    var trashedURLs: [URL] = []
    var totalSize: UInt64 = 0
    var failureForPath: ((String) -> TrashError?)?

    func moveToTrash(url: URL) async throws -> URL {
        if let error = failureForPath?(url.path) { throw error }
        trashedURLs.append(url)
        return url.appendingPathExtension("trashed")
    }

    func moveToTrash(urls: [URL]) async throws -> [TrashResult] {
        urls.map { url in
            if let error = failureForPath?(url.path) {
                return TrashResult(url: url, success: false, error: error, trashURL: nil)
            }
            trashedURLs.append(url)
            return TrashResult(
                url: url,
                success: true,
                error: nil,
                trashURL: url.appendingPathExtension("trashed")
            )
        }
    }

    func trashSize() async -> UInt64 { totalSize }
}
#endif
