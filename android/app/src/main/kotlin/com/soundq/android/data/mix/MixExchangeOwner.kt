package com.soundq.android.data.mix

import com.soundq.android.data.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.*

/** Keep this owner in account-scoped ViewModel state, not remember(sheetOpen).
 * bind is an entry/selection event, never a redraw. close permanently retires that binding.
 * No process-death persistence, clipboard, queue, playback or acquisition authority lives here. */
enum class ExchangePhase { Editing, ImportPending, Checking, Refused, UnknownCreate, ReadbackFailed, Confirmed, ExportLoading, ExportReady, ExportFailed, Retired }
class ExchangeState internal constructor(
    val phase:ExchangePhase=ExchangePhase.Editing,
    val input:String="", val exportText:String?=null, val knownId:String?=null,
    val refusal:ExchangeRefusal.Code?=null, val priorUnconfirmed:Boolean=false,
) {
    val pending get()=phase in setOf(ExchangePhase.ImportPending,ExchangePhase.Checking,ExchangePhase.ExportLoading)
    val blocksOtherWrites get()=phase in setOf(ExchangePhase.ImportPending,ExchangePhase.Checking,ExchangePhase.UnknownCreate,ExchangePhase.ReadbackFailed)
    override fun toString()="ExchangeState($phase, pending=$pending, payloads=[redacted])"
}
class MixExchangeOwner(private val api:SoundQApi,private val account:AccountScope) {
    private val mutable=MutableStateFlow(ExchangeState())
    val state:StateFlow<ExchangeState> = mutable
    private var serial=0L
    private var retired=false
    private var bound:Binding?=null
    private var operation:Any?=null
    private var acknowledged:JsonObject?=null
    private var priorUnconfirmed=false
    private var input=""
    private var knownId:String?=null
    private fun accountCurrent()=!retired && api.session.remoteCurrent(account)
    private fun publish(phase:ExchangePhase,export:String?=null,refusal:ExchangeRefusal.Code?=null) {
        mutable.value=ExchangeState(phase,input,export,knownId,refusal,priorUnconfirmed)
    }
    private fun retireAccount() {
        retired=true;bound=null;serial++;operation=null;acknowledged=null;knownId=null;input="";priorUnconfirmed=false
        publish(ExchangePhase.Retired)
    }
    /** Account lifecycle consumer clears payloads immediately on retirement. */
    @Synchronized fun retire() {retireAccount()}
    @Synchronized fun snapshot():ExchangeState {
        if(!accountCurrent())retireAccount()
        return mutable.value
    }
    /** Caller must observe each selection transition, including same-ID/version ABA. */
    @Synchronized fun bind(saved:SavedMix?):Binding {
        retireBinding()
        if(!accountCurrent())retireAccount()
        val next=Binding(++serial,saved?.id,saved?.version)
        if(accountCurrent()) {
            bound=next
            if(mutable.value.phase !in setOf(ExchangePhase.UnknownCreate,ExchangePhase.ReadbackFailed)) {
                acknowledged=null;knownId=null
                publish(ExchangePhase.Editing)
            }
        }
        return next
    }
    private fun retireBinding() {
        bound=null;serial++
        if(mutable.value.phase in setOf(ExchangePhase.ImportPending,ExchangePhase.Checking))
            publish(if(knownId==null)ExchangePhase.UnknownCreate else ExchangePhase.ReadbackFailed)
        else if(mutable.value.phase in setOf(ExchangePhase.ExportReady,ExchangePhase.ExportLoading,ExchangePhase.ExportFailed))publish(ExchangePhase.Editing)
        operation=null
    }
    private fun current(b:Binding)=bound===b && b.serial==serial && accountCurrent()
    private fun owns(b:Binding,op:Any)=current(b)&&operation===op
    inner class Binding internal constructor(internal val serial:Long,val savedId:String?,val savedVersion:Long?) {
        fun snapshot():ExchangeState = synchronized(this@MixExchangeOwner) {
            if(!accountCurrent())retireAccount()
            if(current(this))mutable.value else ExchangeState(ExchangePhase.Retired)
        }
        fun edit(text:String):Boolean = synchronized(this@MixExchangeOwner) {
            if(!current(this)||mutable.value.phase !in setOf(ExchangePhase.Editing,ExchangePhase.Refused))false
            else {input=text;publish(ExchangePhase.Editing);true}
        }
        fun close()=synchronized(this@MixExchangeOwner) {if(current(this))retireBinding()}
        /** Explicit duplicate-risk confirmation is a new intent, never list-driven replay. */
        fun startAnotherImport(duplicateRiskConfirmed:Boolean):Boolean = synchronized(this@MixExchangeOwner) {
            if(!current(this)||!duplicateRiskConfirmed||mutable.value.phase !in setOf(ExchangePhase.UnknownCreate,ExchangePhase.ReadbackFailed))false
            else {priorUnconfirmed=true;acknowledged=null;knownId=null;publish(ExchangePhase.Editing);true}
        }
        /** Synchronous IO: consumer schedules off-main. Return is a one-shot accepted selection. */
        fun importMix():SavedMix? {
            val (op,submitted)=synchronized(this@MixExchangeOwner) {
                if(!current(this)||mutable.value.phase !in setOf(ExchangePhase.Editing,ExchangePhase.Refused))return null
                try {validateExchangeInput(input)} catch(_:IllegalArgumentException){publish(ExchangePhase.Refused);return null}
                Any().also {operation=it;acknowledged=null;knownId=null;publish(ExchangePhase.ImportPending)} to input
            }
            try {
                val response=api.mixExchange(account,rawImport=submitted){synchronized(this@MixExchangeOwner){owns(this,op)}}.body
                synchronized(this@MixExchangeOwner) {
                    if(!owns(this,op))return null
                    val id=response["id"]?.jsonPrimitive?.takeIf {it.isString}?.content
                    require(id!=null && java.util.UUID.fromString(id).toString()==id)
                    knownId=id;acknowledged=response;publish(ExchangePhase.Checking)
                }
                return readback(op)
            } catch(error:Exception) {
                synchronized(this@MixExchangeOwner) {
                    if(owns(this,op)) {
                        val refused=error is ExchangeRefusal || error is ExchangeAdmissionRefused
                        publish(if(knownId!=null)ExchangePhase.ReadbackFailed else if(refused)ExchangePhase.Refused else ExchangePhase.UnknownCreate,refusal=(error as? ExchangeRefusal)?.code)
                    }
                }
                return null
            } finally {finish(op)}
        }
        fun recoverSaved():SavedMix? {
            val op=synchronized(this@MixExchangeOwner) {
                if(!current(this)||mutable.value.phase!=ExchangePhase.ReadbackFailed||acknowledged==null||knownId==null)return null
                Any().also {operation=it;publish(ExchangePhase.Checking)}
            }
            return try {readback(op)} catch(_:Exception) {
                synchronized(this@MixExchangeOwner){if(owns(this,op))publish(ExchangePhase.ReadbackFailed)}
                null
            } finally {finish(op)}
        }
        private fun readback(op:Any):SavedMix? {
            val (id,ack)=synchronized(this@MixExchangeOwner) {
                if(!owns(this,op))return null
                knownId!! to acknowledged!!
            }
            val observed=api.mixExchangeReadback(account,id){synchronized(this@MixExchangeOwner){owns(this,op)}}
            // Compare complete untransformed authoring JSON before strict SavedMix parsing.
            require(observed==ack)
            val saved=MixJson.saved(observed);require(saved.id==id)
            return synchronized(this@MixExchangeOwner) {
                if(!owns(this,op))null else {publish(ExchangePhase.Confirmed);saved}
            }
        }
        fun loadExport():Boolean {
            val op=synchronized(this@MixExchangeOwner) {
                if(!current(this)||savedId==null||mutable.value.pending||mutable.value.blocksOtherWrites)return false
                Any().also {operation=it;publish(ExchangePhase.ExportLoading)}
            }
            return try {
                val reply=api.mixExchange(account,id=savedId){synchronized(this@MixExchangeOwner){owns(this,op)}}
                validatePortableExport(reply)
                synchronized(this@MixExchangeOwner) {
                    if(!owns(this,op))false else {publish(ExchangePhase.ExportReady,reply.text);true}
                }
            } catch(error:Exception) {
                synchronized(this@MixExchangeOwner){if(owns(this,op))publish(ExchangePhase.ExportFailed,refusal=(error as? ExchangeRefusal)?.code)}
                false
            } finally {finish(op)}
        }
        /** Executes only explicit current Copy. Never retain the payload/callback after close. */
        fun copyExport(copy:(String)->Unit):Boolean = synchronized(this@MixExchangeOwner) {
            val s=mutable.value
            if(!current(this)||s.phase!=ExchangePhase.ExportReady||s.exportText==null)false
            else try {copy(s.exportText);true}catch(_:Exception){false}
        }
        private fun finish(op:Any)=synchronized(this@MixExchangeOwner) {
            if(operation===op)operation=null
            if(!accountCurrent())retireAccount()
        }
    }
}

/** Validate the portable whitelist without rewriting the returned text or granting source access. */
private fun validatePortableExport(reply:ExchangeDocument) {
    validateExchangeInput(reply.text)
    val o=reply.body
    require(o.keys==setOf("format","version","name","clips"))
    require(o["format"]==JsonPrimitive("soundq-mix") && o["version"]==JsonPrimitive(1))
    val name=MixJson.text(o,"name")
    val clips=o.getValue("clips").jsonArray.map {v ->
        val c=v.jsonObject
        require(c.keys.all {it in setOf("clipId","queueItemId","sourceFileHash","sourceStartMs","sourceEndMs","timelineStartMs","gainDb","fadeInMs","fadeOutMs","pitchMode","tempoPolicy","stemEdits")})
        require(c.keys.containsAll(setOf("clipId","queueItemId","sourceFileHash","sourceStartMs","sourceEndMs","timelineStartMs","gainDb","pitchMode","tempoPolicy")))
        val hash=MixJson.text(c,"sourceFileHash");require(Regex("sha256:[0-9a-f]{64}").matches(hash))
        c["stemEdits"]?.let {require(it.jsonObject["sourceFileHash"]==JsonPrimitive(hash))}
        MixJson.clip(JsonObject((c-"sourceFileHash")+("trackId" to JsonPrimitive(1))))
    }
    require(clips.map {it.occurrence}.distinct().size==clips.size)
    MixJson.draft(name,clips)
}
