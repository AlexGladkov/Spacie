import Foundation
import SwiftUI

// MARK: - 1. Xcode DerivedData

struct XcodeDerivedDataCategory: CleanupCategory {
    let id = "xcode-derived-data"
    let name: LocalizedStringResource = "Xcode DerivedData"
    let description: LocalizedStringResource = "Build artifacts, indexes, and intermediate files"
    let icon = "hammer.fill"

    var searchPaths: [CleanupSearchPath] {
        [CleanupSearchPath(path: "~/Library/Developer/Xcode/DerivedData")]
    }

    func detailedItems(at path: URL) async throws -> [CleanupItem] {
        try await enumerateSubdirectories(at: path)
    }
}

// MARK: - 2. Xcode Archives

struct XcodeArchivesCategory: CleanupCategory {
    let id = "xcode-archives"
    let name: LocalizedStringResource = "Xcode Archives"
    let description: LocalizedStringResource = "Archived builds for distribution"
    let icon = "archivebox.fill"

    var searchPaths: [CleanupSearchPath] {
        [CleanupSearchPath(path: "~/Library/Developer/Xcode/Archives")]
    }

    func detailedItems(at path: URL) async throws -> [CleanupItem] {
        try await enumerateSubdirectories(at: path)
    }
}

// MARK: - 3. Xcode Device Support

struct XcodeDeviceSupportCategory: CleanupCategory {
    let id = "xcode-device-support"
    let name: LocalizedStringResource = "Xcode Device Support"
    let description: LocalizedStringResource = "iOS/watchOS device symbols for debugging"
    let icon = "iphone"

    var searchPaths: [CleanupSearchPath] {
        [CleanupSearchPath(path: "~/Library/Developer/Xcode/iOS DeviceSupport")]
    }

    func detailedItems(at path: URL) async throws -> [CleanupItem] {
        try await enumerateSubdirectories(at: path)
    }
}

// MARK: - 4. Homebrew Cache

struct HomebrewCacheCategory: CleanupCategory {
    let id = "homebrew-cache"
    let name: LocalizedStringResource = "Homebrew Cache"
    let description: LocalizedStringResource = "Downloaded package archives and bottles"
    let icon = "mug.fill"

    var searchPaths: [CleanupSearchPath] {
        [CleanupSearchPath(path: "~/Library/Caches/Homebrew")]
    }
}

// MARK: - 5. npm Cache

struct NpmCacheCategory: CleanupCategory {
    let id = "npm-cache"
    let name: LocalizedStringResource = "npm Cache"
    let description: LocalizedStringResource = "Cached npm package tarballs"
    let icon = "shippingbox.fill"

    var searchPaths: [CleanupSearchPath] {
        [CleanupSearchPath(path: "~/.npm/_cacache")]
    }
}

// MARK: - 6. node_modules

struct NodeModulesCategory: CleanupCategory {
    let id = "node-modules"
    let name: LocalizedStringResource = "node_modules"
    let description: LocalizedStringResource = "Node.js dependency folders across your projects"
    let icon = "folder.fill.badge.gearshape"

    var searchPaths: [CleanupSearchPath] {
        // We scan home directory recursively, but the custom detailedItems handles the logic
        [CleanupSearchPath(path: "~", recursive: true)]
    }

    func canSafelyDelete(item: URL) async -> Bool {
        // Check if parent directory has a package.json (meaning it's a valid node project)
        let parentDir = item.deletingLastPathComponent()
        let packageJson = parentDir.appendingPathComponent("package.json")
        return FileManager.default.fileExists(atPath: packageJson.path)
    }

    func detailedItems(at path: URL) async throws -> [CleanupItem] {
        // Custom: find all node_modules directories under home, top-level only
        // (do not recurse into nested node_modules)
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        return try await findNodeModules(under: homeURL)
    }

    private func findNodeModules(under root: URL) async throws -> [CleanupItem] {
        let fm = FileManager.default
        var results: [CleanupItem] = []

        // Directories to skip entirely
        let skipDirs: Set<String> = [
            ".Trash", "Library", ".cache", ".local",
            "node_modules", // Don't recurse into node_modules themselves
            ".git", ".svn"
        ]

        func scan(directory: URL, depth: Int) {
            guard depth < 8 else { return } // Limit depth to avoid infinite recursion

            guard let contents = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for itemURL in contents {
                let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDir else { continue }

                let name = itemURL.lastPathComponent

                if name == "node_modules" {
                    let size = (try? fm.allocatedSizeOfDirectory(at: itemURL)) ?? 0
                    let parentName = directory.lastPathComponent
                    results.append(CleanupItem(
                        url: itemURL,
                        name: "\(parentName)/node_modules",
                        size: size,
                        modificationDate: (try? itemURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                        isDirectory: true
                    ))
                    // Do NOT recurse into node_modules
                } else if !skipDirs.contains(name) {
                    scan(directory: itemURL, depth: depth + 1)
                }
            }
        }

        scan(directory: root, depth: 0)
        return results.sorted { $0.size > $1.size }
    }
}

// MARK: - 7. Docker

struct DockerCategory: CleanupCategory {
    let id = "docker-data"
    let name: LocalizedStringResource = "Docker Data"
    let description: LocalizedStringResource = "Docker Desktop virtual machine images and data"
    let icon = "shippingbox.fill"

    var searchPaths: [CleanupSearchPath] {
        [CleanupSearchPath(path: "~/Library/Containers/com.docker.docker/Data/vms")]
    }

    func canSafelyDelete(item: URL) async -> Bool {
        // Docker must not be running. Check if the process exists.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "Docker"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus != 0 // Safe only if Docker is NOT running
        } catch {
            return true
        }
    }
}

// MARK: - 8. Gradle Cache

struct GradleCacheCategory: CleanupCategory {
    let id = "gradle-cache"
    let name: LocalizedStringResource = "Gradle Cache"
    let description: LocalizedStringResource = "Gradle build cache, dependency artifacts, and wrapper distributions"
    let icon = "square.stack.3d.up.fill"

    var searchPaths: [CleanupSearchPath] {
        [CleanupSearchPath(path: "~/.gradle/caches")]
    }

    func detailedItems(at path: URL) async throws -> [CleanupItem] {
        try await enumerateSubdirectories(at: path)
    }
}

// MARK: - 9. System Logs

struct SystemLogsCategory: CleanupCategory {
    let id = "system-logs"
    let name: LocalizedStringResource = "System Logs"
    let description: LocalizedStringResource = "System and application log files"
    let icon = "doc.text.fill"

    var searchPaths: [CleanupSearchPath] {
        [
            CleanupSearchPath(path: "/var/log"),
            CleanupSearchPath(path: "~/Library/Logs"),
        ]
    }

    func canSafelyDelete(item: URL) async -> Bool {
        // Allow deletion of log files, but not directories that contain active logs
        let ext = item.pathExtension.lowercased()
        let safeExtensions: Set<String> = ["log", "gz", "bz2", "xz", "old", "1", "2", "3"]
        if safeExtensions.contains(ext) { return true }
        // If it's a file without extension, check age (> 7 days)
        if let values = try? item.resourceValues(forKeys: [.contentModificationDateKey]),
           let date = values.contentModificationDate {
            return date.timeIntervalSinceNow < -7 * 86400
        }
        return false
    }
}

// MARK: - 10. Crash Reports

struct CrashReportsCategory: CleanupCategory {
    let id = "crash-reports"
    let name: LocalizedStringResource = "Crash Reports"
    let description: LocalizedStringResource = "Application crash logs and diagnostic reports"
    let icon = "exclamationmark.triangle.fill"

    var searchPaths: [CleanupSearchPath] {
        [CleanupSearchPath(path: "~/Library/Logs/DiagnosticReports")]
    }
}

// MARK: - 11. iOS Backups

struct IOSBackupsCategory: CleanupCategory {
    let id = "ios-backups"
    let name: LocalizedStringResource = "iOS Backups"
    let description: LocalizedStringResource = "iPhone and iPad local backup files"
    let icon = "iphone.gen3"

    var searchPaths: [CleanupSearchPath] {
        [CleanupSearchPath(path: "~/Library/Application Support/MobileSync/Backup")]
    }

    func canSafelyDelete(item: URL) async -> Bool {
        // Allow deleting individual backup folders (each is a device backup)
        let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        return isDir
    }

    func detailedItems(at path: URL) async throws -> [CleanupItem] {
        // Each subdirectory is a device backup
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: path,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var items: [CleanupItem] = []
        for url in contents {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }

            let size = (try? fm.allocatedSizeOfDirectory(at: url)) ?? 0
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

            // Try to read device name from Info.plist inside the backup
            let displayName = readBackupDeviceName(at: url) ?? url.lastPathComponent

            items.append(CleanupItem(
                url: url,
                name: displayName,
                size: size,
                modificationDate: modDate,
                isDirectory: true
            ))
        }
        return items.sorted { $0.size > $1.size }
    }

    private func readBackupDeviceName(at backupURL: URL) -> String? {
        let infoPlist = backupURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let deviceName = plist["Device Name"] as? String else {
            return nil
        }
        return deviceName
    }
}

// MARK: - 12. Old Downloads

struct DownloadsOldCategory: CleanupCategory {
    let id = "downloads-old"
    let name: LocalizedStringResource = "Old Downloads"
    let description: LocalizedStringResource = "Files in Downloads older than 30 days"
    let icon = "arrow.down.circle.fill"

    var searchPaths: [CleanupSearchPath] {
        [CleanupSearchPath(
            path: "~/Downloads",
            minAge: 30 * 86400 // 30 days in seconds
        )]
    }

    func detailedItems(at path: URL) async throws -> [CleanupItem] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-30 * 86400)

        guard let contents = try? fm.contentsOfDirectory(
            at: path,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey, .totalFileAllocatedSizeKey],
            options: []
        ) else { return [] }

        var items: [CleanupItem] = []
        for url in contents {
            let resources = try? url.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey, .isDirectoryKey, .totalFileAllocatedSizeKey
            ])
            let modDate = resources?.contentModificationDate
            guard let date = modDate, date < cutoff else { continue }

            let isDir = resources?.isDirectory ?? false
            let size: UInt64
            if isDir {
                size = (try? fm.allocatedSizeOfDirectory(at: url)) ?? 0
            } else {
                size = UInt64(resources?.totalFileAllocatedSize ?? resources?.fileSize ?? 0)
            }

            items.append(CleanupItem(
                url: url,
                name: url.lastPathComponent,
                size: size,
                modificationDate: modDate,
                isDirectory: isDir
            ))
        }
        return items.sorted { $0.size > $1.size }
    }
}

// MARK: - 13. Trash

struct TrashCategory: CleanupCategory {
    let id = "trash"
    let name: LocalizedStringResource = "Trash"
    let description: LocalizedStringResource = "Items currently in your Trash"
    let icon = "trash.fill"

    var searchPaths: [CleanupSearchPath] {
        [CleanupSearchPath(path: "~/.Trash")]
    }
}

// MARK: - Shared Helper

/// Enumerates immediate subdirectories at the given path, computing size for each.
private func enumerateSubdirectories(at path: URL) async throws -> [CleanupItem] {
    let fm = FileManager.default
    guard let contents = try? fm.contentsOfDirectory(
        at: path,
        includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    var items: [CleanupItem] = []
    for url in contents {
        let resources = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
        let isDir = resources?.isDirectory ?? false

        let size: UInt64
        if isDir {
            size = (try? fm.allocatedSizeOfDirectory(at: url)) ?? 0
        } else {
            size = UInt64(resources?.fileSize ?? 0)
        }

        items.append(CleanupItem(
            url: url,
            name: url.lastPathComponent,
            size: size,
            modificationDate: resources?.contentModificationDate,
            isDirectory: isDir
        ))
    }
    return items.sorted { $0.size > $1.size }
}
