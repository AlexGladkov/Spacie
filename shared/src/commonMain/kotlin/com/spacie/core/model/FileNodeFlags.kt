package com.spacie.core.model

import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaFileNodeFlags")
class FileNodeFlags(val rawValue: Int) {

    fun contains(flag: FileNodeFlags): Boolean = (rawValue and flag.rawValue) != 0

    infix fun or(other: FileNodeFlags): FileNodeFlags = FileNodeFlags(rawValue or other.rawValue)

    val isDirectory: Boolean get() = contains(IS_DIRECTORY)
    val isSymlink: Boolean get() = contains(IS_SYMLINK)
    val isHidden: Boolean get() = contains(IS_HIDDEN)
    val isRestricted: Boolean get() = contains(IS_RESTRICTED)
    val isPackage: Boolean get() = contains(IS_PACKAGE)
    val isCompressed: Boolean get() = contains(IS_COMPRESSED)
    val isHardLink: Boolean get() = contains(IS_HARD_LINK)
    val isSIPProtected: Boolean get() = contains(IS_SIP_PROTECTED)
    val isExcluded: Boolean get() = contains(IS_EXCLUDED)
    val isVirtual: Boolean get() = contains(IS_VIRTUAL)
    val isDeepScanned: Boolean get() = contains(IS_DEEP_SCANNED)

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is FileNodeFlags) return false
        return rawValue == other.rawValue
    }

    override fun hashCode(): Int = rawValue

    override fun toString(): String = "FileNodeFlags(rawValue=$rawValue)"

    companion object {
        val IS_DIRECTORY = FileNodeFlags(1 shl 0)
        val IS_SYMLINK = FileNodeFlags(1 shl 1)
        val IS_HIDDEN = FileNodeFlags(1 shl 2)
        val IS_RESTRICTED = FileNodeFlags(1 shl 3)
        val IS_PACKAGE = FileNodeFlags(1 shl 4)
        val IS_COMPRESSED = FileNodeFlags(1 shl 5)
        val IS_HARD_LINK = FileNodeFlags(1 shl 6)
        val IS_SIP_PROTECTED = FileNodeFlags(1 shl 7)
        val IS_EXCLUDED = FileNodeFlags(1 shl 8)
        val IS_VIRTUAL = FileNodeFlags(1 shl 9)
        val IS_DEEP_SCANNED = FileNodeFlags(1 shl 10)
    }
}
