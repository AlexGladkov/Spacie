package com.spacie.core.api

import com.spacie.core.error.SpacieError
import kotlin.coroutines.cancellation.CancellationException

/**
 * Boundary for the `ipatool` CLI client. Extends [AppleIDAuthApi] with the
 * IPA download operation so [TransferOrchestrator] (and unit tests) can swap
 * a fake without touching the real binary.
 */
internal interface IpaToolClientApi : AppleIDAuthApi {

    /**
     * @throws SpacieError.ExtractionFailed
     */
    @Throws(SpacieError::class, CancellationException::class)
    suspend fun downloadIPA(
        bundleID: String,
        destinationDir: String,
        onProgress: (Double) -> Unit
    ): String
}
