"""Execute the exact PhoneArtwork body with declared host hardware/Compose facades."""
from pathlib import Path

def generate(output: Path, source: Path):
    text=source.read_text()
    (output/'PhoneBinding.kt').write_text('''package com.soundq.android.product.artwork
import android.graphics.Bitmap
import com.soundq.android.AppGraph
import com.soundq.android.playback.PlaybackRef
import kotlinx.coroutines.*
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.*
import java.util.concurrent.atomic.AtomicBoolean
import com.soundq.android.PhoneOriginals
import com.soundq.android.PhoneRetriever
import com.soundq.android.PhoneUri
import com.soundq.android.PhoneRetriever as MediaMetadataRetriever
import com.soundq.android.PhoneUri as Uri
typealias Dp=Int
'''+text[text.index('private val phoneArtworkReaders'):])
    (output/'ConsumerGraph.kt').write_text('''package com.soundq.android
import com.soundq.android.data.AccountSession
import com.soundq.android.playback.PlaybackRef
import java.util.concurrent.atomic.AtomicInteger
internal class AppGraph(val libraryArtwork:com.soundq.android.product.artwork.LibraryArtwork,private val accountSession:AccountSession?=null) {
 val session:AccountSession get()=accountSession ?: error("Remote binding does not use graph session")
 val phoneAudio=PhoneBoundary {session}
 val applicationContext=PhoneOriginals()
}
class PhoneBoundary(private val session:()->AccountSession) {
 var available=true
 fun current(version:Long)=available&&session().version()==version
 fun observed(ref:PlaybackRef.Device):PhoneRow?=if(available)PhoneRow(listOf(PhoneAlias(PhoneLocator(ref.id))))else null
}
class PhoneRow(val aliases:List<PhoneAlias>)
class PhoneAlias(val locator:PhoneLocator,val state:com.soundq.android.data.deviceaudio.AccessState=com.soundq.android.data.deviceaudio.AccessState.AVAILABLE)
class PhoneLocator(val value:String)
class PhoneUri(val value:String) {companion object {fun parse(value:String)=PhoneUri(value)}}
class PhoneOriginals {
 var read:(String)->ByteArray?={error("Original hardware read must be supplied by the test")}
 val released=AtomicInteger()
}
class PhoneRetriever {
 private lateinit var originals:PhoneOriginals
 private lateinit var locator:PhoneUri
 fun setDataSource(context:PhoneOriginals,uri:PhoneUri){originals=context;locator=uri}
 val embeddedPicture:ByteArray? get()=originals.read(locator.value)
 fun release(){originals.released.incrementAndGet()}
}
''')
    (output/'PhoneAccessBoundary.kt').write_text('package com.soundq.android.data.deviceaudio\nenum class AccessState {AVAILABLE}\n')
    (output/'PhoneLifecycleBoundary.kt').write_text('''package androidx.lifecycle
class Lifecycle {
 enum class State {INITIALIZED, RESUMED;fun isAtLeast(other:State)=ordinal>=other.ordinal}
 val currentStateFlow=kotlinx.coroutines.flow.MutableStateFlow(State.RESUMED)
 enum class Event {ON_RESUME, ON_PAUSE}
 // This extraction fixture is always resumed; Android lifecycle is tested on device.
 fun addObserver(observer:LifecycleEventObserver){observer.onStateChanged(this,Event.ON_RESUME)}
 fun removeObserver(observer:LifecycleEventObserver){}
}
fun interface LifecycleEventObserver {fun onStateChanged(owner:Lifecycle,event:Lifecycle.Event)}
''')
    (output/'PhoneLifecycleOwnerBoundary.kt').write_text('''package androidx.lifecycle.compose
class LifecycleOwner {val lifecycle=androidx.lifecycle.Lifecycle()}
object LocalLifecycleOwner {val current=LifecycleOwner()}
''')
    (output/'PhoneStateBoundary.kt').write_text('''package com.soundq.android.product.artwork
class ProbeState<T>(var value:T) {operator fun getValue(receiver:Any?,property:kotlin.reflect.KProperty<*>)=value}
internal fun <T> rememberUpdatedState(value:T):ProbeState<T> = remember {ProbeState(value)}.also {it.value=value}
internal fun <T> mutableStateOf(value:T)=ProbeState(value)
internal fun <T> kotlinx.coroutines.flow.StateFlow<T>.collectAsState()=ProbeState(value)
''')
