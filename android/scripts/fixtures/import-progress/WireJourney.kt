package com.soundq.android.data

import com.soundq.android.data.imports.*
import com.soundq.android.data.discovery.SourceDecision
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody

private class WireStore:SessionStore {
 override fun load(endpoint:ApiEndpoint):SecretTokens?=null
 override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){}
 override fun clear(){}
}
fun main() {
 val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),WireStore()).apply {accept(beginIntent(),SecretTokens("synthetic","synthetic","A"))}
 val calls=mutableListOf<String>();val statuses=linkedMapOf<String,String>();var sequence=0
 var beforeReturn:()->Unit={}
 val client=OkHttpClient.Builder().addInterceptor {chain->
  val request=chain.request();check(request.url.host=="fixture.invalid")
  val guardClass=Class.forName("com.soundq.android.data.SoundQApi\$WireGuard")
  val guard=request.tag(guardClass)!!
  @Suppress("UNCHECKED_CAST") val valid=guardClass.getDeclaredMethod("getValid").apply {isAccessible=true}.invoke(guard) as ()->Boolean
  if(!valid())throw SafeFailure(SafeFailure.Reason.Retired)
  calls.add(request.method+" "+request.url.encodedPath)
  val body=when {
   request.method=="POST"&&request.url.encodedPath=="/api/v1/downloads"->{
    val id="123e4567-e89b-12d3-a456-"+(++sequence).toString().padStart(12,'0');statuses[id]="queued"
    """{"job_id":"$id","status":"queued"}"""
   }
   request.method=="POST"&&request.url.encodedPath=="/api/v1/queue/items"->{
    val id=statuses.keys.last()
    """{"queue":{},"idempotent":true,"downloadJobId":"$id"}"""
   }
   request.method=="GET"&&request.url.encodedPath.startsWith("/api/v1/downloads/")->{
    val id=request.url.pathSegments.last();val status=statuses.getValue(id)
    """{"job_id":"$id","status":"$status","progress":0,"track_id":null,"source_type":"youtube","created_at":"2026-11-14T12:00:00Z","error":"https://private.invalid/never-present"}"""
   }
   else->error("unexpected synthetic request")
  }
  beforeReturn()
  Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(if(request.method=="POST"&&request.url.encodedPath.endsWith("/downloads"))201 else 200)
   .message("synthetic").body(body.toResponseBody("application/json".toMediaType())).build()
 }.build()
 try {
  val api=SoundQApi(session,client);val repo=ImportRepository(session,api,LibraryRepository())
  val progress=repo.progressObservation;var now=0L;progress.clock={now};progress.visible(true);val lease=progress.open()!!
  repeat(3) {
   val view=repo.open()!!;repo.another(view);repo.edit(view,"https://youtube.com/watch?v=synthetic")
   repo.submit(repo.claim(view)!!);repo.close(view)
  }
  check(calls.count {it.startsWith("POST") }==3)
  check(api.intakeReceipts.entries(session.endpoint.identity,"A").size==3)
  progress.receipts(lease);progress.refresh(lease)
  check(repo.progress.value!!.active==3&&repo.progress.value!!.complete==0)
  statuses[statuses.keys.first()]="complete";now+=ImportProgressObservation.POLL_MS
  progress.refresh(lease);check(repo.progress.value!!.active==2&&repo.progress.value!!.complete==1)
  statuses.keys.toList().forEach {statuses[it]="complete"};now+=ImportProgressObservation.POLL_MS
  progress.refresh(lease);check(repo.progress.value!!.active==0&&repo.progress.value!!.complete==3)
  now+=ImportProgressObservation.DWELL_MS;progress.advance(lease);check(repo.progress.value==null)
  val callsAtIdle=calls.size;repeat(500){progress.receipts(lease);progress.refresh(lease)};check(calls.size==callsAtIdle)
  // Same published queue job arriving through a second canonical receipt is not another job.
  val saved=api.intakeReceipts.begin(session.endpoint.identity,"A","source",sessionId="123e4567-e89b-12d3-a456-000000000098",candidateId="synthetic",decisionId="123e4567-e89b-12d3-a456-000000000099")
  api.intakeReceipts.finish(session.endpoint.identity,"A",saved,"accepted",decisionId=saved.decisionId)
  api.queueSourceDecision(session.capture()!!,SourceDecision(saved.decisionId!!,saved.sessionId!!,"synthetic",null),{true},{true})
  progress.receipts(lease);progress.refresh(lease);check(repo.progress.value==null)
  val view=repo.open()!!;repo.another(view);repo.edit(view,"https://youtube.com/watch?v=synthetic2");repo.submit(repo.claim(view)!!)
  statuses[statuses.keys.last()]="invented-status"
  progress.receipts(lease);progress.refresh(lease)
  check(repo.progress.value!!.unknown==1&&repo.progress.value!!.active==0&&repo.progress.value!!.complete==0)
  check(progress.nextDelay(lease)==null&&!repo.progress.value.toString().contains("private.invalid"))
  println("PASS real SoundQApi + WireGuard + strict ImportJson + durable receipts + ImportRepository: three imports, exact-job transitions, terminal dwell, idle no IO, queue dedupe, invalid-status unknown")
 } finally {client.connectionPool.evictAll();client.dispatcher.executorService.shutdownNow()}
}
