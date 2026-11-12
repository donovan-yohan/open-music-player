package com.soundq.android.product

import com.soundq.android.data.*
import com.soundq.android.data.deviceaudio.*
import com.soundq.android.playback.PlaybackRef
import java.util.Locale

/** A presentation of existing acknowledged owners, not a second Library/queue repository. */
internal data class UnifiedLibraryRow(val ref:PlaybackRef,val title:String,val artist:String,val album:String,val durationMs:Long,val local:Boolean,val phone:DeviceAudio?=null,val server:Track?=null) {
    val key:HistoryKey get()=when(val r=ref){is PlaybackRef.Device->HistoryKey.Device(DeviceFileId(java.util.UUID.fromString(r.id)));is PlaybackRef.Server->HistoryKey.Server(ServerAccount(r.endpoint,r.account),ServerAudioId(r.id))}
    val stable:String get()=stableSourceIdentity(key)
}
/** Present on the phone but SoundQ could not read or decode it (e.g. protected audio). Not an access loss. */
internal val DeviceAudio.unplayable:Boolean get()=!available&&aliases.any {it.state==AccessState.UNSUPPORTED||it.state==AccessState.UNREADABLE}
internal fun phoneRowUnavailableLabel(row:DeviceAudio,grants:List<ScanGrant>):String {
    if(row.unplayable)return "Can’t play this file"
    val indexed=grants.filter {it.kind==GrantKind.INDEXED}.map {it.id}.toSet()
    if(row.aliases.isNotEmpty()&&row.aliases.all {it.state==AccessState.REVOKED&&it.grantId in indexed})return "Unavailable · File access is off"
    return "Unavailable · Choose file again"
}
internal fun unifiedLibraryRows(endpoint:String,account:String?,server:List<Track>,downloads:List<Track>,phone:DeviceListeningSnapshot?,query:LibraryQuery,localOnly:Boolean,recent:Boolean):List<UnifiedLibraryRow> {
    fun matches(title:String,artist:String,album:String,filename:String="")=query.text.trim().let {it.isEmpty()||listOf(title,artist,album,filename).any {field->field.contains(it,true)}}
    val downloaded=downloads.associateBy {it.id}
    val acknowledged=server.associateBy {it.id}
    val remote=if(account==null)emptyList() else (server+downloads.filter {it.id !in acknowledged}).distinctBy {it.id}.filter {
        (it.id in acknowledged||matches(it.title,it.artist,it.album))&&(!query.liked||it.liked==true)&&query.collection?.contains(it)!=false&&((query.genre.isBlank()&&query.verified==null)||it.id in acknowledged)
    }.map {track->UnifiedLibraryRow(PlaybackRef.Server(endpoint,account,track.id.value),track.title,track.artist,track.album,track.durationMs,track.id in downloaded,server=track)}
    val device=if(query.liked||query.verified!=null||query.genre.isNotBlank())emptyList() else phone?.files.orEmpty().filter {
        matches(it.metadata.displayTitle,it.metadata.artist.orEmpty(),it.metadata.album.orEmpty(),it.metadata.filename)&&query.collection?.let {c->(c.artist==null||c.artist==it.metadata.artist)&&(c.album==null||c.album==it.metadata.album)}!=false
    }.map {row->UnifiedLibraryRow(PlaybackRef.Device(row.id.value.toString(),row.revision.sha256,row.revision.byteLength,row.incarnation),row.metadata.displayTitle,row.metadata.artist.orEmpty(),row.metadata.album.orEmpty(),row.durationMs ?: 0,row.available||row.unplayable,phone=row)}
    val rows=(remote+device).filter {!localOnly||it.local}
    val times=phone?.history.orEmpty().associate {it.key to it.playedAtEpochMs}
    val tie=compareBy<UnifiedLibraryRow> {it.title.lowercase(Locale.ROOT)}.thenBy {it.stable}
    if(recent)return rows.sortedWith(compareByDescending<UnifiedLibraryRow> {times[it.key] ?: Long.MIN_VALUE}.then(tie))
    // Added order has no cross-source timestamp contract: retain acknowledged server order,
    // then stable phone discovery identity. Other sorts are global only on complete coverage.
    if(query.sort==LibrarySort.Added)return remote.filter {!localOnly||it.local}+device.filter {!localOnly||it.local}.sortedWith(tie)
    val order=when(query.sort){LibrarySort.Title->compareBy<UnifiedLibraryRow>{it.title.lowercase(Locale.ROOT)};LibrarySort.Artist->compareBy{it.artist.lowercase(Locale.ROOT)};LibrarySort.Duration->compareBy{it.durationMs};LibrarySort.Added->tie}
    return rows.sortedWith((if(query.ascending)order else order.reversed()).then(tie))
}
