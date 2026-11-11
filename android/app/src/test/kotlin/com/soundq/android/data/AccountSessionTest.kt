package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test

internal class MemoryStore : SessionStore {
    var tokens: SecretTokens? = null
    var writes = 0
    var fail = false
    override fun load(endpoint: ApiEndpoint) = tokens
    override fun save(endpoint: ApiEndpoint, tokens: SecretTokens) { writes++; if (fail) throw java.io.IOException(); this.tokens = tokens }
    override fun clear() { tokens = null }
}
class AccountSessionTest {
    private val endpoint = ApiEndpoint.parse("https://fixture.test/api/v1")
    @Test fun lateLoginCannotAdoptReplacementOrOverwriteItsStore() {
        val store = MemoryStore(); val session = AccountSession(endpoint, store)
        val old = session.beginIntent(); session.retire()
        val replacement = session.beginIntent()
        assertTrue(session.accept(replacement, SecretTokens("b", "br", "B")))
        assertFalse(session.accept(old, SecretTokens("a", "ar", "A")))
        assertEquals("B", session.capture()?.accountId)
        assertEquals("B", store.tokens?.accountId)
        val scope = session.capture()!!; session.retire(); assertFalse(session.current(scope))
    }
}
