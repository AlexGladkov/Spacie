package com.spacie.core.model

import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaFileNodeInfo")
data class FileNodeInfo(
    val id: Int,
    val name: String,
    val fullPath: String,
    val logicalSize: Long,
    val physicalSize: Long,
    val isDirectory: Boolean,
    val fileType: FileType,
    val modificationDate: Long,
    val childCount: Int,
    val entryCount: Int,
    val depth: Int,
    val flags: FileNodeFlags,
    val dirMtime: Long
) {
    val isVirtual: Boolean get() = flags.isVirtual
}
