"""Closed UI/platform declarations for source-host execution, not native UI."""
FACADES = {
'Compose.kt': '''package androidx.compose.runtime
import kotlin.reflect.KProperty
@Target(AnnotationTarget.FUNCTION,AnnotationTarget.TYPE) annotation class Composable
class State<T>(val value:T)
operator fun <T> State<T>.getValue(owner:Any?,property:KProperty<*>)=value
class Disposal {fun onDispose(block:()->Unit){Effects.dispose=block}}
object Effects {var dispose:()->Unit={}}
fun DisposableEffect(vararg keys:Any?,block:Disposal.()->Unit){Disposal().block()}
''',
'Modifier.kt': '''package androidx.compose.ui
open class Modifier {companion object:Modifier()}
object Alignment {val CenterVertically=Any()}
''',
'Layout.kt': '''package androidx.compose.foundation.layout
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import host.UI
object Arrangement {fun spacedBy(n:Dp)=Any()}
fun Modifier.fillMaxWidth()=this
fun Modifier.heightIn(min:Dp)=this
fun Modifier.padding(start:Dp)=this
fun Modifier.size(n:Dp)=this
fun Modifier.weight(n:Float)=this
fun Row(modifier:Modifier,verticalAlignment:Any,horizontalArrangement:Any,content:()->Unit){UI.nodes.add("strip");content()}
''',
'Dp.kt': '''package androidx.compose.ui.unit
class Dp(val value:Int)
val Int.dp get()=Dp(this)
''',
'Semantics.kt': '''package androidx.compose.ui.semantics
import androidx.compose.ui.Modifier
enum class LiveRegionMode {Polite}
class Semantics {var liveRegion=LiveRegionMode.Polite}
fun Modifier.semantics(block:Semantics.()->Unit):Modifier {Semantics().block();return this}
''',
'Material.kt': '''package androidx.compose.material3
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import host.UI
fun CircularProgressIndicator(modifier:Modifier,color:Any,strokeWidth:Dp){UI.spinners++}
fun Text(value:String,modifier:Modifier,style:Any,color:Any){UI.text.add(value)}
''',
'Lifecycle.kt': '''package androidx.lifecycle
class Owner(val lifecycle:Lifecycle=Lifecycle())
class Lifecycle {
 enum class State {CREATED,STARTED,RESUMED;fun isAtLeast(other:State)=ordinal>=other.ordinal}
 var currentState=State.RESUMED
 val observers=mutableListOf<LifecycleEventObserver>()
 fun addObserver(o:LifecycleEventObserver){observers.add(o)}
 fun removeObserver(o:LifecycleEventObserver){observers.remove(o)}
 fun dispatch(s:State){currentState=s;observers.toList().forEach {it.event(this,Any())}}
}
fun interface LifecycleEventObserver {fun event(owner:Any,event:Any)}
''',
'LifecycleCompose.kt': '''package androidx.lifecycle.compose
import kotlinx.coroutines.flow.StateFlow
import androidx.compose.runtime.State
import androidx.lifecycle.Owner
object LocalLifecycleOwner {var current=Owner()}
fun <T> StateFlow<T>.collectAsStateWithLifecycle()=State(value)
''',
'Design.kt': '''package com.soundq.designsystem
import androidx.compose.ui.unit.dp
import host.UI
object SoundQ {
 object spacing {val gutter=16.dp;val small=8.dp}
 object typography {val caption=Any()}
 object colors {val primary=Any();val text=Any()}
}
enum class SoundQIcon {Info,Close}
fun SoundQIconButton(icon:SoundQIcon,label:String,onClick:()->Unit,outlined:Boolean){UI.actions[label]=onClick}
fun SoundQDivider(){UI.nodes.add("divider")}
fun SoundQCompactPlayer(title:String,artist:String,playing:Boolean,canPlay:Boolean,preparing:Boolean,onOpen:()->Unit,onToggle:()->Unit,onQueue:()->Unit,timing:Any,artwork:()->Unit){UI.nodes.add("player")}
''',
'Artwork.kt': '''package com.soundq.android.product.artwork
fun PlayerArtwork(graph:Any,playback:Any,size:Any,valid:()->Boolean){}
''',
'UI.kt': '''package host
object UI {
 val nodes=mutableListOf<String>();val actions=mutableMapOf<String,()->Unit>();val text=mutableListOf<String>();var spinners=0
 fun reset(){nodes.clear();actions.clear();text.clear();spinners=0}
}
''',
}
