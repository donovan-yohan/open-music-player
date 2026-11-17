package com.soundq.android.data
import com.soundq.android.data.imports.*
import com.soundq.android.data.discovery.*
import com.soundq.android.data.playlists.*
import com.soundq.android.data.acquisition.IntakeReceipts
class LibraryCollection
class LibraryRepository {fun revealImported(t:TrackId,v:()->Boolean)=false}
class Detail(val tracks:List<Track> = emptyList())
class SoundQApi(val session:AccountSession) {
 val intakeReceipts=IntakeReceipts()
 var next=1;var gets=0;var posts=0
 val jobs=mutableMapOf<ImportJobId,ImportJob>()
 var beforeRead:(ImportJobId,()->Boolean)->Unit={_,_->}
 fun createImport(s:AccountScope,source:ImportSource,admit:()->Boolean,current:()->Boolean):ImportAcknowledgement {
  check(admit()&&current());posts++
  val id=ImportJobId("123e4567-e89b-12d3-a456-"+next++.toString().padStart(12,'0'))
  val receipt=intakeReceipts.begin(session.endpoint.identity,s.accountId,"download")
  val job=ImportJob(id,ImportStatus.Queued,0,null,"youtube");jobs[id]=job
  intakeReceipts.finish(session.endpoint.identity,s.accountId,receipt,"accepted",id.value)
  return ImportAcknowledgement(id,ImportStatus.Queued)
 }
 fun importJob(s:AccountScope,id:ImportJobId,current:()->Boolean):ImportJob {
  check(current()&&session.remoteCurrent(s));gets++;beforeRead(id,current)
  return jobs[id] ?: throw SafeFailure(SafeFailure.Reason.Network)
 }
 fun recentImports(s:AccountScope,v:()->Boolean):List<ImportJob> = error("recent-page fallback forbidden")
 fun playlists(s:AccountScope,offset:Int,v:()->Boolean):PlaylistPage=error("unrelated")
 fun trackDetailsSnapshot(s:AccountScope,t:TrackId,v:()->Boolean):Track?=error("unrelated")
 fun playlistDetail(s:AccountScope,p:PlaylistId,v:()->Boolean):Detail=error("unrelated")
 fun createSourceDecision(s:AccountScope,c:SourceChoice,v:()->Boolean,admit:()->Boolean,playlistId:PlaylistId?):SourceDecision=error("unrelated")
 fun queueSourceDecision(s:AccountScope,d:SourceDecision,v:()->Boolean,admit:()->Boolean):ImportAcknowledgement=error("unrelated")
 fun sourceDecision(s:AccountScope,d:SourceDecision,v:()->Boolean):SourceDecision=error("unrelated")
 fun findSourceDecision(s:AccountScope,c:SourceChoice,v:()->Boolean):SourceDecision?=error("unrelated")
 fun recoverDurableSource(s:AccountScope,r:com.soundq.android.data.acquisition.IntakeReceipt,v:()->Boolean):SourceDecision?=error("unrelated")
}
