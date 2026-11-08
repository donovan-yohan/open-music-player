package com.soundq.android.localunlock

import com.soundq.android.data.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class LocalUnlockTest {
    private class Fixture:AutoCloseable {
        val dir=Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"unlock-metadata").toFile()
        val endpoint=ApiEndpoint.parse("https://unlock.example.test/api/v1")
        var saved:SecretTokens?=null
        val store=object:SessionStore {
            override fun load(endpoint:ApiEndpoint)=saved
            override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){saved=tokens}
            override fun clear(){saved=null}
        }
        val session=AccountSession(endpoint,store).also {it.accept(it.beginIntent(),SecretTokens("a","r","A"))}
        val file=dir.resolve("local-unlock")
        val unlock=LocalUnlock(file,session).also {it.loadBeforeRestore()}
        override fun close(){dir.deleteRecursively()}
    }
    @Test fun canceledEnrollmentCannotEnableAndSavedEnrollmentLocksReconstructedSessionBeforeReadingTokens() {
        Fixture().use {f ->
            assertFalse(f.unlock.complete(f.unlock.requestEnrollment(true)!!,false){true});assertFalse(f.unlock.state.value.enrolled);assertFalse(f.file.exists())
            assertTrue(f.unlock.complete(f.unlock.requestEnrollment(true)!!,true){true});assertTrue(f.unlock.state.value.enrolled)
            val bytes=f.file.readBytes();assertFalse(String(bytes).contains("refresh"))
            val session=AccountSession(f.endpoint,f.store);val next=LocalUnlock(f.file,session);next.loadBeforeRestore()
            assertEquals(AuthState.LocalLocked,session.state.value);assertFalse(session.useDeviceDownloads());assertFalse(session.restore {error("must not refresh")})
            assertTrue(next.complete(next.requestUnlock()!!,true){true});assertEquals(AuthState.Restoring,session.state.value)
            assertTrue(session.useDeviceDownloads());assertEquals(AuthState.DeviceOnly("A"),session.state.value)
            assertArrayEquals(bytes,f.file.readBytes())
        }
    }
    @Test fun routeExitAndSameAccountReplacementRetireEnrollmentCallbacksAndPasswordFallbackRetiresSecrets() {
        Fixture().use {f ->
            val retired=f.unlock.requestEnrollment(true)!!
            assertFalse(f.unlock.complete(retired,true){false});assertFalse(f.file.exists())
            val old=f.unlock.requestEnrollment(true)!!
            f.session.accept(f.session.beginIntent(),SecretTokens("a2","r2","A"))
            assertFalse(f.unlock.complete(old,true){true});assertFalse(f.file.exists())
            f.unlock.cancel()
            assertTrue(f.unlock.complete(f.unlock.requestEnrollment(true)!!,true){true});assertTrue(f.unlock.lock())
            val prompt=f.unlock.requestUnlock()!!;f.unlock.passwordFallback()
            assertFalse(f.unlock.complete(prompt,true){true});assertNull(f.saved);assertFalse(f.file.exists());assertTrue(f.session.state.value is AuthState.SignedOut)
        }
    }
    @Test fun queuedPasswordFallbackCannotRetireReplacementSession() {
        Fixture().use {f ->
            val version=f.session.version();f.session.accept(f.session.beginIntent(),SecretTokens("b","br","B"))
            f.unlock.passwordFallback(version){true}
            assertEquals(AuthState.SignedIn("B"),f.session.state.value);assertEquals("B",f.saved?.accountId)
        }
    }
    @Test fun failedEnrollmentWriteRetainsAcceptedChoiceAndForeignBytes() {
        Fixture().use {f ->
            val request=f.unlock.requestEnrollment(true)!!;f.file.writeText("foreign enrollment")
            assertFalse(f.unlock.complete(request,true){true});assertFalse(f.unlock.state.value.enrolled)
            assertEquals("foreign enrollment",f.file.readText())
        }
    }
    @Test fun enrollmentForAnotherAccountRejectsSavedRecordWithoutRefreshingOrRewritingIt() {
        Fixture().use {f ->
            assertTrue(f.unlock.complete(f.unlock.requestEnrollment(true)!!,true){true})
            val enrolled=f.file.readBytes();f.saved=SecretTokens("foreign","foreign-refresh","B")
            val session=AccountSession(f.endpoint,f.store);val next=LocalUnlock(f.file,session);next.loadBeforeRestore()
            assertTrue(next.complete(next.requestUnlock()!!,true){true})
            assertFalse(session.useDeviceDownloads());assertNull(session.capture());assertEquals("B",f.saved?.accountId)
            assertArrayEquals(enrolled,f.file.readBytes())
        }
    }
    @Test fun retainedPasswordSubmissionCannotBypassLocalGate() {
        HttpsFixture().use {tls ->
            Fixture().use {f ->
                f.session.lockLocal()
                assertFalse(SoundQApi(f.session,tls.client).authenticate("old@example.test","test-password"))
                assertEquals(AuthState.LocalLocked,f.session.state.value);assertEquals(0,tls.server.requestCount)
            }
        }
    }
}
