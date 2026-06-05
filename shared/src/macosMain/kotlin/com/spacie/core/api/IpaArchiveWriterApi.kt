package com.spacie.core.api

import com.spacie.core.error.SpacieError
import com.spacie.core.model.AppInfo

/**
 * Boundary for archiving an extracted IPA + metadata to disk.
 *
 * Extracted as an interface so [TransferOrchestrator] can be unit-tested with
 * a fake writer that records calls without touching the file system, and so
 * future archive backends (e.g. iCloud, S3, encrypted vault) can plug in
 * without changing orchestration code.
 */
internal interface IpaArchiveWriterApi {

    /**
     * Persist [ipaPath] (and any extras like icon/metadata) under [archiveDir].
     *
     * @throws SpacieError.ArchiveWriteFailed on any IO failure.
     */
    suspend fun write(ipaPath: String, app: AppInfo, archiveDir: String)
}
