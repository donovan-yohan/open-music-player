package com.soundq.android.playback
internal enum class CatalogResult { Empty, InvalidRequest }
internal object FoundationCatalog {
    const val ROOT = "soundq:foundation"
    fun children(parent: String, page: Int, size: Int): CatalogResult =
        if (parent == ROOT && page >= 0 && size > 0) CatalogResult.Empty else CatalogResult.InvalidRequest
    fun acceptsController(appUid: Int, controllerUid: Int): Boolean = appUid == controllerUid
}
