package com.spacie.core.api

import com.spacie.core.error.SpacieError
import com.spacie.core.flow.CommonStateFlow
import com.spacie.core.model.DuplicateFilterOptions
import com.spacie.core.model.DuplicateGroup
import com.spacie.core.model.DuplicateScanState
import kotlin.coroutines.cancellation.CancellationException
import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaDuplicateEngineApi")
interface DuplicateEngineApi {

    val state: CommonStateFlow<DuplicateScanState>

    @Throws(SpacieError::class, CancellationException::class)
    suspend fun findDuplicates(filterOptions: DuplicateFilterOptions): List<DuplicateGroup>

    fun cancel()
}
