package com.soundq.android.data.preferences

/** Flutter SettingsModel defaults, frozen seam for future engine consumers. No keep-queued duplicate. */
data class ListeningPreferences(
    val crossfadeSeconds:Int=0,
    val endOfQueue:EndOfQueue=EndOfQueue.ShuffleLibrary,
    val swipeQueue:SwipeQueue=SwipeQueue.AddToQueue,
    val keyNotation:KeyNotation=KeyNotation.Camelot,
    val djMode:Boolean=true,
    val appearance:Appearance=Appearance.System,
) {
    init {require(crossfadeSeconds in 0..12)}
}
enum class EndOfQueue { Off, ShuffleLibrary }
enum class SwipeQueue { AddToQueue, PlayNext }
enum class KeyNotation(val wire:String) {
    Camelot("camelot"), Musical("musical");
    companion object {fun fromWire(value:String):KeyNotation?=entries.firstOrNull {it.wire==value}}
}
/** Stable device-local wire values, independent of enum ordinals and OS brightness. */
enum class Appearance(val wire:String) {
    System("system"), Light("light"), Dark("dark");
    companion object { fun fromWire(value:String):Appearance?=entries.firstOrNull {it.wire==value} }
}
