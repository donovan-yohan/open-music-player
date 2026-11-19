package com.soundq.android.playback

import com.soundq.android.data.imports.ImportSource
import com.soundq.android.data.AccountSession
import com.soundq.android.data.ApiEndpoint
import com.soundq.android.data.SessionStore
import com.soundq.android.data.SecretTokens
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DiscoveryPreviewAdmissionTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun heldPreparationCannotCommitAfterNewIntentOrDetachedService() = runBlocking {
        val admission = ContextStartAdmission(temporary.newFolder())
        val session = AccountSession(ApiEndpoint.parse("https://localhost/api/v1"), object : SessionStore {
            override fun load(endpoint: ApiEndpoint): SecretTokens? = null
            override fun save(endpoint: ApiEndpoint, tokens: SecretTokens) = Unit
            override fun clear() = Unit
        })
        session.accept(session.beginIntent(), SecretTokens("a","r","account"))
        val scope = checkNotNull(session.capture())
        val source = checkNotNull(ImportSource.parse("https://youtu.be/fixture"))
        val release = CompletableDeferred<Unit>()
        val target = DiscoveryPreviewHandoff { captured, exact, title, _, current ->
            assertSame(scope,captured)
            assertSame(source,exact)
            if (title == "old") release.await()
            current()
        }
        admission.discoveryPreview = target
        val old = admission.captureRead()
        val held = async(start = CoroutineStart.UNDISPATCHED) { admission.startDiscoveryPreview(scope,source,"old","Artist",old) }
        val newer = admission.captureRead()
        release.complete(Unit)
        assertFalse(held.await())
        assertTrue(newer())
        assertTrue(admission.startDiscoveryPreview(scope,source,"new","Artist",newer))
        assertFalse(newer())
        val fresh = admission.captureRead()
        admission.discoveryPreview = DiscoveryPreviewHandoff { _, _, _, _, current ->
            admission.discoveryPreview = null
            current()
        }
        assertFalse(admission.startDiscoveryPreview(scope,source,"detached","Artist",fresh))
        assertTrue(fresh())
    }
}
