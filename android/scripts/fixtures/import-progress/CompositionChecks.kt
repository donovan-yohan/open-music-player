package com.soundq.android.data
import androidx.compose.runtime.Effects
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.soundq.android.product.*
import com.soundq.android.product.imports.*
import com.soundq.android.data.imports.*
import host.UI
import kotlinx.coroutines.*

fun presentationChecks() {
 val f=Fixture();val job=SupervisorJob()
 val model=ProductViewModel(Graph(f.session,f.repo),CoroutineScope(job+kotlinx.coroutines.Dispatchers.Unconfined))
 try {
  model.importProgressForeground(true)
  val lease=f.progress.open()!!;f.submit();f.progress.receipts(lease);f.progress.refresh(lease)
  for(tab in listOf("Home","Discover","Library","Playlists","Imports")) {
   UI.reset();renderDock(model,tab)
   check(UI.nodes==listOf("strip","divider","player")){"actual root dock must compose progress immediately above shared player across tabs: ${UI.nodes}"}
   check(UI.text.single()=="This batch · 1 active"&&UI.spinners==1)
  }
  val calls=f.api.gets
  repeat(1000){UI.reset();renderDock(model,"Library")};check(f.api.gets==calls)
  var opened=0;UI.reset();renderDock(model,"Home"){opened++}
  val oldOpen=UI.actions.getValue("Open Imports");val oldDismiss=UI.actions.getValue("Dismiss import progress")
  oldOpen();check(opened==1)
  oldDismiss();check(f.repo.progress.value==null)
  UI.reset();renderDock(model,"Home");check(UI.nodes==listOf("player")&&UI.spinners==0&&UI.text.isEmpty())
  f.submit();f.progress.receipts(lease);f.progress.refresh(lease);f.checkBatch(1,0)
  oldDismiss();oldOpen();check(opened==1);f.checkBatch(1,0)
  for(status in listOf(ImportStatus.Failed,ImportStatus.Complete)) {
   val id=f.api.jobs.keys.last();f.status(id,status);f.now+=ImportProgressObservation.POLL_MS
   // Complete cannot overwrite an earlier terminal failed observation without explicit recovery.
   if(status==ImportStatus.Complete)continue
   f.progress.refresh(lease);UI.reset();renderDock(model,"Home")
   check(UI.spinners==0&&UI.text.single().contains("1 failed")&&!UI.text.single().contains("complete"))
  }
  f.progress.visible(false);oldOpen();check(opened==1)
  println("PASS exact root dock + actual strip: all tabs, idle removal, factual spinner/text, stale callbacks and 1000 tick-like rerenders without IO")
 } finally {model.importProgressForeground(false);job.cancel()}
}

fun vmChecks()=runBlocking {
 val f=Fixture();val job=SupervisorJob()
 val graph=Graph(f.session,f.repo)
 val model=ProductViewModel(graph,CoroutineScope(job+kotlinx.coroutines.Dispatchers.Unconfined))
 try {
  val lifecycle=LocalLifecycleOwner.current.lifecycle
  lifecycle.currentState=Lifecycle.State.RESUMED
  ImportProgressLifecycle(model)
  suspend fun until(block:()->Boolean) {withTimeout(3_000){while(!block())yield()}}
  val id=f.submit()
  until {f.repo.progress.value?.active==1}
  check(f.api.gets==1)
  repeat(100){graph.acquisition.state.value++}
  check(f.api.gets==1)
  val extra=ImportJobId("123e4567-e89b-12d3-a456-000000001000")
  f.api.jobs[extra]=ImportJob(extra,ImportStatus.Processing,20,null,"soundcloud")
  f.receipt(extra);graph.acquisition.state.value++
  until {f.repo.progress.value?.active==2};check(f.api.gets==2)
  f.status(id,ImportStatus.Complete);f.status(extra,ImportStatus.Complete)
  f.now+=ImportProgressObservation.POLL_MS;graph.acquisition.state.value++
  until {f.repo.progress.value?.complete==2};check(f.repo.progress.value!!.active==0)
  f.now+=ImportProgressObservation.DWELL_MS;graph.acquisition.state.value++
  until {f.repo.progress.value==null}
  val calls=f.api.gets
  repeat(100){graph.acquisition.state.value++};check(f.api.gets==calls)
  lifecycle.dispatch(Lifecycle.State.STARTED)
  check(f.progress.open()==null&&f.repo.progress.value==null)
  lifecycle.dispatch(Lifecycle.State.RESUMED)
  val fresh=f.submit();until {f.repo.progress.value?.active==1}
  f.session.accept(f.session.beginIntent(),SecretTokens("new","r","B"))
  until {f.repo.progress.value==null}
  Effects.dispose();check(lifecycle.observers.isEmpty()&&f.progress.open()==null)
  println("PASS exact ViewModel collector + lifecycle callbacks: import/acquisition signals, finite dwell, idle no IO, background/resume, account change and disposal")
 } finally {model.importProgressForeground(false);job.cancelAndJoin()}
}
