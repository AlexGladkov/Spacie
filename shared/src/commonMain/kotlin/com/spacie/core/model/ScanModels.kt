package com.spacie.core.model

import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

// MARK: - ScanPhase

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaScanPhase")
enum class ScanPhase {
    RED,
    YELLOW,
    SMART_GREEN,
    GREEN
}

// MARK: - ScanState

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaScanState")
sealed class ScanState {
    @ObjCName("SpaScanStateIdle")
    data object Idle : ScanState()

    @ObjCName("SpaScanStateScanning")
    data class Scanning(val progress: ScanProgress) : ScanState()

    @ObjCName("SpaScanStateCompleted")
    data class Completed(val stats: ScanStats) : ScanState()

    @ObjCName("SpaScanStateCancelled")
    data object Cancelled : ScanState()

    @ObjCName("SpaScanStateError")
    data class Error(val message: String) : ScanState()

    val isScanning: Boolean get() = this is Scanning
    val isCompleted: Boolean get() = this is Completed
}

// MARK: - ScanProgress

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaScanProgress")
data class ScanProgress(
    val filesScanned: Long,
    val directoriesScanned: Long,
    val skippedDirectories: Long,
    val totalLogicalSizeScanned: Long,
    val totalPhysicalSizeScanned: Long,
    val currentPath: String,
    val elapsedTime: Double,
    val estimatedTotalFiles: Long?,
    val phase: ScanPhase,
    val deepScanProgress: Double?,
    val deepScanDirsCompleted: Long,
    val deepScanDirsTotal: Long,
    val coveragePercent: Double?,
    val scannedBytes: Long,
    val estimatedUsedSpace: Long
) {
    fun totalSizeScanned(mode: SizeMode): Long = when (mode) {
        SizeMode.LOGICAL -> totalLogicalSizeScanned
        SizeMode.PHYSICAL -> totalPhysicalSizeScanned
    }

    val estimatedProgress: Double?
        get() {
            val total = estimatedTotalFiles ?: return null
            if (total <= 0) return null
            return minOf(1.0, filesScanned.toDouble() / total.toDouble())
        }

    val filesPerSecond: Double
        get() {
            if (elapsedTime <= 0.0) return 0.0
            return filesScanned.toDouble() / elapsedTime
        }
}

// MARK: - ScanStats

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaScanStats")
data class ScanStats(
    val totalFiles: Long,
    val totalDirectories: Long,
    val totalLogicalSize: Long,
    val totalPhysicalSize: Long,
    val restrictedDirectories: Long,
    val skippedDirectories: Long,
    val scanDuration: Double,
    val volumeId: String
) {
    val filesPerSecond: Double
        get() {
            if (scanDuration <= 0.0) return 0.0
            return totalFiles.toDouble() / scanDuration
        }
}

// MARK: - ScanEvent

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaScanEvent")
sealed class ScanEvent {
    @ObjCName("SpaScanEventDirectoryEntered")
    data class DirectoryEntered(val path: String, val depth: Int) : ScanEvent()

    @ObjCName("SpaScanEventFileFound")
    data class FileFound(val node: RawFileNode) : ScanEvent()

    @ObjCName("SpaScanEventDirectoryCompleted")
    data class DirectoryCompleted(val path: String, val totalSize: Long) : ScanEvent()

    @ObjCName("SpaScanEventDirectorySkipped")
    data class DirectorySkipped(val path: String, val depth: Int) : ScanEvent()

    @ObjCName("SpaScanEventProgress")
    data class Progress(val progress: ScanProgress) : ScanEvent()

    @ObjCName("SpaScanEventRestricted")
    data class Restricted(val path: String) : ScanEvent()

    @ObjCName("SpaScanEventError")
    data class Error(val path: String, val code: Int, val message: String) : ScanEvent()

    @ObjCName("SpaScanEventCompleted")
    data class Completed(val stats: ScanStats) : ScanEvent()
}

// MARK: - ScanConfiguration

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaScanConfiguration")
data class ScanConfiguration(
    val rootPath: String,
    val volumeId: String,
    val followSymlinks: Boolean,
    val crossMountPoints: Boolean,
    val includeHidden: Boolean,
    val batchSize: Int,
    val throttleInterval: Double,
    val exclusionBasenames: Set<String>,
    val exclusionPathPrefixes: List<String>
)

// MARK: - SizeMode

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaSizeMode")
enum class SizeMode(val id: String) {
    LOGICAL("logical"),
    PHYSICAL("physical");

    val displayName: String
        get() = when (this) {
            LOGICAL -> "Logical Size"
            PHYSICAL -> "Disk Usage"
        }
}

// MARK: - VisualizationMode

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaVisualizationMode")
enum class VisualizationMode(val id: String) {
    SUNBURST("sunburst"),
    TREEMAP("treemap");

    val displayName: String
        get() = when (this) {
            SUNBURST -> "Sunburst"
            TREEMAP -> "Treemap"
        }

    val systemImage: String
        get() = when (this) {
            SUNBURST -> "circle.circle"
            TREEMAP -> "square.grid.2x2"
        }
}

// MARK: - ScanProfileType

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaScanProfileType")
enum class ScanProfileType(val id: String) {
    DEFAULT("default"),
    DEVELOPER("developer");

    val displayName: String
        get() = when (this) {
            DEFAULT -> "Default"
            DEVELOPER -> "Developer"
        }
}

// MARK: - SmartScanSettings

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaSmartScanSettings")
data class SmartScanSettings(
    val isEnabled: Boolean,
    val profile: ScanProfileType,
    val coverageThreshold: Double
) {
    val rescanTriggerThreshold: Double
        get() = maxOf(0.80, coverageThreshold - 0.05)
}

// MARK: - SmartScanResult

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaSmartScanResult")
data class SmartScanResult(
    val coveragePercent: Double,
    val scannedBytes: Long,
    val estimatedUsedSpace: Long,
    val unscannedDirectoryCount: Int
)
