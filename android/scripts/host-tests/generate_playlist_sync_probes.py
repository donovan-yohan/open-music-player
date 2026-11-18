"""Extract actual root lifecycle callbacks and source-sync control body.
Platform lifecycle enum/render primitives are facades; no repository callback,
read/POST guard or production callback statement is substituted.
"""
import json,hashlib

def block(source,at):
    """Return an unchanged Kotlin body; only code braces delimit the body.

    Skip quoted/raw strings (including nested template expressions), character
    literals, line comments and nested block comments. Fail closed on truncation.
    """
    def comment(i):
        if source.startswith('//',i):
            end=source.find('\n',i+2)
            return len(source) if end<0 else end
        if source.startswith('/*',i):
            depth=1;i+=2
            while i<len(source) and depth:
                if source.startswith('/*',i):depth+=1;i+=2
                elif source.startswith('*/',i):depth-=1;i+=2
                else:i+=1
            if depth:raise ValueError('Unterminated Kotlin comment')
            return i
        return i
    def quoted(i):
        token='"""' if source.startswith('"""',i) else source[i]
        i+=len(token)
        while i<len(source):
            if source.startswith(token,i):return i+len(token)
            if token!='"""' and source[i]=='\\':i+=2
            elif token!="'" and source.startswith('${',i):i=body_end(i+1)
            else:i+=1
        raise ValueError('Unterminated Kotlin literal')
    def body_end(start):
        depth=1;i=start+1
        while i<len(source):
            end=comment(i)
            if end!=i:i=end;continue
            if source[i] in ('"',"'"):i=quoted(i);continue
            depth+=(source[i]=='{')-(source[i]=='}')
            i+=1
            if not depth:return i
        raise ValueError('Unbalanced Kotlin body')
    i=at
    while i<len(source):
        end=comment(i)
        if end!=i:i=end;continue
        if source[i] in ('"',"'"):i=quoted(i);continue
        if source[i]=='{':return source[i+1:body_end(i)-1]
        i+=1
    raise ValueError('Missing Kotlin body')

def generate(b,o):
    product=(b/'product/ProductApp.kt').read_text()
    controls=(b/'product/playlists/PlaylistSourceSyncControls.kt').read_text()

    at=product.index('DisposableEffect(model,blendLifecycle,blendVisible)')
    effect=product.index('LaunchedEffect(model,playlistDetail.id',at)
    keys=product[product.index('(',effect)+1:product.index(')',effect)]
    callback=block(product,product.index('fun sync()',at))
    dispose=block(product,product.index('onDispose',at))
    render=block(controls,controls.index('fun PlaylistSourceSyncControls'))
    visible=next(line.split('=',1)[1] for line in product.splitlines() if line.strip().startswith('val blendVisible='))
    poll=block(product,product.index('kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO)',product.index('while(true)',effect)))
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
 private var destination="Playlists";private val importView:Any?=null
 private object AuthState {class SignedIn}
 private val auth=AuthState.SignedIn();private var settingsRoutes=emptyList<String>()
 private val blendVisible get()=VISIBLE
 private var blendForeground=false;private var playlistArtworkVisit=0L
 private var syncDisposed=false
 private val playlistDetail=PlaylistDetailState(PlaylistId(1));private val accountVersion=0L
 fun effectKeys():List<Any?> = listOf(KEYS)
 fun sync() {CALLBACK}
 fun pause(){blendLifecycle.lifecycle.currentState=Lifecycle.State.STARTED;sync()}
 fun resume(){blendLifecycle.lifecycle.currentState=Lifecycle.State.RESUMED;sync()}
 fun dispose(){DISPOSE}
 fun settings(shown:Boolean){settingsRoutes=if(shown)listOf("Root")else emptyList();sync()}
 fun poll(syncOwner:Long){POLL}
}
'''.replace('CALLBACK',callback).replace('DISPOSE',dispose).replace('KEYS',keys).replace('VISIBLE',visible).replace('POLL',poll)
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
 fun render(state:PlaylistSourceSyncState,onSync:()->Unit,onRead:()->Unit,writeReady:Boolean=true) {RENDER}
}
'''.replace('RENDER',render)
    (o/'ProductSyncLifecycleProbe.kt').write_text(lifecycle)
    (o/'SourceSyncControlProbe.kt').write_text(rendering)
    (o/'callback-inputs.json').write_text(json.dumps({str(b/'product/ProductApp.kt'):hashlib.sha256(product.encode()).hexdigest(),str(b/'product/playlists/PlaylistSourceSyncControls.kt'):hashlib.sha256(controls.encode()).hexdigest()},indent=2))
    return [o/'ProductSyncLifecycleProbe.kt',o/'SourceSyncControlProbe.kt']
