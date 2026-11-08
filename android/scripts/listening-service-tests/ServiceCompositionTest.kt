package com.soundq.android.playback.listening

import android.os.Bundle
import androidx.media3.common.Player
import androidx.media3.session.MediaSession
import com.soundq.android.SoundQApplication
import com.soundq.android.playback.SoundQLibraryService
import com.soundq.android.playback.ServiceQueuePlayer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Real service command policy and real Media3 owner. No Android execution claim. */
@RunWith(RobolectricTestRunner::class)
@Config(manifest=Config.NONE,sdk=[28],application=android.app.Application::class)
internal class ServiceCompositionTest {
 @Test fun ownControllerOffersOnlyCommandsTheSelectedOwnerCanExecute() {
  ServiceProbe().use {h->
   val service=SoundQLibraryService()
   val output=java.lang.reflect.Proxy.newProxyInstance(javaClass.classLoader,arrayOf(androidx.media3.exoplayer.ExoPlayer::class.java)){_,method,args->
    if(method.name=="getAvailableCommands")Player.Commands.Builder().addAllCommands().remove(Player.COMMAND_SET_SHUFFLE_MODE).build()
    else method.invoke(h.output,*(args ?: emptyArray()))
   } as androidx.media3.exoplayer.ExoPlayer
   val owner=ServiceQueuePlayer(output)
   fun field(name:String)=SoundQLibraryService::class.java.getDeclaredField(name).apply{isAccessible=true}
   field("player").set(service,owner)
   val constructor=MediaSession.ControllerInfo::class.java.declaredConstructors.single{it.parameterCount==8}.apply{isAccessible=true}
   val remote=constructor.parameterTypes[0].getConstructor(String::class.java,Int::class.javaPrimitiveType,Int::class.javaPrimitiveType).newInstance("fixture",android.os.Process.myPid(),org.robolectric.RuntimeEnvironment.getApplication().applicationInfo.uid)
   val controller=constructor.newInstance(remote,1,1,true,null,Bundle.EMPTY,0,true) as MediaSession.ControllerInfo
   // Own admission uses the service Context. Attach it without running service startup.
   val attach=android.content.ContextWrapper::class.java.getDeclaredMethod("attachBaseContext",android.content.Context::class.java).apply{isAccessible=true}
   attach.invoke(service,org.robolectric.RuntimeEnvironment.getApplication())
   val method=SoundQLibraryService::class.java.getDeclaredMethod("commands",Boolean::class.javaPrimitiveType,MediaSession.ControllerInfo::class.java).apply{isAccessible=true}
   val offered=method.invoke(service,true,controller) as Player.Commands
   // Exo boundary deliberately advertises no shuffle. The service may not invent it.
   assertFalse("unsupported shuffle must not be offered",offered.contains(Player.COMMAND_SET_SHUFFLE_MODE))
   assertTrue(offered.contains(Player.COMMAND_PLAY_PAUSE))
  }
 }
 @Test fun failedNewSetCannotLetQueuedPreparePlayResumeTheOldSelection() {
  ServiceProbe(rolling=true).use {h->
   h.player.setMediaItems(h.items,1,1700);h.player.pause()
   val transport=com.soundq.android.playback.system.ServiceTransportPlayer(h.player){true}
   val invalid=h.items.first().buildUpon().setMediaMetadata(h.items.first().mediaMetadata.buildUpon().setExtras(Bundle(h.items.first().mediaMetadata.extras).apply{putLong("durationMs",0)}).build()).build()
   assertTrue(runCatching{transport.setMediaItems(listOf(invalid),0,0)}.isFailure)
   transport.prepare();transport.play()
   assertFalse("a failed new context must not resume old observation",h.player.playWhenReady)
   assertEquals(1,h.player.currentMediaItemIndex);assertEquals(1700L,h.player.currentPosition)
   assertEquals(h.items,(0 until h.player.mediaItemCount).map(h.player::getMediaItemAt));assertEquals(0,h.playCalls)
   transport.setMediaItems(h.items,0,0);transport.prepare();transport.play()
   assertTrue("fresh accepted selection restores transport admission",h.player.playWhenReady)
  }
 }
 @Test fun boundedOwnerRefusesUnsupportedCustomActionsBeforeAnyCollaboratorAccess() {
  ServiceProbe(rolling=true).use {h->
   val service=SoundQLibraryService()
   val attach=android.content.ContextWrapper::class.java.getDeclaredMethod("attachBaseContext",android.content.Context::class.java).apply{isAccessible=true}
   attach.invoke(service,org.robolectric.RuntimeEnvironment.getApplication())
   SoundQLibraryService::class.java.getDeclaredField("player").apply{isAccessible=true}.set(service,h.player)
   val ctor=MediaSession.ControllerInfo::class.java.declaredConstructors.single{it.parameterCount==8}.apply{isAccessible=true}
   val remote=ctor.parameterTypes[0].getConstructor(String::class.java,Int::class.javaPrimitiveType,Int::class.javaPrimitiveType).newInstance("fixture",android.os.Process.myPid(),service.applicationInfo.uid)
   val controller=ctor.newInstance(remote,1,1,true,null,Bundle.EMPTY,0,true) as MediaSession.ControllerInfo
   val callback=Class.forName("com.soundq.android.playback.SoundQLibraryService\$Callback").getDeclaredConstructor(SoundQLibraryService::class.java).apply{isAccessible=true}.newInstance(service) as androidx.media3.session.MediaLibraryService.MediaLibrarySession.Callback
   // graph/transport intentionally unbound. Refusal must precede their first access.
   val session=MediaSession.Builder(service,h.player).build()
   try {for(action in listOf(SoundQLibraryService.PLAY_MIX,SoundQLibraryService.APPLY_ARRANGEMENT,SoundQLibraryService.RETURN_SOURCES,SoundQLibraryService.JAM_ADMIT)) {
    assertEquals(androidx.media3.session.SessionError.ERROR_NOT_SUPPORTED,callback.onCustomCommand(session,controller,androidx.media3.session.SessionCommand(action,Bundle.EMPTY),Bundle.EMPTY).get().resultCode)
   }}finally{session.release()}
  }
 }
 @Test @Config(application=RollingCompositionApplication::class)
 fun actualServiceRestoreReadRefusesIncompatibleModesAndNeverPublishesGrants() {
  val app=org.robolectric.RuntimeEnvironment.getApplication() as RollingCompositionApplication
  val session=app.graph.session
  check(session.accept(session.beginIntent(),com.soundq.android.data.SecretTokens("test-access","test-refresh","service-test")))
  val scope=session.capture()!!
  val file=SoundQLibraryService::class.java.getDeclaredMethod("queueFile",com.soundq.android.data.AccountScope::class.java).apply{isAccessible=true}.let{method->
   val uncreated=SoundQLibraryService();SoundQLibraryService::class.java.getDeclaredField("graph").apply{isAccessible=true}.set(uncreated,app.graph);method.invoke(uncreated,scope) as java.io.File
  }
  val raw=com.soundq.android.playback.QueueSnapshot(app.graph.endpoint.identity,scope.accountId,listOf(com.soundq.android.playback.SavedOccurrence("saved",7,"Saved","Fixture",false,false,10000)),0,100,true).encode()
  file.writeText(raw)
  val controller=Robolectric.buildService(SoundQLibraryService::class.java).create()
  try {
   val service=controller.get()
   val read=SoundQLibraryService::class.java.getDeclaredMethod("readSavedQueue",com.soundq.android.data.AccountScope::class.java,kotlin.coroutines.Continuation::class.java).apply{isAccessible=true}
   val result=kotlinx.coroutines.runBlocking {
    kotlin.coroutines.intrinsics.suspendCoroutineUninterceptedOrReturn<Any?> {continuation->read.invoke(service,scope,continuation)}
   }
   assertNull(result);assertEquals(raw,file.readText())
   assertTrue((SoundQLibraryService::class.java.getDeclaredField("grants").apply{isAccessible=true}.get(service) as Map<*,*>).isEmpty())
   assertEquals(0,app.owner!!.mediaItemCount)
  }finally{controller.destroy();app.graph.close()}
 }
 @Test @Config(application=RollingCompositionApplication::class)
 fun realServiceConstructionSelectsOnceBeforeAttachingRawConsumersAndReleasesOutput() {
  val app=org.robolectric.RuntimeEnvironment.getApplication() as RollingCompositionApplication
  val controller=Robolectric.buildService(SoundQLibraryService::class.java).create()
  val service=controller.get()
  fun field(type:Class<*>,owner:Any,name:String)=type.getDeclaredField(name).apply{isAccessible=true}.get(owner)
  try {
   assertEquals(1,app.calls)
   assertSame(app.owner,field(SoundQLibraryService::class.java,service,"player"))
   for(name in listOf("continuation","recorder","interruptions")) {
    val consumer=field(SoundQLibraryService::class.java,service,name)!!
    assertSame("raw logical capability for $name",app.owner,field(consumer.javaClass,consumer,"player"))
   }
   assertFalse(app.output!!.isReleased)
  }finally{controller.destroy();assertTrue(app.output!!.isReleased);app.graph.close()}
 }
 @Test @Config(application=FailingCompositionApplication::class)
 fun realServiceFactoryFailureReleasesUntransferredOutputAndCancelsServiceJobs() {
  val app=org.robolectric.RuntimeEnvironment.getApplication() as FailingCompositionApplication
  assertTrue(runCatching{Robolectric.buildService(SoundQLibraryService::class.java).create()}.isFailure)
  assertEquals(1,app.calls);assertTrue(app.output!!.isReleased)
  assertFalse(app.jobs!!.coroutineContext[kotlinx.coroutines.Job]!!.isActive)
  app.graph.close()
 }
 @Test fun ordinaryApplicationFactoryKeepsServiceQueuePlayerAndTheSuppliedOutput() {
  ServiceProbe().use{h->
   val app=SoundQApplication()
   val owner=app.createLibraryPlayer(h.output,h.grants,h.jobs)
   assertTrue(owner is ServiceQueuePlayer)
   owner.release();assertEquals(1,h.releaseCalls)
  }
 }
 @Test fun incompatibleRollingRestoreRetainsBytesAndIssuesNoGrants() {
  ServiceProbe(rolling=true).use {h->
   val service=SoundQLibraryService()
   fun field(name:String)=SoundQLibraryService::class.java.getDeclaredField(name).apply{isAccessible=true}
   field("player").set(service,h.player);field("graph").set(service,h.graph)
   val file=SoundQLibraryService::class.java.getDeclaredMethod("queueFile",com.soundq.android.data.AccountScope::class.java).apply{isAccessible=true}.invoke(service,h.scope) as java.io.File
   val rows=listOf(com.soundq.android.playback.SavedOccurrence("saved",7,"Saved","Fixture",false,false,10000))
   val method=SoundQLibraryService::class.java.getDeclaredMethod("savedItems",com.soundq.android.data.AccountScope::class.java,com.soundq.android.playback.QueueSnapshot::class.java).apply{isAccessible=true}
   for(saved in listOf(com.soundq.android.playback.QueueSnapshot(h.graph.endpoint.identity,h.scope.accountId,rows,0,100,true),com.soundq.android.playback.QueueSnapshot(h.graph.endpoint.identity,h.scope.accountId,rows.map{it.copy(durationMs=0)},0,0))) {
    val raw=saved.encode();file.writeText(raw)
    assertTrue("unsupported restore refused before grants",runCatching{method.invoke(service,h.scope,saved)}.isFailure)
    assertTrue((field("grants").get(service) as Map<*,*>).isEmpty());assertEquals(raw,file.readText());assertEquals(0,h.player.mediaItemCount)
   }
  }
 }
}

open class RollingCompositionApplication:SoundQApplication() {
 var calls=0
 var output:androidx.media3.exoplayer.ExoPlayer?=null
 var owner:Player?=null
 var jobs:kotlinx.coroutines.CoroutineScope?=null
 override fun onCreate(){graph=com.soundq.android.AppGraph(this,com.soundq.android.data.ApiEndpoint.parse("https://fixture.invalid/api/v1"),store=object:com.soundq.android.data.SessionStore{
  override fun load(endpoint:com.soundq.android.data.ApiEndpoint):com.soundq.android.data.SecretTokens?=null
  override fun save(endpoint:com.soundq.android.data.ApiEndpoint,tokens:com.soundq.android.data.SecretTokens){}
  override fun clear(){}
 })}
 override fun createLibraryPlayer(output:androidx.media3.exoplayer.ExoPlayer,grants:java.util.concurrent.ConcurrentHashMap<String,com.soundq.android.playback.MediaGrant>,jobs:kotlinx.coroutines.CoroutineScope):Player {
  calls++;this.output=output;this.jobs=jobs
  return ListeningServicePlayer.createRollingMp3(output,graph,grants,jobs,1000).also{owner=it}
 }
}
class FailingCompositionApplication:RollingCompositionApplication() {
 override fun createLibraryPlayer(output:androidx.media3.exoplayer.ExoPlayer,grants:java.util.concurrent.ConcurrentHashMap<String,com.soundq.android.playback.MediaGrant>,jobs:kotlinx.coroutines.CoroutineScope):Player {
  calls++;this.output=output;this.jobs=jobs;throw IllegalStateException("synthetic factory failure before transfer")
 }
}
