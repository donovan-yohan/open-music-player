package com.soundq.android.gallery
/** Gallery-only presentation. Never playback state or a product library. */
data class GalleryState(val query: String = "", val selectedId: String? = null, val reducedMotion: Boolean = false) {
    fun reduce(action: GalleryAction): GalleryState = when (action) {
        is GalleryAction.Select -> copy(selectedId = action.id.takeUnless { it == selectedId })
    }
}
sealed interface GalleryAction { data class Select(val id: String) : GalleryAction }
