package com.soundq.android.data.catalog

private val mbid=Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
@JvmInline value class ArtistMbid(val value:String) {init {require(mbid.matches(value))}}
@JvmInline value class ReleaseGroupMbid(val value:String) {init {require(mbid.matches(value))}}
@JvmInline value class ReleaseMbid(val value:String) {init {require(mbid.matches(value))}}
@JvmInline value class RecordingMbid(val value:String) {init {require(mbid.matches(value))}}
data class CatalogResolutionCandidate(val trackId:Long,val mbVerified:Boolean,val inLibrary:Boolean)
data class CatalogResolution(val recording:RecordingMbid,val accountId:String,val status:String,val candidates:List<CatalogResolutionCandidate>,val truncated:Boolean)
/** A selection incarnation, not merely an MBID: repeated edition positions remain distinct. */
class CatalogSelection internal constructor(val album:CatalogAlbum,val row:CatalogRecording,val index:Int)
data class CatalogInspection(val selection:CatalogSelection,val loading:Boolean=true,val result:CatalogResolution?=null,val error:com.soundq.android.data.SafeFailure.Reason?=null,val unavailable:Boolean=false,val membership:String?=null)
data class CatalogAlbumRow(val localId:Long,val id:ReleaseMbid?,val title:String,val artist:String?,val trackCount:Int)
data class CatalogAlbums(val rows:List<CatalogAlbumRow>,val total:Int,val offset:Int,val limit:Int)
data class CatalogArtistRow(val id:ArtistMbid,val name:String,val description:String="")
data class CatalogSearch(val rows:List<CatalogArtistRow>,val total:Int,val offset:Int,val limit:Int)
data class CatalogReleaseGroup(val id:ReleaseGroupMbid,val title:String,val date:String?)
data class CatalogArtist(val row:CatalogArtistRow,val releases:List<CatalogReleaseGroup>)
data class CatalogRecording(val id:RecordingMbid,val title:String,val artist:String?,val durationMs:Long?,val position:Int?,val inLibrary:Boolean,val downloadable:Boolean)
data class CatalogAlbum(val id:ReleaseMbid,val title:String,val artist:String?,val date:String?,val trackCount:Int?,val tracks:List<CatalogRecording>)
