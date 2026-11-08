package com.soundq.android

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class ActionSettlementTest {
    @Test fun heldActionSettlesWithoutJoiningPermanentSibling() = runBlocking {
        val parent=SupervisorJob()
        val scope=CoroutineScope(parent+Dispatchers.Default)
        val started=CompletableDeferred<Unit>()
        val release=CompletableDeferred<Unit>()
        val permanent=scope.launch {awaitCancellation()}
        try {
            val admitted=admittedActionJobs(parent) {scope.launch {started.complete(Unit);release.await()}}
            started.await()
            val settled=async {withTimeout(5000) {admitted.forEach {it.join()}}}
            yield()
            assertFalse("must await held finite action",settled.isCompleted)
            assertTrue(permanent.isActive)
            release.complete(Unit)
            settled.await()
            assertTrue("must not retire permanent collector",permanent.isActive)
            assertTrue("refused callback admits no jobs",admittedActionJobs(parent) {}.isEmpty())
        } finally {release.complete(Unit);parent.cancelAndJoin()}
    }
}
