package com.soundq.android.data.timeline

import com.soundq.android.data.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Semaphore

/** Account-scoped feature owner and bounded lazy analysis admission. No transport clock. */
class TimelineRepository(private val session:AccountSession,private val directory:File,private val fetch:(AccountScope,TrackId,Long,()->Boolean)->TrackWaveform) {
    private val mutable=MutableStateFlow(TimelineState())
    val state:StateFlow<TimelineState> = mutable
    private var scope:AccountScope?=null
    private var owner:TimelineOwner?=null
    private val cache=WaveformCache()
    // The record is also the fetch lease: absence/duration ABA must not revive old work.
    // Identity metadata survives peak LRU eviction; eviction must not revive a stale manual link.
    private class SourceQualification(val durationMs:Long) {
        var sourceKey:String?=null
        var timing:PhaseGrid?=null
        var tempoTiming:TempoSourceTiming?=null
        var analysisTempo:TempoSourceTiming?=null
        val localTempos=mutableSetOf<TempoSourceTiming>()
        var revision=0L
    }
    private val qualifications=mutableMapOf<Long,SourceQualification>()
    private val permits=Semaphore(3)
    @Synchronized fun observe(captured:AccountScope,sources:List<TimelineSource>) {
        if(!session.current(captured))return
        if(scope?.let {session.current(it)&&it.accountId==captured.accountId}!=true) {
            retire();scope=captured
            val hash=MessageDigest.getInstance("SHA-256").digest((session.endpoint.identity+"\u0000"+captured.accountId).toByteArray()).joinToString(""){"%02x".format(it)}
            val file=File(directory,"arrangement-$hash.v1.json")
            owner=TimelineOwner({
                if(!file.exists())null else {require(file.length()<=2_000_000);file.readText()}
            },{raw ->
                check(session.current(captured));directory.mkdirs()
                val staging=File(directory,".${file.name}.pending")
                try {java.io.FileOutputStream(staging).use {out ->out.write(raw.toByteArray());out.fd.sync()};check(session.current(captured));java.nio.file.Files.move(staging.toPath(),file.toPath(),java.nio.file.StandardCopyOption.ATOMIC_MOVE,java.nio.file.StandardCopyOption.REPLACE_EXISTING)}
                finally {staging.delete()}
            })
        }
        owner?.observe(sources)
        if(owner!!.state.value.context!=TimelineContext.Supported) {
            // Retire analysis/authoring leases even when the old and new queues
            // share tracks. Recovery creates fresh qualification incarnations.
            audition=null;qualifications.clear();cache.clear()
            mutable.value=owner!!.state.value
            return
        }
        // One track ID with conflicting durations has no source authority until resolved.
        val durations=sources.groupBy {it.track}.mapNotNull {(track,items)->
            items.map {it.durationMs}.distinct().singleOrNull()?.let {track to it}
        }.toMap()
        qualifications.keys.retainAll(durations.keys)
        durations.forEach {(track,duration)->
            if(qualifications[track]?.durationMs!=duration)qualifications[track]=SourceQualification(duration)
        }
        mutable.value=owner!!.state.value
    }
    private fun autoEdit(edit:TimelineEdit):TimelineTempoEdit {
        val d=mutable.value.document
        require(d.revision==edit.revision&&d.clips.any {it===edit.original}) {"Arrangement changed. Try again."}
        require(edit.authoredFadeTrimReason()==null) {edit.authoredFadeTrimReason().orEmpty()}
        val clips=d.clips.map {if(it===edit.original)edit.candidate().copy(tempoMap=null) else it}
        val ids=d.clips.mapNotNull(::tempoSource)
        return TimelineTempoEdit(d,d.copy(clips=clips).withAutoBpmCrossfade(true,ids))
    }
    @Synchronized fun preview(edit:TimelineEdit):EditDecision {
        if(scope?.let(session::current)!=true||!gridReady(mutable.value.document))return EditDecision(false,"Session or captured timing changed. Refresh the current source.")
        if(mutable.value.document.autoBpmCrossfade)return try {preview(autoEdit(edit))}catch(e:Exception){EditDecision(false,e.message)}
        return owner?.preview(edit) ?: EditDecision(false)
    }
    /** Read-only whole candidate for the captured workspace, including Auto BPM and linked partners. */
    @Synchronized fun previewDocument(document:TimelineDocument,edit:TimelineEdit,valid:()->Boolean):TimelineDocument? {
        if(!valid()||mutable.value.document!==document||document.clips.none {it===edit.original}||!preview(edit).accepted)return null
        val candidate=runCatching {if(document.autoBpmCrossfade)autoEdit(edit).candidate else document.edited(edit)}.getOrNull()
        return candidate?.takeIf {valid()&&mutable.value.document===document&&scope?.let(session::current)==true}
    }
    @Synchronized fun commit(edit:TimelineEdit,valid:()->Boolean):Boolean {
        val s=scope ?: return false;val o=owner ?: return false
        if(!valid()||!session.current(s)||!gridReady(mutable.value.document))return false
        if(mutable.value.document.autoBpmCrossfade) {
            val candidate=runCatching {autoEdit(edit)}.getOrNull() ?: return false
            return commit(candidate,valid)
        }
        val accepted=o.commit(edit){session.current(s)&&valid()};mutable.value=o.state.value;return accepted
    }
    @Synchronized fun preview(edit:TimelineFadeEdit):EditDecision = if(scope?.let(session::current)==true)owner?.preview(edit) ?: EditDecision(false) else EditDecision(false,"Session changed.")
    @Synchronized fun commit(edit:TimelineFadeEdit,valid:()->Boolean):Boolean {
        val s=scope ?: return false;val o=owner ?: return false
        if(!valid()||!session.current(s)||!gridReady(mutable.value.document))return false
        val accepted=o.commit(edit){session.current(s)&&valid()};mutable.value=o.state.value;return accepted
    }
    private fun currentGrid(clip:TimelineClip,grid:PhaseGrid):Boolean {
        val source=qualifications[clip.track]?.takeIf {it.durationMs==clip.sourceDurationMs} ?: return false
        if(grid.provenance=="manual_timing_v2" && source.timing?.let {it.copy(groupOriginMs=grid.groupOriginMs)==grid}!=true)return false
        return source.sourceKey?.let {it==grid.sourceKey}
            ?: (grid.provenance=="local_manual" && grid.sourceKey=="manual:${clip.track}:${clip.sourceDurationMs}")
    }
    /** Read-only live timing capability. The returned predicate captures the exact qualification incarnation. */
    @Synchronized fun qualifyLiveGrid(captured:AccountScope,track:Long,durationMs:Long,sourceKey:String,revision:String,bpm:Double,anchorMs:Double,groupOriginMs:Double?,provenance:String): (()->Boolean)? {
        val source=qualifications[track]?.takeIf {it.durationMs==durationMs} ?: return null
        val version=source.revision
        fun valid():Boolean = synchronized(this) {
            if(!session.current(captured) || scope?.let {session.current(it)&&it.epoch==captured.epoch&&it.accountId==captured.accountId}!=true ||
                qualifications[track]!==source || source.revision!=version || source.sourceKey!=sourceKey || sourceKey.isBlank() ||
                revision.isBlank() || revision.length>512 || !bpm.isFinite() || bpm !in 10.0..600.0 || !anchorMs.isFinite() || anchorMs !in 0.0..durationMs.toDouble())return@synchronized false
            if(groupOriginMs!=null) {
                if(!groupOriginMs.isFinite() || groupOriginMs !in 0.0..durationMs.toDouble())return@synchronized false
                val ordinal=(groupOriginMs-anchorMs)*bpm/60000.0
                if(kotlin.math.abs(ordinal-kotlin.math.round(ordinal))>1e-7)return@synchronized false
            }
            when(provenance) {
                "local_manual"->true
                "manual_timing_v2"->source.timing?.let {it.sourceKey==sourceKey&&it.revision==revision&&it.anchorMs.toDouble()==anchorMs&&kotlin.math.abs(60000.0/it.periodMs-bpm)<=1e-9}==true
                else->false
            }
        }
        return if(valid())::valid else null
    }
    @Synchronized fun preview(edit:PhaseEdit):EditDecision {
        if(scope?.let(session::current)!=true)return EditDecision(false,"Session changed.")
        if(!currentGrid(edit.reference,edit.referenceGrid)||!currentGrid(edit.incoming,edit.incomingGrid))return EditDecision(false,"Analysis source changed. Qualify the current grid again.")
        return owner?.preview(edit) ?: EditDecision(false)
    }
    @Synchronized fun commit(edit:PhaseEdit,valid:()->Boolean):Boolean {
        val s=scope ?: return false;val o=owner ?: return false
        if(!valid()||!preview(edit).accepted)return false
        val accepted=o.commit(edit){session.current(s)&&valid()&&currentGrid(edit.reference,edit.referenceGrid)&&currentGrid(edit.incoming,edit.incomingGrid)}
        mutable.value=o.state.value;return accepted
    }
    @Synchronized fun unlock(revision:Long,valid:()->Boolean):Boolean {
        val s=scope ?: return false;val o=owner ?: return false
        val accepted=o.unlock(revision){session.current(s)&&valid()};mutable.value=o.state.value;return accepted
    }
    /** Exact live grid incarnation. Returning a predicate does not grant route authority. */
    @Synchronized fun qualifyTempo(captured:AccountScope,identity:TempoSourceIdentity): (()->Boolean)? {
        if(!identity.supportsTempoOnly())return null
        val source=qualifications[identity.track]?.takeIf {it.durationMs==identity.durationMs} ?: return null
        val version=source.revision
        val expected=TempoSourceTiming(identity.sourceKey,identity.gridRevision,identity.gridProvenance,identity.sourceBpm,identity.beatAnchorMs,identity.gridLaw,identity.beatAnchorKnown)
        fun current():Boolean = synchronized(this) {
            session.current(captured)&&scope?.epoch==captured.epoch&&qualifications[identity.track]===source&&source.revision==version&&source.sourceKey==identity.sourceKey&&
                mutable.value.document.clips.any {it.occurrence==identity.occurrence&&it.track==identity.track&&it.sourceDurationMs==identity.durationMs}&&
                when(identity.gridProvenance) {
                    "analysis_bpm"->source.analysisTempo==expected
                    "manual_timing_v2"->source.tempoTiming==expected||source.timing?.let {identity.beatAnchorKnown&&it.sourceKey==identity.sourceKey&&it.revision==identity.gridRevision&&it.provenance==identity.gridProvenance&&it.anchorMs.toDouble()==identity.beatAnchorMs&&kotlin.math.abs(60000.0/it.periodMs-identity.sourceBpm)<1e-9}==true
                    "local_manual","local_bpm"->expected in source.localTempos||tempoIdentities(mutable.value.document).any {it==identity}
                    else->false
                }
        }
        return if(current())::current else null
    }
    /** A captured measured-source lease survives unchanged reads, never source/duration/account ABA. */
    @Synchronized fun captureWaveformSource(captured:AccountScope,clip:TimelineClip,wave:TrackWaveform):()->Boolean {
        val source=qualifications[clip.track]?.takeIf {it.durationMs==clip.sourceDurationMs&&it.sourceKey==wave.sourceKey&&wave.track.value==clip.track&&wave.durationMs==clip.sourceDurationMs} ?: return {false}
        val version=source.revision
        return {synchronized(this){session.current(captured)&&scope?.epoch==captured.epoch&&qualifications[clip.track]===source&&source.revision==version&&source.sourceKey==wave.sourceKey}}
    }
    /** Explicit local confirmation. No server write, no synthesized beat anchor. */
    @Synchronized fun authorTempoSource(captured:AccountScope,document:TimelineDocument,clip:TimelineClip,wave:TrackWaveform,bpm:Double,anchorMs:Double,valid:()->Boolean):TempoSourceIdentity? {
        return authorLocalTempo(captured,document,clip,wave,bpm,anchorMs,valid)
    }
    /** Explicit BPM-only confirmation cannot create phase authority. */
    @Synchronized fun authorTempoBpm(captured:AccountScope,document:TimelineDocument,clip:TimelineClip,wave:TrackWaveform,bpm:Double,valid:()->Boolean):TempoSourceIdentity? {
        return authorLocalTempo(captured,document,clip,wave,bpm,null,valid)
    }
    private fun authorLocalTempo(captured:AccountScope,document:TimelineDocument,clip:TimelineClip,wave:TrackWaveform,bpm:Double,anchorMs:Double?,valid:()->Boolean):TempoSourceIdentity? {
        if(!valid()||!session.current(captured)||scope?.epoch!=captured.epoch||mutable.value.document!==document||document.clips.none {it===clip}||wave.track.value!=clip.track||wave.durationMs!=clip.sourceDurationMs)return null
        val source=qualifications[clip.track]?.takeIf {it.durationMs==wave.durationMs&&it.sourceKey==wave.sourceKey} ?: return null
        val timing=runCatching {TempoSourceTiming(wave.sourceKey,"local:${java.util.UUID.randomUUID()}",if(anchorMs==null)"local_bpm" else "local_manual",bpm,anchorMs ?: 0.0,beatAnchorKnown=anchorMs!=null)}.getOrNull() ?: return null
        if(timing.beatAnchorMs>wave.durationMs)return null
        if(source.localTempos.size>=16)source.localTempos.remove(source.localTempos.first())
        source.localTempos.add(timing)
        return timing.identity(clip)
    }
    @Synchronized fun tempoSource(clip:TimelineClip):TempoSourceIdentity? {
        val source=qualifications[clip.track]?.takeIf {it.durationMs==clip.sourceDurationMs} ?: return null
        val durable=tempoIdentities(mutable.value.document).firstOrNull {it.occurrence==clip.occurrence&&qualifyTempo(scope ?: return null,it)?.invoke()==true}
        return durable ?: source.tempoTiming?.identity(clip) ?: source.timing?.let {TempoSourceTiming(it.sourceKey,it.revision,it.provenance,60000.0/it.periodMs,it.anchorMs.toDouble()).identity(clip)} ?: source.analysisTempo?.identity(clip)
    }
    private fun tempoIdentities(document:TimelineDocument)=document.tempoRamps.flatMap {listOf(it.outgoing,it.incoming)}+document.playbackTempos.map {it.source}
    @Synchronized fun captureTempoSources(identities:List<TempoSourceIdentity>):()->Boolean {
        val s=scope ?: return {false}
        val captures=identities.map {qualifyTempo(s,it) ?: return {false}}
        return {synchronized(this){session.current(s)&&captures.all {it()}}}
    }
    @Synchronized fun preview(edit:TimelineTempoEdit):EditDecision {
        if(scope?.let(session::current)!=true)return EditDecision(false,"Session changed.")
        if(!tempoReady(edit.candidate))return EditDecision(false,"Source timing changed. Refresh the original sources before saving.")
        return owner?.preview(edit) ?: EditDecision(false,"Arrangement unavailable.")
    }
    @Synchronized fun commit(edit:TimelineTempoEdit,valid:()->Boolean):Boolean = commitTempo(edit,valid,false)
    @Synchronized fun commitContinuingTempo(edit:TimelineTempoEdit,valid:()->Boolean):Boolean = commitTempo(edit,valid,true)
    private fun commitTempo(edit:TimelineTempoEdit,valid:()->Boolean,continuingPlayback:Boolean):Boolean {
        val s=scope ?: return false;val o=owner ?: return false
        if(!valid()||!preview(edit).accepted)return false
        val captures=tempoIdentities(edit.candidate).map {qualifyTempo(s,it) ?: return false}
        val admitted={session.current(s)&&valid()&&captures.all {it()}}
        val accepted=if(continuingPlayback)o.commitContinuingTempo(edit,admitted) else o.commit(edit,admitted)
        mutable.value=o.state.value;return accepted
    }
    private fun tempoReady(document:TimelineDocument):Boolean {
        val s=scope ?: return false
        return validateTempoDocument(document)==null && tempoIdentities(document).all {qualifyTempo(s,it)?.invoke()==true}
    }
    private fun gridReady(document:TimelineDocument):Boolean {
        if(!tempoReady(document))return false
        val link=document.phaseLink ?: return true
        return validatePhase(document)==null && listOf(link.reference to link.referenceGrid,link.incoming to link.incomingGrid).all {(id,g)->
            document.clips.singleOrNull {it.occurrence==id}?.let {currentGrid(it,g)}==true
        }
    }
    @Synchronized fun undo(valid:()->Boolean):Boolean {
        val s=scope ?: return false;val o=owner ?: return false
        val accepted=o.undo {session.current(s)&&valid()};mutable.value=o.state.value;return accepted
    }
    private fun owns(captured:AccountScope):Boolean = session.remoteCurrent(captured) && scope?.let {session.current(it)&&it.accountId==captured.accountId}==true
    fun waveform(captured:AccountScope,track:TrackId,duration:Long,refresh:Boolean=false,valid:()->Boolean):TrackWaveform? {
        val source=synchronized(this) {
            if(!owns(captured)||!valid())return null
            val current=qualifications[track.value]?.takeIf {it.durationMs==duration} ?: return null
            if(!refresh)cache.get(track)?.takeIf {it.durationMs==duration&&it.sourceKey==current.sourceKey}?.let {return it}
            current
        }
        fun current():Boolean = synchronized(this) {owns(captured)&&valid()&&qualifications[track.value]===source}
        permits.acquire()
        try {
            synchronized(this) {
                if(!current())return null
                if(!refresh)cache.get(track)?.takeIf {it.durationMs==duration&&it.sourceKey==source.sourceKey}?.let {return it}
            }
            val wave=fetch(captured,track,duration,::current)
            synchronized(this) {
                if(!current())return null
                require(wave.track==track&&wave.durationMs==duration)
                cache.put(wave)
                val analysisTempo=wave.analysisTempo()
                if(source.sourceKey!=wave.sourceKey || source.timing!=wave.phaseTiming || source.tempoTiming!=wave.tempoTiming || source.analysisTempo!=analysisTempo) {
                    source.revision++;source.localTempos.clear()
                }
                source.sourceKey=wave.sourceKey;source.timing=wave.phaseTiming;source.tempoTiming=wave.tempoTiming;source.analysisTempo=analysisTempo
                if(!gridReady(mutable.value.document))mutable.value=mutable.value.copy(message="Captured linked timing changed. Positions were not moved. Unlock and qualify the current sources before auditioning.")
                return wave
            }
        } finally {permits.release()}
    }
    fun window(wave:TrackWaveform,start:Long,end:Long,columns:Int)=cache.window(wave,start,end,columns)
    @Synchronized fun captureAudition(captured:AccountScope,document:TimelineDocument,valid:()->Boolean):String? {
        if(!accepts(captured,document)||!valid())return null
        val id=java.util.UUID.randomUUID().toString()
        audition=Audition(id,captured,document,valid)
        return id
    }
    @Synchronized fun installAudition(id:String,captured:AccountScope,document:TimelineDocument,install:()->Unit):Boolean {
        val held=audition ?: return false
        return synchronized(session) {
            if(held.installed || !admitsAudition(id,captured,document))return@synchronized false
            held.installed=true
            install()
            true
        }
    }
    private class Audition(val id:String,val scope:AccountScope,val document:TimelineDocument,val valid:()->Boolean) {var installed=false}
    private var audition:Audition?=null
    @Synchronized fun admitsAudition(id:String,captured:AccountScope,document:TimelineDocument):Boolean {
        val held=audition ?: return false
        return held.id==id && held.scope.epoch==captured.epoch && held.document==document && accepts(captured,document) && held.valid()
    }
    @Synchronized fun completeAudition(id:String,captured:AccountScope,document:TimelineDocument,play:()->Unit):Boolean = synchronized(session) {
        val held=audition ?: return@synchronized false
        if(!held.installed || !admitsAudition(id,captured,document))return@synchronized false
        audition=null;play();true
    }
    @Synchronized fun cancelAudition(){audition=null}
    @Synchronized fun retireAudition(id:String){if(audition?.id==id)audition=null}
    @Synchronized fun accepts(captured:AccountScope,document:TimelineDocument):Boolean =
        scope?.let {session.current(it)&&it.epoch==captured.epoch}==true && session.current(captured) &&
            mutable.value.writable && mutable.value.document==document && gridReady(document)
    @Synchronized fun retire() {scope=null;owner=null;audition=null;cache.clear();qualifications.clear();mutable.value=TimelineState()}
}
