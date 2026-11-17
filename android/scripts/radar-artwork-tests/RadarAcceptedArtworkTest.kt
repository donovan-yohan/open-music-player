package com.soundq.android.product.discovery

import com.soundq.android.data.*
import com.soundq.android.data.discovery.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.concurrent.*

/** Real session + repository + parser + acquisition + checked draw; authorized API boundary is host-only. */
class RadarAcceptedArtworkTest {
 private fun wire():String {
  val body=Json.parseToJsonElement(File(System.getProperty("soundq.radar.wire")).readText()).jsonObject
  val song=body.getValue("items").jsonArray.single().jsonObject
  return JsonObject(body+mapOf("policyVersion" to JsonPrimitive("recording-radar-v2"),"items" to JsonArray(listOf(JsonObject(song+mapOf("releaseGroupMbid" to JsonPrimitive("48140466-cff6-3222-bd55-63c27e43190d"))))))).toString()
 }
 private val store get()=object:SessionStore {override fun load(endpoint:ApiEndpoint):SecretTokens?=null;override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){};override fun clear(){}}
 private fun settle(pool:RadarArtworkPool){val end=System.nanoTime()+TimeUnit.SECONDS.toNanos(5);while(pool.resources()[1]!=0&&System.nanoTime()<end)Thread.sleep(2);assertEquals(0,pool.resources()[1])}
 private fun png():ByteArray {val bytes=java.io.ByteArrayOutputStream();javax.imageio.ImageIO.write(java.awt.image.BufferedImage(16,16,java.awt.image.BufferedImage.TYPE_INT_RGB),"png",bytes);return bytes.toByteArray()}
 @Test fun actualAcceptedRadarOwnersRefuseOldPaintAcrossAccountRoutePageDraftAndForeground() {
  for(change in listOf("account","route","page","draft","foreground"))HttpsFixture().use {metadata->CaaTlsFixture().use {art->
   val session=AccountSession(metadata.endpoint,store).apply {accept(beginIntent(),SecretTokens("synthetic-access","r","A"))}
   val repo=DiscoveryRepository(session,SoundQApi(session,metadata.client),radarAdmitted=true)
   val view=repo.open()!!;var visible=true;val landing=repo.showRadar(view){visible}!!
   metadata.reply(wire());repo.loadRadar(repo.claimRadar(view)!!)
   assertEquals("recording-radar-v2",metadata.server.takeRequest().headers["X-SoundQ-Radar-Policy"])
   val page=repo.radar.value.page!!;val song=page.songs.single();val draft=repo.state.value.draft
   assertTrue(repo.radarCurrent(view,page,song,draft))
   val pool=RadarArtworkPool(reader={art.read(it)})
   art.server.enqueue(mockwebserver3.MockResponse.Builder().body(okio.Buffer().write(png())).build())
   val lease=pool.open(art.client,song.artwork){repo.radarCurrent(view,page,song,draft)}
   try {
    lease.start();settle(pool);val pixels=lease.bitmap();assertNotNull(change,pixels);val draw=DrawBoundary();draw.paint(pixels,lease::bitmap);assertEquals(1,draw.images)
    when(change) {
     "account"->{session.accept(session.beginIntent(),SecretTokens("b","r","B"));session.accept(session.beginIntent(),SecretTokens("a2","r","A"))}
     "route"->{repo.close(view);val fresh=repo.open()!!;repo.showRadar(fresh){true}}
     "page"->{metadata.reply(wire());repo.loadRadar(repo.claimRadar(view,refresh=true)!!);assertNotSame(page,repo.radar.value.page)}
     "draft"->{repo.edit(view,"typing");repo.edit(view,"")}
     "foreground"->{visible=false;repo.hideRadar(landing);lease.close();visible=true;repo.showRadar(view){visible}}
    }
    assertFalse(change,repo.radarCurrent(view,page,song,draft)&&change!="foreground")
    draw.paint(pixels,lease::bitmap);assertEquals("old paint $change",1,draw.images);assertNull(lease.bitmap())
   }finally {lease.close();settle(pool);repo.retire()}
  }}
 }
 @Test fun exactComposableBindingRenewsSurfaceAndForegroundButNeverOldLease() {
  HttpsFixture().use {metadata->CaaTlsFixture().use {art->
   val session=AccountSession(metadata.endpoint,store).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
   val repo=DiscoveryRepository(session,SoundQApi(session,metadata.client),radarAdmitted=true);val view=repo.open()!!;repo.showRadar(view){true}
   metadata.reply(wire());repo.loadRadar(repo.claimRadar(view)!!);val page=repo.radar.value.page!!;val song=page.songs.single();val draft=repo.state.value.draft
   val pool=RadarArtworkPool(reader={art.read(it)});var surface:Any=Any()
   val host=androidx.compose.runtime.HostComposition
   androidx.lifecycle.compose.LocalLifecycleOwner.current=androidx.lifecycle.LifecycleOwner()
   val lifecycle=androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
   fun render(){host.render {RadarArtwork(art.client,repo,view,page,song,draft,surface,pool)}}
   art.server.enqueue(mockwebserver3.MockResponse.Builder().body(okio.Buffer().write(png())).build())
   try {
    render();settle(pool);val old=com.soundq.android.product.artwork.PaintBinding.bitmap;assertNotNull(old())
    render();assertNotNull(old());assertEquals(1,art.server.requestCount)
    surface=Any();render();val replacement=com.soundq.android.product.artwork.PaintBinding.bitmap;assertNull(old());assertNotNull(replacement())
    lifecycle.dispatch(androidx.lifecycle.Lifecycle.State.STARTED);assertNull(replacement())
    lifecycle.dispatch(androidx.lifecycle.Lifecycle.State.RESUMED);assertNull(replacement());render();settle(pool)
    val resumed=com.soundq.android.product.artwork.PaintBinding.bitmap;assertNotNull(resumed());assertNull(old());assertNull(replacement())
    host.dispose();assertNull(resumed());assertEquals(0,pool.resources()[0]);assertEquals(1,art.server.requestCount)
   }finally {host.dispose();settle(pool);repo.retire()}
  }}
 }
 @Test fun pageReplacementDuringHeldDecodeCannotPublishOldPixels() {
  HttpsFixture().use {metadata->CaaTlsFixture().use {art->
   val session=AccountSession(metadata.endpoint,store).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
   val repo=DiscoveryRepository(session,SoundQApi(session,metadata.client),radarAdmitted=true);val view=repo.open()!!;repo.showRadar(view){true}
   metadata.reply(wire());repo.loadRadar(repo.claimRadar(view)!!);val page=repo.radar.value.page!!;val song=page.songs.single();val draft=repo.state.value.draft
   val entered=CountDownLatch(1);val release=CountDownLatch(1)
   val pool=RadarArtworkPool(decode={data->entered.countDown();check(release.await(5,TimeUnit.SECONDS));com.soundq.android.product.artwork.decodeArtwork(data,192)},reader={art.read(it)})
   art.server.enqueue(mockwebserver3.MockResponse.Builder().body(okio.Buffer().write(png())).build());val lease=pool.open(art.client,song.artwork){repo.radarCurrent(view,page,song,draft)}
   try {lease.start();assertTrue(entered.await(3,TimeUnit.SECONDS));metadata.reply(wire());repo.loadRadar(repo.claimRadar(view,true)!!);assertEquals(1,pool.resources()[1]);release.countDown();settle(pool);assertNull(lease.bitmap());assertEquals(0,pool.resources()[2])}
   finally {release.countDown();lease.close();settle(pool);repo.retire()}
  }}
 }
}
