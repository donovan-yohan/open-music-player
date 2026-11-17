package com.soundq.android.data
import com.soundq.android.data.imports.*
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
class Store:SessionStore {override fun load(endpoint:ApiEndpoint):SecretTokens?=null;override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){};override fun clear(){}}
internal class Fixture {
 val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),Store()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
 val api=SoundQApi(session);val repo=ImportRepository(session,api,LibraryRepository());val progress=repo.progressObservation
 var now=0L
 init {progress.clock={now};progress.visible(true)}
 fun submit():ImportJobId {
  val view=repo.open()!!;repo.another(view);repo.edit(view,"https://youtube.com/watch?v=fixture")
  repo.submit(repo.claim(view)!!);repo.close(view)
  return repo.state.value.acknowledgement!!.id
 }
 fun receipt(id:ImportJobId,kind:String="queue") {
  val r=api.intakeReceipts.begin(session.endpoint.identity,"A",kind)
  api.intakeReceipts.finish(session.endpoint.identity,"A",r,"accepted",id.value)
 }
 fun status(id:ImportJobId,s:ImportStatus) {api.jobs[id]=api.jobs.getValue(id).copy(status=s,progress=if(s==ImportStatus.Complete)100 else 0)}
 fun checkBatch(active:Int,complete:Int,failed:Int=0,unknown:Int=0) {
  val p=repo.progress.value
  check(p!=null&&listOf(p.active,p.complete,p.failed,p.unknown)==listOf(active,complete,failed,unknown)){"expected $active/$complete/$failed/$unknown, got $p"}
 }
}
fun main(){
 run {
  val f=Fixture();val p=f.progress;val lease=p.open()!!
  val ids=List(3){f.submit()};p.receipts(lease)
  f.checkBatch(0,0,unknown=3) // ACK queued is not an observed job count.
  p.refresh(lease);f.checkBatch(3,0)
  check(f.api.gets==3&&f.api.posts==3)
  f.status(ids[0],ImportStatus.Complete);f.now+=ImportProgressObservation.POLL_MS
  p.refresh(lease);f.checkBatch(2,1)
  ids.forEach {f.status(it,ImportStatus.Complete)};f.now+=ImportProgressObservation.POLL_MS
  p.refresh(lease);f.checkBatch(0,3)
  val calls=f.api.gets
  f.now+=ImportProgressObservation.DWELL_MS-1;p.advance(lease);f.checkBatch(0,3)
  f.now++;p.advance(lease);check(f.repo.progress.value==null&&p.nextDelay(lease)==null)
  repeat(1000){p.receipts(lease);p.refresh(lease)}
  check(f.api.gets==calls&&f.repo.progress.value==null)
  println("PASS actual repository: 3 published -> 3 exact queued -> 2 active/1 complete -> 3 complete -> dwell -> idle, no repeated IO")
 }
 run {
  val f=Fixture();val old=f.submit();val lease=f.progress.open()!!
  f.progress.receipts(lease);f.progress.refresh(lease);check(f.repo.progress.value==null&&f.api.gets==0)
  val id=f.submit();f.receipt(id);f.receipt(id,"source");f.receipt(old,"research")
  f.progress.receipts(lease);f.progress.refresh(lease);f.checkBatch(1,0);check(f.api.gets==1)
  val source=f.api.intakeReceipts.begin(f.session.endpoint.identity,"A","source")
  f.api.intakeReceipts.finish(f.session.endpoint.identity,"A",source,"accepted",decisionId="123e4567-e89b-12d3-a456-000000000099")
  f.progress.receipts(lease);f.checkBatch(1,0)
  println("PASS canonical published queue/source receipts dedupe; historic, research and decision-only evidence excluded")
 }
 run {
  val f=Fixture();val lease=f.progress.open()!!;val ids=List(3){f.submit()}
  f.progress.receipts(lease);f.progress.refresh(lease)
  f.status(ids[0],ImportStatus.Failed);f.api.jobs.remove(ids[1]);f.now+=ImportProgressObservation.POLL_MS
  f.progress.refresh(lease);f.checkBatch(1,0,failed=1,unknown=1)
  f.status(ids[2],ImportStatus.Complete);f.now+=ImportProgressObservation.POLL_MS;f.progress.refresh(lease)
  f.checkBatch(0,1,failed=1,unknown=1);check(f.progress.nextDelay(lease)==null)
  val captured=f.repo.progress.value!!;f.progress.dismiss(captured);check(f.repo.progress.value==null)
  repeat(5){f.progress.receipts(lease);f.progress.refresh(lease)};check(f.repo.progress.value==null)
  f.submit();f.progress.receipts(lease);f.progress.refresh(lease);f.checkBatch(1,0)
  f.progress.dismiss(captured);f.checkBatch(1,0)
  println("PASS failure/unknown are not success; no polling unknown; dismissal/stale dismissal/new batch")
 }
 run {
  val f=Fixture();val lease=f.progress.open()!!;val id=f.submit();f.progress.receipts(lease)
  f.api.beforeRead={_,valid->f.progress.visible(false);f.progress.visible(true);check(!valid())}
  f.progress.refresh(lease);check(f.repo.progress.value==null&&!f.progress.current(lease))
  f.api.beforeRead={_,_->};val next=f.progress.open()!!;f.progress.refresh(next);f.checkBatch(1,0)
  val late=f.api.intakeReceipts.begin(f.session.endpoint.identity,"A","download")
  val lateId=ImportJobId("123e4567-e89b-12d3-a456-000000009999")
  f.api.jobs[lateId]=ImportJob(lateId,ImportStatus.Queued,0,null,"youtube")
  f.progress.visible(false)
  f.progress.visible(true);val returned=f.progress.open()!!
  // The old operation's ACK arrives only after foreground returned, with a distinct real ID.
  f.api.intakeReceipts.finish(f.session.endpoint.identity,"A",late,"accepted",lateId.value)
  f.progress.receipts(returned);f.progress.refresh(returned);f.checkBatch(1,0)
  check(!f.progress.current(next))
  println("PASS immediate background fence, renewed lease, late ACK boundary, existing batch retained")
 }
 run {
  val f=Fixture();val lease=f.progress.open()!!;f.submit();f.progress.receipts(lease)
  f.api.beforeRead={_,valid->
   f.session.accept(f.session.beginIntent(),SecretTokens("b","r","B"))
   f.session.accept(f.session.beginIntent(),SecretTokens("a2","r","A"));check(!valid())
  }
  f.progress.refresh(lease);check(!f.progress.current(lease))
  f.api.beforeRead={_,_->};f.progress.open()!!;check(f.repo.progress.value==null)
  f.repo.retire();check(f.repo.progress.value==null)
  println("PASS account A/B/A rejects held exact read and old batch, canonical retirement clears observer")
 }
 run {
  val f=Fixture();val lease=f.progress.open()!!;repeat(35){f.submit()}
  f.progress.receipts(lease);f.progress.refresh(lease);f.checkBatch(32,0)
  check(f.repo.progress.value!!.needsChecking&&f.api.gets==32)
  f.now+=ImportProgressObservation.EXPIRY_MS
  f.progress.refresh(lease);f.checkBatch(0,0,unknown=32)
  check(f.progress.nextDelay(lease)==null&&f.api.gets==32)
  println("PASS bounded 32-job partial batch and expiry, no false global total")
 }
 run {
  val f=Fixture();val lease=f.progress.open()!!;f.submit();f.progress.receipts(lease)
  repeat(ImportProgressObservation.MAX_READS+10){f.progress.refresh(lease);f.now+=ImportProgressObservation.POLL_MS}
  f.checkBatch(0,0,unknown=1);check(f.api.gets==ImportProgressObservation.MAX_READS&&f.progress.nextDelay(lease)==null)
  println("PASS finite paced read budget, capacity is unknown rather than success")
 }
 run {
  val f=Fixture();val lease=f.progress.open()!!
  val saved=f.api.intakeReceipts.begin(f.session.endpoint.identity,"A","download")
  f.api.intakeReceipts.finish(f.session.endpoint.identity,"A",saved,"uncertain")
  f.progress.receipts(lease);check(f.repo.progress.value!!.needsChecking&&f.api.gets==0&&f.progress.nextDelay(lease)==null)
  check(f.repo.progress.value!!.unknown==0) // A request is not an invented job.
  val view=f.repo.open()!!;check(f.repo.state.value.consumed&&f.repo.state.value.error==SafeFailure.Reason.Uncertain)
  f.progress.dismiss(f.repo.progress.value!!)
  check(f.repo.state.value.consumed&&f.repo.state.value.error==SafeFailure.Reason.Uncertain)
  check(f.repo.claim(view)==null)
  println("PASS uncertain operation has no invented job or spinner; dismiss preserves durable lock/recovery")
 }
 run {
  val f=Fixture();val lease=f.progress.open()!!;val id=f.submit();val view=f.repo.open()!!
  val entered=CountDownLatch(1);val release=CountDownLatch(1)
  f.api.beforeRead={_,_->if(Thread.currentThread().name=="route-read"){entered.countDown();check(release.await(3,TimeUnit.SECONDS))}}
  val route=Thread({f.repo.check(view)},"route-read")
  route.start()
  try {
   check(entered.await(3,TimeUnit.SECONDS)&&f.repo.state.value.loading)
   f.progress.receipts(lease);f.progress.refresh(lease);f.checkBatch(1,0)
   check(f.repo.state.value.loading&&f.repo.state.value.selected==null)
  } finally {release.countDown();route.join(3_000)}
  check(!route.isAlive&&f.repo.state.value.selected?.id==id&&!f.repo.state.value.loading)
  val selected=f.repo.state.value.selected
  f.progress.dismiss(f.repo.progress.value!!);check(f.repo.state.value.selected===selected)
  println("PASS held canonical route read token/selected job survives independent progress read and dismissal")
 }
 run {
  val f=Fixture();f.submit() // Establish an older route owner independently of the observer.
  f.session.accept(f.session.beginIntent(),SecretTokens("b","r","B"))
  f.session.accept(f.session.beginIntent(),SecretTokens("a2","r","A"))
  val fresh=f.progress.open()!!
  f.submit();f.progress.receipts(fresh);f.progress.refresh(fresh)
  check(f.progress.current(fresh)&&f.repo.progress.value?.active==1){"opening Imports must not retire the already-new account observation"}
  println("PASS fresh account observer survives canonical route-owner reset after A/B/A")
 }
 presentationChecks()
 vmChecks()
}
