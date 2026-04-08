package com.spacie.core.model

import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

// MARK: - SortCriteria

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaSortCriteria")
enum class SortCriteria(val id: String) {
    SIZE("size"),
    NAME("name"),
    DATE("date"),
    TYPE("type");

    val displayName: String
        get() = when (this) {
            SIZE -> "Size"
            NAME -> "Name"
            DATE -> "Date Modified"
            TYPE -> "Type"
        }
}

// MARK: - TreeSortOrder

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaTreeSortOrder")
data class TreeSortOrder(
    val criteria: SortCriteria,
    val ascending: Boolean
) {
    fun toggled(newCriteria: SortCriteria): TreeSortOrder {
        return if (criteria == newCriteria) {
            copy(ascending = !ascending)
        } else {
            TreeSortOrder(
                criteria = newCriteria,
                ascending = newCriteria == SortCriteria.NAME || newCriteria == SortCriteria.TYPE
            )
        }
    }

    companion object {
        val sizeDescending = TreeSortOrder(SortCriteria.SIZE, ascending = false)
        val nameAscending = TreeSortOrder(SortCriteria.NAME, ascending = true)
        val dateDescending = TreeSortOrder(SortCriteria.DATE, ascending = false)
        val typeAscending = TreeSortOrder(SortCriteria.TYPE, ascending = true)
        val size = sizeDescending
    }
}
