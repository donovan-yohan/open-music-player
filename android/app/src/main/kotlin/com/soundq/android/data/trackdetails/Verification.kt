package com.soundq.android.data.trackdetails

data class MatchSuggestion(val recording:RecordingMbid,val title:String,val artist:String,val release:RecordingMbid?=null,val artistMbid:RecordingMbid?=null,val confidence:Double?=null,val album:String?=null,val durationMs:Long?=null)
sealed interface VerificationAction {
    data object Rematch:VerificationAction
    data class Confirm(val suggestion:MatchSuggestion):VerificationAction
    data class Link(val recording:RecordingMbid,val updateMetadata:Boolean=false):VerificationAction
}
