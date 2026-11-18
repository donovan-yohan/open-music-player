"""Exact consumer extraction; keyed remember/effect host facade, not native layout."""
from pathlib import Path

def generate(output: Path, presentation: Path, library_binding: Path):
    text = presentation.read_text()
    consumer = text[text.index('private class ArtworkTrackIdentity'):text.index('/** One paint body')]
    (output/'TrackBinding.kt').write_text('''package com.soundq.android.product.artwork
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import java.util.concurrent.atomic.AtomicBoolean
'''+consumer)
    text = library_binding.read_text()
    (output/'LibraryBinding.kt').write_text('''package com.soundq.android.product.artwork
import com.soundq.android.data.playlists.LibraryTrackCapture
import java.util.concurrent.atomic.AtomicBoolean
'''+text[text.index('@Composable internal fun LibraryRowArtwork'):])
    (output/'ConsumerGraph.kt').write_text('package com.soundq.android\ninternal class AppGraph(val libraryArtwork:com.soundq.android.product.artwork.LibraryArtwork)\n')
    (output/'ConsumerDemand.kt').write_text('''package com.soundq.designsystem
import com.soundq.android.product.artwork.ArtworkBindingProbe
object LocalSoundQThumbnailVisible {val current:()->Boolean get() {val p=ArtworkBindingProbe.active.get()!!;return {p.visible.value}}}
''')
    (output/'ConsumerRuntime.kt').write_text('''package com.soundq.android.product.artwork
import android.graphics.Bitmap
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
annotation class Composable
object Modifier
val Int.dp:Int get()=this
// Models keyed retention/disposal and asynchronous effects explicitly. No layout, raster,
// lifecycle, SubcomposeLayout or native scheduler is replaced with a claimed passing result.
internal class ArtworkBindingProbe:AutoCloseable {
 companion object {val active=ThreadLocal<ArtworkBindingProbe>()}
 val visible=MutableStateFlow(false)
 private val scope=CoroutineScope(SupervisorJob()+Dispatchers.Default)
 private val memory=mutableMapOf<Int,Pair<List<Any?>,Any?>>()
 private val effects=mutableMapOf<Int,Pair<List<Any?>,()->Unit>>()
 private var slot=0
 var checked:(()->Bitmap?)?=null
 fun pixels()=checked?.invoke()
 fun render(block:()->Unit) {slot=0;active.set(this);try {block()}finally {active.remove()}}
 @Suppress("UNCHECKED_CAST") fun <T> remember(keys:List<Any?>,block:()->T):T {
  val index=slot++;val old=memory[index]
  if(old!=null&&old.first==keys)return old.second as T
  return block().also {memory[index]=keys to it}
 }
 fun effect(keys:List<Any?>,block:()->(()->Unit)) {
  val index=slot++;val old=effects[index];if(old?.first==keys)return
  old?.second?.invoke();effects[index]=keys to block()
 }
 fun launch(block:suspend CoroutineScope.()->Unit):Job=scope.launch(active.asContextElement(this)) {block()}
 override fun close(){effects.values.toList().forEach {it.second()};effects.clear();memory.clear();scope.cancel()}
}
internal fun <T> remember(vararg keys:Any?,block:()->T):T=ArtworkBindingProbe.active.get()!!.remember(keys.toList(),block)
class Dispose(val close:()->Unit)
class EffectScope {fun onDispose(block:()->Unit)=Dispose(block)}
internal fun DisposableEffect(vararg keys:Any?,block:EffectScope.()->Dispose) {
 ArtworkBindingProbe.active.get()!!.effect(keys.toList()) {val result=EffectScope().block();result.close}
}
internal fun LaunchedEffect(vararg keys:Any?,block:suspend CoroutineScope.()->Unit) {
 val p=ArtworkBindingProbe.active.get()!!
 p.effect(keys.toList()) {val job=p.launch(block);{job.cancel()}}
}
internal fun <T> snapshotFlow(block:()->T):Flow<T> {
 val p=ArtworkBindingProbe.active.get()!!
 return p.visible.map {block()}.distinctUntilChanged()
}
internal fun ArtworkPaint(state:StateFlow<Bitmap?>,bitmap:()->Bitmap?,mounted:AtomicBoolean,size:Int,modifier:Modifier=Modifier) {
 ArtworkBindingProbe.active.get()!!.checked={if(mounted.get())bitmap() else null}
}
''')
