package com.soundq.android.product.playlists

import org.junit.Assert.*
import org.junit.Test

class PlaylistCreateFormTest {
    @Test fun sameDurableOwnerRetainsDraftAndOpenSheetWithoutSavingAuthority() {
        val draft = PlaylistCreateForm("海辺", "Evening\nset", true)
        val payload = saveCreateForm("https://fixture.invalid/api/v1", "account-a", draft)
        assertEquals(draft, restoreCreateForm("https://fixture.invalid/api/v1", "account-a", payload))
    }
    @Test fun replacementEndpointOrAccountCannotRestoreAnotherOwnersDraft() {
        val payload = saveCreateForm("endpoint-a", "account-a", PlaylistCreateForm("Private title", "Private description", true))
        assertNull(restoreCreateForm("endpoint-b", "account-a", payload))
        assertNull(restoreCreateForm("endpoint-a", "account-b", payload))
        assertNull(restoreCreateForm("endpoint-a", "account-a", payload.toMutableList().also { it[0] = "future:2" }))
        assertNull(restoreCreateForm("endpoint-a", "account-a", payload.take(5)))
        assertNull(restoreCreateForm("endpoint-a", "account-a", payload.toMutableList().also { it[5] = "not-a-boolean" }))
    }
}
