package com.spacie.core.scanner

import com.spacie.core.model.SmartScanSettings
import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

/**
 * Lightweight representation of a directory from the shallow tree.
 *
 * @property index Node index in the flat array.
 * @property entryCount Number of direct entries from readdir() during shallow scan.
 */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaDirEntry")
data class DirEntry(
    val index: Int,
    val entryCount: Int
)

/**
 * Builds a prioritized directory queue for Smart Scan's Phase 2.
 *
 * The queue is divided into two tiers:
 * - **Tier 1**: Known "heavy" directories from the active [ScanProfile].
 *   These are scanned unconditionally and first.
 * - **Tier 2**: All remaining directories not covered by Tier 1,
 *   sorted by cached size (descending) with entry count as fallback.
 */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaSmartScanPrioritizer")
object SmartScanPrioritizer {

    /**
     * Builds a prioritized scanning queue from pre-extracted directory data.
     *
     * @param settings The active Smart Scan settings (determines profile and paths).
     * @param dirsByPath Map of path to [DirEntry] for all directories in the shallow tree.
     * @param cachedDirSizes Optional map of path to byte-size from a previous scan cache.
     * @return Ordered list of (path, entryCount) pairs, Tier 1 first, then Tier 2.
     */
    fun buildPrioritizedQueue(
        settings: SmartScanSettings,
        dirsByPath: Map<String, DirEntry>,
        cachedDirSizes: Map<String, Long>?
    ): List<Pair<String, Int>> {
        // Tier 1: profile paths
        val tier1Paths = ScanProfile.tier1Paths(settings.profile)
        val tier1Set = HashSet<String>(tier1Paths.size)
        val tier1Queue = ArrayList<Pair<String, Int>>(tier1Paths.size)

        for (path in tier1Paths) {
            tier1Set.add(path)
            val entry = dirsByPath[path]
            tier1Queue.add(path to (entry?.entryCount ?: 0))
        }

        // Tier 2: remaining directories NOT in Tier 1 and NOT children of Tier 1 paths
        data class Tier2Item(val path: String, val entryCount: Int, val cachedSize: Long)

        val tier2Queue = ArrayList<Tier2Item>()

        for ((path, entry) in dirsByPath) {
            if (tier1Set.contains(path)) continue
            if (isChildOfAny(path, tier1Set)) continue

            val cachedSize = cachedDirSizes?.get(path) ?: 0L
            tier2Queue.add(Tier2Item(path, entry.entryCount, cachedSize))
        }

        // Sort Tier 2: cached size descending, fallback to entry count descending
        tier2Queue.sortWith(compareByDescending<Tier2Item> { it.cachedSize }
            .thenByDescending { it.entryCount })

        val result = ArrayList<Pair<String, Int>>(tier1Queue.size + tier2Queue.size)
        result.addAll(tier1Queue)
        for (item in tier2Queue) {
            result.add(item.path to item.entryCount)
        }
        return result
    }

    /**
     * Determines whether a directory should be skipped because it (or a parent path)
     * has already been scanned.
     *
     * @param path The absolute path of the directory to check.
     * @param settings Not used directly -- kept for API symmetry. The actual
     *   check is against [completedPaths].
     * @return `true` if the directory should be skipped.
     */
    fun shouldSkipDirectory(path: String, completedPaths: Set<String>): Boolean {
        if (completedPaths.contains(path)) {
            return true
        }
        val dirWithSlash = if (path.endsWith("/")) path else "$path/"
        for (completed in completedPaths) {
            val completedWithSlash = if (completed.endsWith("/")) completed else "$completed/"
            if (dirWithSlash.startsWith(completedWithSlash)) {
                return true
            }
        }
        return false
    }

    // -- Private Helpers --

    private fun isChildOfAny(path: String, parents: Set<String>): Boolean {
        val pathWithSlash = if (path.endsWith("/")) path else "$path/"
        for (parent in parents) {
            val parentWithSlash = if (parent.endsWith("/")) parent else "$parent/"
            if (pathWithSlash.startsWith(parentWithSlash)) {
                return true
            }
        }
        return false
    }
}
