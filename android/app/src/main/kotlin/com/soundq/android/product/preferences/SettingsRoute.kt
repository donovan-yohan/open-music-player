package com.soundq.android.product.preferences

import com.soundq.android.data.AuthState
import com.soundq.android.data.preferences.*

/** One typed route family. Back pops exactly one entry; an empty stack means Settings is closed. */
internal enum class SettingsRoute(val title:String) {
    Root("Settings"), Account("Account"), SignIn("Sign in"), CreateAccount("Create account"),
    LocalAudio("Local audio"), Storage("Storage"), StorageDetails("Storage details"),
    Theme("Theme"), EndOfQueue("End of queue"), SwipeToQueue("Swipe to queue"), Crossfade("Crossfade"), KeyNotation("Key notation"),
    MusicTools("Music tools"), About("About"), Notices("Open-source notices");
    companion object {
        /** Saveable form is route names; unknown names (older builds) are dropped rather than guessed. */
        fun decode(names:List<String>):List<SettingsRoute> = names.mapNotNull {name->entries.firstOrNull {it.name==name}}
    }
}
internal fun List<SettingsRoute>.encode():List<String> = map {it.name}
internal fun List<SettingsRoute>.push(route:SettingsRoute):List<SettingsRoute> = this+route
internal fun List<SettingsRoute>.pop():List<SettingsRoute> = dropLast(1)
/** Auth form routes retire once the session they were collecting exists. */
internal fun List<SettingsRoute>.settled(auth:AuthState):List<SettingsRoute> =
    if(auth is AuthState.SignedIn||auth is AuthState.DeviceOnly) filterNot {it==SettingsRoute.SignIn||it==SettingsRoute.CreateAccount} else this
/** Opening Account for an action that needs a session goes straight to the form when one is required. */
internal fun accountEntry(auth:AuthState):List<SettingsRoute> =
    if(auth is AuthState.SignedOut) listOf(SettingsRoute.Account,SettingsRoute.SignIn) else listOf(SettingsRoute.Account)

/** Existing remote destinations relocated from the old Account hub, in their original order. */
internal enum class MusicTool(val label:String) {
    Catalog("Catalog"), Mixes("Mixes"), ConnectedDevices("Connected devices"), Jam("Jam"), Imports("Imports"), ServerImports("Server import jobs and research")
}

internal fun accountStatus(auth:AuthState):String = when(auth) {
    is AuthState.SignedIn->"Signed in"
    is AuthState.DeviceOnly->"Offline"
    else->"Signed out"
}
internal fun crossfadeLabel(seconds:Int):String = when(seconds) {0->"Off";1->"1 second";else->"$seconds seconds"}
internal val crossfadeChoices:List<Int> = (0..12).toList()
internal fun endOfQueueLabel(mode:EndOfQueue):String = if(mode==EndOfQueue.Off)"Off" else "Shuffle library"
internal fun swipeQueueLabel(mode:SwipeQueue):String = if(mode==SwipeQueue.PlayNext)"Play next" else "Add to queue"
internal fun keyNotationLabel(choice:KeyNotation):String = if(choice==KeyNotation.Camelot)"Camelot" else "Musical key"
internal fun appearanceLabel(choice:Appearance):String = choice.name
/** Summary values are accepted state only; an unready owner shows a placeholder, not its default. */
internal fun summary(ready:Boolean,value:String):String = if(ready)value else "Loading…"
internal fun songCount(count:Int):String = if(count==1)"1 song" else "$count songs"
