package com.spacie.core.model

import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaRawFileNode")
data class RawFileNode(
    val name: String,
    val path: String,
    val logicalSize: Long,
    val physicalSize: Long,
    val flags: FileNodeFlags,
    val fileType: FileType,
    val modTime: Int,
    val inode: Long,
    val depth: Int,
    val parentPath: String,
    val entryCount: Int,
    val dirMtime: Long
)
