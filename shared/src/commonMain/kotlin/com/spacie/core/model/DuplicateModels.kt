package com.spacie.core.model

import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

// MARK: - HashLevel

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaHashLevel")
enum class HashLevel(val level: Int) : Comparable<HashLevel> {
    SIZE_ONLY(0),
    PARTIAL_HASH(1),
    FULL_HASH(2);

    val displayName: String
        get() = when (this) {
            SIZE_ONLY -> "Size Match"
            PARTIAL_HASH -> "Partial Hash"
            FULL_HASH -> "Full Hash (Confirmed)"
        }
}

// MARK: - DuplicateFile

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaDuplicateFile")
data class DuplicateFile(
    val id: String,
    val path: String,
    val name: String,
    val displayPath: String,
    val size: Long,
    val modificationDate: Long,
    val treeIndex: Int
)

// MARK: - DuplicateGroup

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaDuplicateGroup")
data class DuplicateGroup(
    val id: String,
    val fileSize: Long,
    val files: List<DuplicateFile>,
    val hashLevel: HashLevel
) {
    val wastedSpace: Long
        get() {
            if (files.size <= 1) return 0L
            return fileSize * (files.size - 1).toLong()
        }

    val fileCount: Int get() = files.size
}

// MARK: - DuplicateFilterOptions

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaDuplicateFilterOptions")
data class DuplicateFilterOptions(
    val minFileSize: Long,
    val excludeHardLinks: Boolean,
    val excludePackageContents: Boolean
)

// MARK: - DuplicateScanProgress

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaDuplicateScanProgress")
data class DuplicateScanProgress(
    val filesHashed: Int,
    val totalFiles: Int,
    val bytesHashed: Long,
    val currentFile: String
) {
    val fraction: Double
        get() = if (totalFiles > 0) filesHashed.toDouble() / totalFiles.toDouble() else 0.0
}

// MARK: - DuplicateStats

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaDuplicateStats")
data class DuplicateStats(
    val groupCount: Int,
    val totalDuplicateFiles: Int,
    val totalWastedSpace: Long,
    val scanDuration: Double
)

// MARK: - DuplicateScanState

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaDuplicateScanState")
sealed class DuplicateScanState {
    @ObjCName("SpaDuplicateScanStateIdle")
    data object Idle : DuplicateScanState()

    @ObjCName("SpaDuplicateScanStateGroupingBySize")
    data object GroupingBySize : DuplicateScanState()

    @ObjCName("SpaDuplicateScanStateHashing")
    data class Hashing(val progress: DuplicateScanProgress) : DuplicateScanState()

    @ObjCName("SpaDuplicateScanStateCompleted")
    data class Completed(val stats: DuplicateStats) : DuplicateScanState()

    @ObjCName("SpaDuplicateScanStateError")
    data class Error(val message: String) : DuplicateScanState()
}

// MARK: - AutoSelectStrategy

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaAutoSelectStrategy")
enum class AutoSelectStrategy(val id: String) {
    KEEP_NEWEST("newest"),
    KEEP_OLDEST("oldest"),
    KEEP_SHORTEST_PATH("shortest");

    val displayName: String
        get() = when (this) {
            KEEP_NEWEST -> "Keep Newest"
            KEEP_OLDEST -> "Keep Oldest"
            KEEP_SHORTEST_PATH -> "Keep Shortest Path"
        }
}

// MARK: - DuplicateSortMode

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaDuplicateSortMode")
enum class DuplicateSortMode(val id: String) {
    WASTED_SPACE("Wasted Space"),
    COUNT("Count"),
    FILE_SIZE("File Size")
}
