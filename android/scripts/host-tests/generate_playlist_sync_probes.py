"""Extract actual root lifecycle callbacks and source-sync control body.
Platform lifecycle enum/render primitives are facades; no repository callback,
read/POST guard or production callback statement is substituted.
"""
import json,hashlib

def generate(b,o):
    product=(b/'product/ProductApp.kt').read_text()
    controls=(b/'product/playlists/PlaylistSourceSyncControls.kt').read_text()
    def block(source,at):
        start=source.index('{',at);depth=1;i=start+1
        while depth:
            depth+=(source[i]=='{')-(source[i]=='}');i+=1
        return source[start+1:i-1]
    at=product.index('DisposableEffect(model,blendLifecycle,blendVisible)')
    effect=product.index('LaunchedEffect(model,playlistDetail.id',at)
    keys=product[product.index('(',effect)+1:product.index(')',effect)]
    callback=block(product,product.index('fun sync()',at))
    dispose=block(product,product.index('onDispose',at))
    render=block(controls,controls.index('fun PlaylistSourceSyncControls'))
    lifecycle='''package com.soundq.android.data
import com.soundq.android.data.playlists.*
/** Host adapter around the exact production callback bodies. */
internal class ProductSyncLifecycleProbe(repo:PlaylistSourceSyncRepository) {
 private object Lifecycle {enum class State {STARTED,RESUMED;fun isAtLeast(other:State)=ordinal>=other.ordinal}}
 private class HostLifecycle {var currentState=Lifecycle.State.STARTED;fun removeObserver(observer:Any){}}
 private class Owner {val lifecycle=HostLifecycle()}
 private class Blend {fun visible(value:Boolean){}}
 private class Graph(val playlistSync:PlaylistSourceSyncRepository){val playlistBlend=Blend()}
 private class Model(repo:PlaylistSourceSyncRepository){val graph=Graph(repo)}
 private val model=Model(repo);private val blendLifecycle=Owner();private val observer=Any()
 private var blendVisible=true;private var blendForeground=false;private var playlistArtworkVisit=0L
 private var syncDisposed=false
 private val playlistDetail=PlaylistDetailState(PlaylistId(1));private val accountVersion=0L
 fun effectKeys():List<Any?> = listOf(KEYS)
 fun sync() {CALLBACK}
 fun pause(){blendLifecycle.lifecycle.currentState=Lifecycle.State.STARTED;sync()}
 fun resume(){blendLifecycle.lifecycle.currentState=Lifecycle.State.RESUMED;sync()}
 fun dispose(){DISPOSE}
}
'''.replace('CALLBACK',callback).replace('DISPOSE',dispose).replace('KEYS',keys)
    rendering='''package com.soundq.android.data
import com.soundq.android.data.playlists.*
/** Captures semantic labels/callbacks, not Compose geometry or lifecycle. */
internal class SourceSyncControlProbe {
 val buttons=linkedMapOf<String,()->Unit>();val labels=mutableListOf<String>()
 private object SoundQ {object typography {val caption=Unit}}
 private enum class SoundQButtonVariant {Secondary}
 private fun Column(body:()->Unit)=body()
 private fun Text(text:String,style:Any){labels.add(text)}
 private fun SoundQButton(label:String,onClick:()->Unit,enabled:Boolean=true,variant:SoundQButtonVariant=SoundQButtonVariant.Secondary){if(enabled)buttons[label]=onClick}
 fun render(state:PlaylistSourceSyncState,onSync:()->Unit,onRead:()->Unit) {RENDER}
}
'''.replace('RENDER',render)
    (o/'ProductSyncLifecycleProbe.kt').write_text(lifecycle)
    (o/'SourceSyncControlProbe.kt').write_text(rendering)
    (o/'callback-inputs.json').write_text(json.dumps({str(b/'product/ProductApp.kt'):hashlib.sha256(product.encode()).hexdigest(),str(b/'product/playlists/PlaylistSourceSyncControls.kt'):hashlib.sha256(controls.encode()).hexdigest()},indent=2))
