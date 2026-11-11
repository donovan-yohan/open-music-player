package com.soundq.android.gallery
import org.junit.Assert.*
import org.junit.Test
class GalleryStateTest {
    @Test fun selectionTogglesWithoutPretendingToPlay() {
        val selected = GalleryState().reduce(GalleryAction.Select("fixture-1"))
        assertEquals("fixture-1", selected.selectedId)
        assertNull(selected.reduce(GalleryAction.Select("fixture-1")).selectedId)
    }
}
