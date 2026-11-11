package com.soundq.android.data

import com.soundq.android.data.imports.*
import org.junit.Assert.*
import org.junit.Test

class AcquisitionIntakeTest {
    @Test fun aReceiptSurvivesImportOwnerRecreationWithoutASecondPost() {
        HttpsFixture().use { f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val library=LibraryRepository(session,api::library,api::like)
            val repo=ImportRepository(session,api,library);val view=repo.open()!!
            repo.edit(view,"https://youtu.be/fixture")
            f.reply("""{"job_id":"123e4567-e89b-12d3-a456-426614174000","status":"queued"}""",201)
            repo.submit(repo.claim(view)!!)
            val recreated=ImportRepository(session,api,library);recreated.open()
            assertEquals("123e4567-e89b-12d3-a456-426614174000",recreated.state.value.acknowledgement?.id?.value)
            assertEquals(1,f.server.requestCount)
        }
    }
    @Test fun closingImportsBeforeWorkerEntryCannotSendDirectImport() {
        HttpsFixture().use { f ->
            val session=AccountSession(f.endpoint,MemoryStore())
            session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client)
            val repository=ImportRepository(session,api,LibraryRepository(session,api::library,api::like))
            val view=repository.open()!!
            repository.edit(view,"https://youtu.be/fixture")
            val submission=repository.claim(view)!!
            repository.close(view)
            f.reply("""{"job_id":"123e4567-e89b-12d3-a456-426614174000","status":"queued"}""",201)
            repository.submit(submission)
            assertEquals("A retired route cannot start a new import",0,f.server.requestCount)
            assertFalse(repository.state.value.pending)
        }
    }
}
