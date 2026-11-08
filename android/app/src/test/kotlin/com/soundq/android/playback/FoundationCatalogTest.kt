package com.soundq.android.playback
import org.junit.Assert.*
import org.junit.Test
class FoundationCatalogTest {
    @Test fun emptyRootIsNotAPlayableCatalog() {
        assertEquals(CatalogResult.Empty, FoundationCatalog.children(FoundationCatalog.ROOT, 0, 20))
        assertEquals(CatalogResult.InvalidRequest, FoundationCatalog.children("https://untrusted.invalid/audio", 0, 20))
        assertEquals(CatalogResult.InvalidRequest, FoundationCatalog.children(FoundationCatalog.ROOT, -1, 20))
        assertEquals(CatalogResult.InvalidRequest, FoundationCatalog.children(FoundationCatalog.ROOT, 0, 0))
    }
    @Test fun onlyThisApplicationUidCanConnect() {
        assertTrue(FoundationCatalog.acceptsController(1000, 1000))
        assertFalse(FoundationCatalog.acceptsController(1000, 2000))
    }
}
