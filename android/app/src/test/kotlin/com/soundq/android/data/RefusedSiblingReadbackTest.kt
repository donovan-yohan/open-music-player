package com.soundq.android.data
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test
class RefusedSiblingReadbackTest {
 @Test fun refusedSiblingCannotDiscardAcknowledgedReadback() {
  val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore())
  session.accept(session.beginIntent(),SecretTokens("a","r","A"))
  val rows=listOf(Track(TrackId(1),"one",liked=false),Track(TrackId(2),"two",liked=false))
  val loaded=CountDownLatch(1);val release=CountDownLatch(1);val calls=AtomicInteger();val writes=AtomicInteger()
  val pool=Executors.newSingleThreadExecutor()
  val repository=LibraryRepository(session,{_,_,o ->
   if(calls.incrementAndGet()>1) {loaded.countDown();check(release.await(3,TimeUnit.SECONDS));LibraryPage(listOf(rows[0].copy(liked=true),rows[1]),2,20,o)}
   else LibraryPage(rows,2,20,o)
  },{_,id,_ -> writes.incrementAndGet();if(id.value==2L)throw SafeFailure(SafeFailure.Reason.Refused)})
  try {
   repository.refine(LibraryQuery())
   val a=pool.submit {repository.like(rows[0])}
   assertTrue("A must reach held readback after acknowledged write",loaded.await(2,TimeUnit.SECONDS))
   repository.like(rows[1])
   assertEquals(MutationOutcome.Refused,repository.state.value.mutations[rows[1].id])
   release.countDown();a.get(3,TimeUnit.SECONDS)
   println("WITNESS A=${repository.state.value.mutations[rows[0].id]} B=${repository.state.value.mutations[rows[1].id]} A-liked=${repository.state.value.rows[0].liked} reads=${calls.get()} writes=${writes.get()} error=${repository.state.value.error}")
   assertEquals("Refused B must not discard A acknowledged readback",true,repository.state.value.rows[0].liked)
  } finally {release.countDown();pool.shutdownNow();check(pool.awaitTermination(3,TimeUnit.SECONDS))}
 }
 @Test fun refusedSiblingPreservesReadbackFailureFeedback() {
  val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore())
  session.accept(session.beginIntent(),SecretTokens("a","r","A"))
  val rows=listOf(Track(TrackId(1),"one",liked=false),Track(TrackId(2),"two",liked=false))
  val entered=CountDownLatch(1);val release=CountDownLatch(1);val calls=AtomicInteger()
  val pool=Executors.newSingleThreadExecutor()
  val repository=LibraryRepository(session,{_,_,o ->
   if(calls.incrementAndGet()>1) {entered.countDown();check(release.await(3,TimeUnit.SECONDS));throw SafeFailure(SafeFailure.Reason.Network)}
   LibraryPage(rows,2,20,o)
  },{_,id,_ -> if(id.value==2L)throw SafeFailure(SafeFailure.Reason.Refused)})
  try {
   repository.refine(LibraryQuery());val first=pool.submit {repository.like(rows[0])}
   assertTrue(entered.await(2,TimeUnit.SECONDS));repository.like(rows[1])
   release.countDown();first.get(3,TimeUnit.SECONDS)
   assertEquals(MutationOutcome.ReadbackFailed,repository.state.value.mutations[rows[0].id])
   assertEquals("Refused B must retain A readback recovery",SafeFailure.Reason.Network,repository.state.value.error)
  } finally {release.countDown();pool.shutdownNow();check(pool.awaitTermination(3,TimeUnit.SECONDS))}
 }
 @Test fun mutationAdmissionStillInvalidatesOrdinaryPagingWhenRefused() {
  val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore())
  session.accept(session.beginIntent(),SecretTokens("a","r","A"))
  val row=Track(TrackId(1),"one",liked=false)
  val entered=CountDownLatch(1);val release=CountDownLatch(1);val writes=AtomicInteger()
  val pool=Executors.newSingleThreadExecutor()
  val repository=LibraryRepository(session,{_,_,o ->
   if(o>0) {entered.countDown();check(release.await(3,TimeUnit.SECONDS));LibraryPage(listOf(Track(TrackId(2),"obsolete",liked=false)),2,20,o)}
   else LibraryPage(listOf(row),2,20,o)
  },{_,_,_ -> writes.incrementAndGet();throw SafeFailure(SafeFailure.Reason.Refused)})
  try {
   repository.refine(LibraryQuery());val page=pool.submit {repository.loadMore()}
   assertTrue(entered.await(2,TimeUnit.SECONDS));repository.like(row)
   release.countDown();page.get(3,TimeUnit.SECONDS)
   assertEquals(listOf(row),repository.state.value.rows)
   assertFalse(repository.state.value.loading);assertEquals(1,writes.get())
   assertEquals(MutationOutcome.Refused,repository.state.value.mutations[row.id])
  } finally {release.countDown();pool.shutdownNow();check(pool.awaitTermination(3,TimeUnit.SECONDS))}
 }
 @Test fun newerPossibleWriteSupersedesOlderReadbackInEitherOutcome() {
  for(uncertain in listOf(false,true)) {
   val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore())
   session.accept(session.beginIntent(),SecretTokens("a","r","A"))
   val rows=listOf(Track(TrackId(1),"one",liked=false),Track(TrackId(2),"two",liked=false))
   val entered=CountDownLatch(1);val release=CountDownLatch(1);val reads=AtomicInteger();val writes=AtomicInteger()
   val pool=Executors.newSingleThreadExecutor()
   val newer=listOf(rows[0].copy(liked=true),rows[1].copy(liked=true))
   val repository=LibraryRepository(session,{_,_,o ->
    when(reads.incrementAndGet()) {
     1 -> LibraryPage(rows,2,20,o)
     2 -> {entered.countDown();check(release.await(3,TimeUnit.SECONDS));LibraryPage(listOf(rows[0].copy(liked=true),rows[1]),2,20,o)}
     else -> LibraryPage(newer,2,20,o)
    }
   },{_,id,_ -> writes.incrementAndGet();if(id.value==2L&&uncertain)throw SafeFailure(SafeFailure.Reason.Uncertain)})
   try {
    repository.refine(LibraryQuery());val first=pool.submit {repository.like(rows[0])}
    assertTrue(entered.await(2,TimeUnit.SECONDS));repository.like(rows[1])
    assertEquals(newer,repository.state.value.rows)
    release.countDown();first.get(3,TimeUnit.SECONDS)
    assertEquals("Older ACK cannot erase newer possible-write readback",newer,repository.state.value.rows)
    assertEquals(MutationOutcome.Confirmed,repository.state.value.mutations[rows[0].id])
    assertEquals(if(uncertain)MutationOutcome.Uncertain else MutationOutcome.Confirmed,repository.state.value.mutations[rows[1].id])
    assertEquals(2,writes.get());assertEquals(3,reads.get())
   } finally {release.countDown();pool.shutdownNow();check(pool.awaitTermination(3,TimeUnit.SECONDS))}
  }
 }
}
