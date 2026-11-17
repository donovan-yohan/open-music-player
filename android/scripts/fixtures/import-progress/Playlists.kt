package com.soundq.android.data.playlists
@JvmInline value class PlaylistId(val value:Long)
data class PlaylistSummary(val id:PlaylistId)
data class PlaylistPage(val rows:List<PlaylistSummary>,val total:Int)
