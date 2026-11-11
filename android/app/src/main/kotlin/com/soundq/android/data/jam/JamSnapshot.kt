package com.soundq.android.data.jam

import com.soundq.android.data.TrackId
import com.soundq.android.data.connect.*
import kotlinx.serialization.json.*
import java.net.URI
import java.time.Instant

private const val noCatalog = "00000000-0000-0000-0000-000000000000"
private fun flag(j:JsonObject,key:String)=j.getValue(key).jsonPrimitive.let {require(!it.isString);it.boolean}
private fun optionalText(j:JsonObject,key:String,max:Int)=if(key in j)text(j,key,max) else null

/** Safe guest projection. It carries no source URL, owner mapping or audio grant. */
data class JamSourceChoice(val selectionSessionId:String,val candidateId:String,val provider:String,val sourceId:String,val title:String,val artist:String,val durationMs:Long,val expires:Instant) {
    companion object {fun parse(j:JsonObject):JamSourceChoice {
        keys(j,setOf("selectionSessionId","candidateId","provider","sourceId","title","artist","durationMs","expiresAt"))
        return JamSourceChoice(uuid(text(j,"selectionSessionId",36)),text(j,"candidateId",256).also {require(it.isNotEmpty())},text(j,"provider",16).also {require(it in setOf("youtube","soundcloud"))},text(j,"sourceId",128).also {require(it.isNotEmpty())},text(j,"title",200).also {require(it.isNotEmpty())},text(j,"artist",200),number(j,"durationMs",max=86400000),date(j,"expiresAt"))
    }}
}
/** Host-only exact captured source, never passed into guest presentation. */
data class JamSelectedSource(val sourceUrl:String) {
    companion object {fun parse(j:JsonObject,source:JamSourceChoice):JamSelectedSource {
        keys(j,setOf("candidateId","provider","sourceId","sourceUrl","title","playable","downloadable"),setOf("explicit","artist","durationMs"))
        require(text(j,"candidateId",256)==source.candidateId&&text(j,"provider",16)==source.provider&&text(j,"sourceId",128)==source.sourceId)
        require(text(j,"title",200)==source.title&&(optionalText(j,"artist",200) ?: "")==source.artist&&(if("durationMs" in j)number(j,"durationMs",max=86400000)else 0L)==source.durationMs)
        flag(j,"playable");require(flag(j,"downloadable"))
        j["explicit"]?.takeUnless {it is JsonNull}?.jsonPrimitive?.let {require(!it.isString);it.boolean}
        val raw=text(j,"sourceUrl",2048);val uri=URI(raw)
        require(uri.scheme=="https"&&uri.rawUserInfo==null)
        require(uri.host in if(source.provider=="youtube")setOf("youtube.com","www.youtube.com","music.youtube.com","youtu.be")else setOf("soundcloud.com","www.soundcloud.com"))
        return JamSelectedSource(raw)
    }}
}
data class JamMember(val id:String,val name:String,val expires:Instant,val revoked:Boolean)
data class JamAuthority(val ownerId:String,val authGeneration:Long,val deviceId:String,val leaseId:String)
data class JamRequest(val id:String,val catalogId:String,val name:String,val status:String,val trackId:TrackId?,val receipt:AdmissionReceipt?,val source:JamSourceChoice?=null,val memberId:String?=null,val selectedSource:JamSelectedSource?=null,val approvalOrder:Long=0,val admissionKey:String?=null,val hostSessionId:String?=null,val canAdmit:Boolean=false,val downloadJobId:String?=null) {
    internal fun publicProjection()=copy(trackId=null,receipt=null,memberId=null,selectedSource=null,approvalOrder=0,admissionKey=null,hostSessionId=null,canAdmit=false,downloadJobId=null)
}
data class JamCatalogItem(val id:String,val title:String,val artist:String,val durationMs:Long=0)
data class JamSnapshot(val id:String,val version:Long,val state:String,val serverTime:Instant,val expires:Instant,val catalog:List<JamCatalogItem>,val requests:List<JamRequest>,val host:Boolean,val outsideDiscovery:Boolean=false,val authority:JamAuthority?=null,val members:List<JamMember> = emptyList()) {
    companion object {fun parse(j:JsonObject,host:Boolean,id:String):JamSnapshot=decode {
        val authorityKeys=setOf("ownerUserId","ownerAuthGeneration","hostDeviceId","leaseId")
        keys(j,setOf("jamId","version","state","serverTime","expiresAt","hostSeenAt","nowPlaying","catalog","requests")+if(host)setOf("hostRequests","memberCount")else emptySet(),setOf("allowOutsideDiscovery")+if(host)authorityKeys+setOf("members")else emptySet())
        require(uuid(text(j,"jamId",36))==id)
        val authority=if(host&&authorityKeys.any {it in j}) {
            require(j.keys.containsAll(authorityKeys+setOf("members","allowOutsideDiscovery")))
            JamAuthority(uuid(text(j,"ownerUserId",36)),number(j,"ownerAuthGeneration"),uuid(text(j,"hostDeviceId",36)),uuid(text(j,"leaseId",36)))
        }else null
        val state=text(j,"state",16);require(state in setOf("open","hostOffline","closed","expired"));date(j,"hostSeenAt")
        val catalog=j.getValue("catalog").jsonArray.also {require(it.size in 1..20)}.map {e->val c=e.jsonObject;keys(c,setOf("catalogItemId","title","artist","durationMs"));JamCatalogItem(uuid(text(c,"catalogItemId",36)),text(c,"title",200),text(c,"artist",200),number(c,"durationMs",max=86400000))}
        require(catalog.map {it.id}.distinct().size==catalog.size)
        val members=j["members"]?.jsonArray?.also {require(host&&it.size<=64)}?.map {e->val m=e.jsonObject;keys(m,setOf("memberId","displayName","expiresAt","revoked"));JamMember(uuid(text(m,"memberId",36)),text(m,"displayName",32),date(m,"expiresAt"),flag(m,"revoked"))} ?: emptyList()
        require(members.map {it.id}.distinct().size==members.size)
        fun request(e:JsonElement,private:Boolean):JamRequest {
            val r=e.jsonObject
            val privateFields=setOf("receipt","memberId","selectedSource","approvalOrder","admissionKey","hostSessionId","canAdmit","downloadJobId")
            keys(r,setOf("requestId","catalogItemId","displayName","status")+if(private)setOf("trackId")else emptySet(),setOf("source")+if(private)privateFields else emptySet())
            if(private&&authority!=null)require(r.keys.containsAll(setOf("memberId","approvalOrder","canAdmit","downloadJobId")))
            val rid=uuid(text(r,"requestId",36));val status=text(r,"status",16)
            require(status in setOf("pending","approved","importing","ready","queued","declined","uncertain","withdrawn","failed","duplicate"))
            val source=r["source"]?.jsonObject?.let(JamSourceChoice::parse)
            val catalogId=text(r,"catalogItemId",36)
            if(source==null)require(catalog.any {it.id==uuid(catalogId)})else require(catalogId==noCatalog)
            val receipt=r["receipt"]?.takeUnless {it is JsonNull}?.jsonObject?.let {a->keys(a,setOf("requestId","sessionId","occurrenceId"));require(uuid(text(a,"requestId",36))==rid&&status=="queued");AdmissionReceipt(rid,text(a,"sessionId",128).also {require(it.isNotBlank())},text(a,"occurrenceId",128).also {require(it.isNotBlank())})}
            val track=if(private)number(r,"trackId").let {if(it==0L){require(source!=null&&status !in setOf("ready","queued"));null}else TrackId(it)}else null
            if(private)require((status=="queued")== (receipt!=null))
            val member=optionalText(r,"memberId",36)?.let(::uuid)
            if(member!=null)require(members.any {it.id==member})
            val selected=r["selectedSource"]?.jsonObject?.let {JamSelectedSource.parse(it,source ?: error("source required"))}
            if(private&&source!=null)require(selected!=null)
            val order=if("approvalOrder" in r)number(r,"approvalOrder",max=50)else 0L
            val key=optionalText(r,"admissionKey",64)?.also {require(Regex("[0-9a-f]{64}").matches(it))}
            val session=optionalText(r,"hostSessionId",128)?.also {require(it.isNotBlank())}
            val canAdmit=if("canAdmit" in r)flag(r,"canAdmit")else false
            val job=optionalText(r,"downloadJobId",36)?.let {if(it==noCatalog)null else uuid(it)}
            if(canAdmit)require(private&&status=="ready"&&track!=null&&key!=null&&session!=null&&order>0)
            if(receipt!=null&&session!=null)require(receipt.sessionId==session)
            return JamRequest(rid,catalogId,text(r,"displayName",32),status,track,receipt,source,member,selected,order,key,session,canAdmit,job)
        }
        val public=j.getValue("requests").jsonArray.also {require(it.size<=50)}.map {request(it,false)}
        require(public.map {it.id}.distinct().size==public.size)
        val requests=if(host)j.getValue("hostRequests").jsonArray.also {require(it.size==public.size)}.map {request(it,true)}else public
        if(host){number(j,"memberCount",max=16);require(requests.map {it.publicProjection()}.toSet()==public.toSet())}
        JamSnapshot(id,number(j,"version",min=1),state,date(j,"serverTime"),date(j,"expiresAt"),catalog,requests,host,if("allowOutsideDiscovery" in j)flag(j,"allowOutsideDiscovery")else false,authority,members)
    }}
}
