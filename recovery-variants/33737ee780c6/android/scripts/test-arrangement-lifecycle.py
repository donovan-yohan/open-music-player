from pathlib import Path
import sys,re
root=Path(sys.argv[1]);out=Path(sys.argv[2]);out.mkdir(parents=True,exist_ok=True)
text=(root/'app/src/main/kotlin/com/soundq/android/product/timeline/StackedTimeline.kt').read_text()
match=re.search(r'    val admitted:\(\)->Boolean=(.*)',text)
assert match is not None,'production TimelinePanel admission is required'
expr=match.group(1)
source=r'''
package com.soundq.android.product.timeline
import androidx.lifecycle.*
import com.soundq.android.data.*
import com.soundq.android.data.timeline.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Test
import java.io.File
class ArrangementLifecycleTest {
 private class Owner:LifecycleOwner { val registry=LifecycleRegistry.createUnsafe(this);override val lifecycle:Lifecycle get()=registry }
 private data class Occurrence(val occurrenceId:String,val trackId:Long)
 private data class Projection(val queue:List<Occurrence>)
 private class Graph(val session:AccountSession)
 private class Model(val graph:Graph) {val playback=MutableStateFlow(Projection(listOf(Occurrence("a",7))))}
 @Test fun actualPanelPredicatePermanentlyRetiresHeldReadyAcrossStopResumeWithoutCompositionDisposal() {
  val owner=Owner();owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_RESUME)
  val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","fixture"))
  val model=Model(Graph(session));val scope=session.capture()!!
  val dir=java.nio.file.Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"arrangement-lifecycle-").toFile()
  try {
   val timeline=TimelineRepository(session,dir){_,_,_,_->error("no analysis")}
   timeline.observe(scope,listOf(TimelineSource("a",7,"Fixture",2000,QueueSegment.Context)))
   val document=timeline.state.value.document
   val live=java.util.concurrent.atomic.AtomicBoolean(true)
   val valid:()->Boolean={true}
   SETUP
   val admitted:()->Boolean=EXPRESSION
   assertTrue("Positive initial native lifecycle admission",admitted())
   val request=timeline.captureAudition(scope,document,admitted)!!
   assertTrue(timeline.installAudition(request,scope,document){})
   owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
   assertTrue("Composition remains mounted",live.get());assertTrue(session.current(scope))
   val afterStop=admitted()
   owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_RESUME)
   val afterResume=admitted()
   var plays=0;val ready=timeline.completeAudition(request,scope,document){plays++}
   assertFalse("STOP must revoke the actual panel predicate",afterStop)
   assertFalse("RESUME cannot revive a prior admission",afterResume)
   assertFalse(ready);assertEquals(0,plays)
   FRESH
  } finally {dir.deleteRecursively()}
 }
}
'''
setup=''
fresh=''
if 'lifetime.capture' in expr:
 setup='val lifecycleState=owner.lifecycle.currentState;val lifetime=ArrangementLifetime(owner.lifecycle);owner.lifecycle.addObserver(lifetime)'
 fresh='val renewed=lifetime.capture(valid);assertTrue(renewed());val next=timeline.captureAudition(scope,document,renewed)!!;assertTrue(timeline.installAudition(next,scope,document){});assertTrue(timeline.completeAudition(next,scope,document){plays++});owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_STOP);assertEquals("Accepted playback is not stopped by admission cleanup",1,plays);lifetime.close();owner.lifecycle.removeObserver(lifetime)'
source=source.replace('SETUP',setup).replace('EXPRESSION',expr).replace('FRESH',fresh)
(out/'ArrangementLifecycleTest.kt').write_text(source)
