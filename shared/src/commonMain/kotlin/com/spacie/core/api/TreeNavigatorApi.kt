package com.spacie.core.api

import com.spacie.core.model.FileNodeInfo
import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaTreeNavigatorApi")
interface TreeNavigatorApi {

    fun rootNode(): FileNodeInfo?
    fun children(nodeId: Int): List<FileNodeInfo>
    fun children(nodeId: Int, offset: Int, limit: Int): List<FileNodeInfo>
    fun nodeInfo(nodeId: Int): FileNodeInfo?
    fun fullPath(nodeId: Int): String
    fun ancestors(nodeId: Int): List<FileNodeInfo>
    fun largestFiles(rootNodeId: Int, limit: Int): List<FileNodeInfo>
    fun childCount(nodeId: Int): Int
    fun logicalSize(nodeId: Int): Long
    fun physicalSize(nodeId: Int): Long
}
