#!/usr/bin/env python3
"""Compile the entire production MainActivity against minimal Android facades.

The real onCreate/Queue button/showQueue/AlertDialog adapter and callbacks run;
only platform Views/dialog mounting and the service command boundary are facades.
This is device-free behavior proof, not Android rendering/accessibility acceptance.
Requires the installed JDK and kotlinc (see test_toolchain.py); no network/build.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

from test_toolchain import java_home, kotlin_compiler

ROOT = Path(__file__).resolve().parents[2]
ACTIVITY = 'native/android/app/src/main/java/com/soundq/nativepreview/MainActivity.kt'

FACADES = {
    'manifest.kt': '''package android
object Manifest {object permission {const val POST_NOTIFICATIONS="notifications"}}
object R {object attr {const val selectableItemBackground=1};object layout {const val select_dialog_item=1}}
''',
    'content.kt': '''package android.content
open class Context {
 companion object {const val BIND_AUTO_CREATE=1}
 fun obtainStyledAttributes(values:IntArray)=Attributes()
}
class Attributes {fun getDrawable(index:Int):Any?=null;fun recycle(){}}
class ComponentName
class Intent(context:Context,kind:Class<*>)
interface ServiceConnection {fun onServiceConnected(name:ComponentName,binder:android.os.IBinder);fun onServiceDisconnected(name:ComponentName)}
interface DialogInterface {fun dismiss()}
''',
    'pm.kt': '''package android.content.pm
object PackageManager {const val PERMISSION_GRANTED=0}
''',
    'os.kt': '''package android.os
open class Bundle
interface IBinder
object Build {object VERSION {const val SDK_INT=36}}
''',
    'graphics.kt': '''package android.graphics
object Color {const val WHITE=0xffffff;fun rgb(r:Int,g:Int,b:Int)=0}
''',
    'text.kt': '''package android.text
object InputType {const val TYPE_CLASS_TEXT=1;const val TYPE_TEXT_VARIATION_EMAIL_ADDRESS=2;const val TYPE_TEXT_VARIATION_PASSWORD=4}
''',
    'input.kt': '''package android.view.inputmethod
object EditorInfo {const val IME_ACTION_SEARCH=1}
''',
    'view.kt': '''package android.view
import android.content.Context
open class View(val context:Context) {
 companion object {const val GONE=8;const val VISIBLE=0}
 var visibility=VISIBLE;var isEnabled=true;var isFocusable=false;var isClickable=false
 var minHeight=0;var background:Any?=null;var contentDescription:CharSequence?=null
 var click:((View)->Unit)?=null
 fun setPadding(a:Int,b:Int,c:Int,d:Int){}
 fun setBackgroundColor(color:Int){}
 fun setOnClickListener(action:(View)->Unit){click=action}
 fun performClick(){if(isEnabled)click?.invoke(this)}
}
open class ViewGroup(context:Context):View(context) {
 val children=mutableListOf<View>()
 open class LayoutParams(val width:Int,val height:Int) {companion object {const val WRAP_CONTENT=-2;const val MATCH_PARENT=-1}}
 fun addView(view:View){children.add(view)}
 fun addView(view:View,params:LayoutParams){children.add(view)}
}
class Window {var statusBarColor=0}
''',
    'widget.kt': '''package android.widget
import android.content.Context
import android.view.*
open class TextView(context:Context):View(context) {
 var text:CharSequence="";var textSize=0f
 fun setTextColor(color:Int){}
}
class Editable {private var value="";fun clear(){value=""};override fun toString()=value}
class EditText(context:Context):View(context) {
 var hint="";var inputType=0;var imeOptions=0;val text=Editable()
 fun setSingleLine(){}
 fun setOnEditorActionListener(action:(TextView,Int,Any?)->Boolean){}
}
class Button(context:Context):TextView(context)
class LinearLayout(context:Context):ViewGroup(context) {
 companion object {const val VERTICAL=1};var orientation=0
 class LayoutParams(width:Int,height:Int,val weight:Float=0f):ViewGroup.LayoutParams(width,height)
}
class SeekBar(context:Context):View(context) {
 var max=0;var progress=0
 interface OnSeekBarChangeListener {fun onStartTrackingTouch(bar:SeekBar);fun onStopTrackingTouch(bar:SeekBar);fun onProgressChanged(bar:SeekBar,progress:Int,fromUser:Boolean)}
 fun setOnSeekBarChangeListener(listener:OnSeekBarChangeListener){}
}
interface ListAdapter {fun getCount():Int;fun isEnabled(position:Int):Boolean;fun areAllItemsEnabled():Boolean;fun getView(position:Int,convertView:View?,parent:ViewGroup):View;fun observe(action:()->Unit)}
open class ArrayAdapter<T>(val ctx:Context,layout:Int,val values:Array<T>):ListAdapter {
 private val observers=mutableListOf<()->Unit>()
 override fun getCount()=values.size
 override fun isEnabled(position:Int)=true
 override fun areAllItemsEnabled()=true
 override fun getView(position:Int,convertView:View?,parent:ViewGroup):View=(convertView as? TextView ?: TextView(ctx)).also {it.text=values[position].toString()}
 override fun observe(action:()->Unit){observers.add(action)}
 fun notifyDataSetChanged(){observers.forEach {it()}}
}
class ListView(context:Context,val adapter:ListAdapter):ViewGroup(context) {
 init {adapter.observe {mount()}}
 fun mount(){val old=children.toList();children.clear();repeat(adapter.getCount()){children.add(adapter.getView(it,old.getOrNull(it),this))}}
}
''',
    'app.kt': '''package android.app
import android.content.*
import android.os.*
import android.view.*
import android.widget.*
open class Activity:Context() {
 val window=Window();lateinit var content:View
 open fun onCreate(state:Bundle?){}
 open fun onDestroy(){}
 fun setContentView(root:View){content=root}
 fun checkSelfPermission(name:String)=0
 fun requestPermissions(names:Array<String>,code:Int){}
 fun bindService(intent:Intent,connection:ServiceConnection,flags:Int){}
 fun unbindService(connection:ServiceConnection){}
}
class AlertDialog(val heading:String,val listView:ListView,val action:((DialogInterface,Int)->Unit)?,val neutral:((DialogInterface,Int)->Unit)?,val message:String?,val positiveLabel:String?,val neutralLabel:String?,val hasList:Boolean):DialogInterface {
 companion object {
  val shown=mutableListOf<AlertDialog>();val pendingDismiss=mutableListOf<()->Unit>();val pendingButtons=mutableListOf<()->Unit>()
  fun drainDismissals(){while(pendingDismiss.isNotEmpty())pendingDismiss.removeAt(0).invoke()}
  fun nextButtonMessage(){pendingButtons.removeAt(0).invoke()}
  fun drainButtons(){while(pendingButtons.isNotEmpty())nextButtonMessage()}
 }
 var dismissed=false;var isShowing=false;private set
 private var onDismiss:((DialogInterface)->Unit)?=null
 fun setOnDismissListener(listener:((DialogInterface)->Unit)?){onDismiss=listener}
 // isShowing observes the visible decor installed before mounting; dismissal
 // removes it synchronously, then posts a captured listener message on main.
 fun show(){isShowing=true;dismissed=false;listView.mount();shown.add(this)}
 override fun dismiss(){if(isShowing){isShowing=false;dismissed=true;onDismiss?.let {listener->pendingDismiss.add {listener(this)}}}}
 // Platform input suppression is separate from retained raw-callback guards.
 fun choose(position:Int){if(isShowing && listView.adapter.isEnabled(position)){action?.invoke(this,position);dismiss()}}
 fun raw(position:Int){action?.invoke(this,position)}
 fun clear(){neutral?.invoke(this,0);dismiss()}
 // AlertController queues the button listener before a separate dismiss message.
 // Tests may interleave ownership changes between those two native messages.
 fun pressNeutral(){if(isShowing && neutralLabel!=null){neutral?.let {listener->pendingButtons.add {listener(this,-3)}};pendingButtons.add {dismiss()}}}
 fun rawNeutral(){neutral?.invoke(this,-3)}
 fun done(){if(isShowing && positiveLabel!=null)pendingButtons.add {dismiss()}}
 class Builder(val context:Context) {
  var heading="";var adapter:ListAdapter?=null;var message:String?=null
  var positiveLabel:String?=null;var neutralLabel:String?=null
  var action:((DialogInterface,Int)->Unit)?=null;var neutral:((DialogInterface,Int)->Unit)?=null
  fun setTitle(value:String)=apply {heading=value}
  fun setMessage(value:String)=apply {message=value}
  fun setItems(values:Array<String>,listener:(DialogInterface,Int)->Unit)=apply {adapter=ArrayAdapter(context,android.R.layout.select_dialog_item,values);action=listener}
  fun setAdapter(value:ListAdapter,listener:(DialogInterface,Int)->Unit)=apply {adapter=value;action=listener}
  fun setPositiveButton(value:String,listener:((DialogInterface,Int)->Unit)?)=apply {positiveLabel=value;check(listener==null){"facade only models null positive listener"}}
  fun setNeutralButton(value:String,listener:(DialogInterface,Int)->Unit)=apply {neutralLabel=value;neutral=listener}
  fun create():AlertDialog=AlertDialog(heading,ListView(context,adapter ?: ArrayAdapter(context,android.R.layout.select_dialog_item,emptyArray<String>())),action,neutral,message,positiveLabel,neutralLabel,adapter!=null)
  fun show():AlertDialog=create().also {it.show()}
 }
}
''',
    'recycler.kt': '''package androidx.recyclerview.widget
import android.content.Context
import android.view.*
open class RecyclerView(context:Context):ViewGroup(context) {
 var layoutManager:Any?=null;var adapter:Any?=null;var itemAnimator:Any?=null
 open class ViewHolder(val itemView:View)
}
class LinearLayoutManager(context:Context)
class DiffUtil {abstract class ItemCallback<T> {abstract fun areItemsTheSame(a:T,b:T):Boolean;abstract fun areContentsTheSame(a:T,b:T):Boolean}}
abstract class ListAdapter<T,H:RecyclerView.ViewHolder>(callback:DiffUtil.ItemCallback<T>) {
 var currentList:List<T> = emptyList();fun submitList(values:List<T>){currentList=values}
 fun getItem(index:Int)=currentList[index];fun setHasStableIds(value:Boolean){}
 open fun getItemId(position:Int)=0L
 abstract fun onCreateViewHolder(parent:ViewGroup,viewType:Int):H
 abstract fun onBindViewHolder(holder:H,position:Int)
}
''',
    'json.kt': '''package org.json
class JSONObject {
 private val values=mutableMapOf<String,Any?>()
 fun put(key:String,value:Any?)=apply {values[key]=value}
 fun optJSONArray(key:String)=values[key] as? JSONArray
 fun getJSONObject(key:String)=values[key] as JSONObject
 fun getLong(key:String)=(values[key] as Number).toLong()
 fun optLong(key:String,fallback:Long=0L)=(values[key] as? Number)?.toLong() ?: fallback
 fun getString(key:String)=values[key] as String
 fun optString(key:String)=values[key]?.toString() ?: ""
 fun optBoolean(key:String)=values[key]==true
 fun isNull(key:String)=values[key]==null
}
class JSONArray(val values:List<JSONObject> = emptyList()) {fun length()=values.size;fun getJSONObject(index:Int)=values[index]}
''',
    'service.kt': '''package com.soundq.nativepreview
import org.json.*
class PlaybackService {
 data class Call(val kind:String,val id:Long?,val index:Int?)
 var snapshot=JSONObject();val calls=mutableListOf<Call>()
 var listener:((JSONObject,String?)->Unit)?=null
 inner class LocalBinder:android.os.IBinder {val service get()=this@PlaybackService}
 fun selectedTrack():JSONObject?=null
 fun select(id:Long){};fun login(email:String,password:String){};fun library(offset:Int=0,query:String=""){}
 fun logout(){};fun command(value:JSONObject){}
 fun queueAction(kind:String,id:Long?=null,index:Int?=null){calls.add(Call(kind,id,index))}
}
object BuildConfig {const val SOURCE_REF="synthetic"}
''',
}

PROBE = r'''package com.soundq.nativepreview
import android.app.AlertDialog
import android.view.*
import android.widget.*
import org.json.*
var failures=0
fun test(name:String,body:()->Unit){try {body();println("PASS $name")}catch(e:Throwable){failures++;println("FAIL $name: ${e.message}")}finally{AlertDialog.drainButtons();AlertDialog.drainDismissals()}}
fun requireThat(value:Boolean,message:String){check(value){message}}
class Fixture(vararg ids:Long) {
 val service=PlaybackService();val activity=MainActivity()
 init {queue(*ids);activity.onCreate(null);connection().onServiceConnected(android.content.ComponentName(),service.LocalBinder())}
 fun connection()=MainActivity::class.java.getDeclaredField("connection").apply {isAccessible=true}.get(activity) as android.content.ServiceConnection
 fun queue(vararg ids:Long){service.snapshot=JSONObject().put("queue",JSONArray(ids.map {JSONObject().put("id",it).put("track",JSONObject().put("id",7L).put("title","Same recording"))})).put("selected_occurrence",ids.firstOrNull() ?: -1L)}
 fun publish(vararg ids:Long){queue(*ids);service.listener!!.invoke(service.snapshot,null)}
 fun queueDialog():AlertDialog {
  fun find(view:View):Button? {if(view is Button && view.text=="Queue")return view;return (view as? ViewGroup)?.children?.firstNotNullOfOrNull {find(it)}}
  find(activity.content)!!.performClick();return AlertDialog.shown.last()
 }
 fun actions(position:Int):AlertDialog {queueDialog().choose(position);return AlertDialog.shown.last()}
 fun sent(kind:String,id:Long?=null,index:Int?=null){requireThat(service.calls==listOf(PlaybackService.Call(kind,id,index)),"wrong dispatch ${service.calls}")}
}
fun states(dialog:AlertDialog,expected:List<Boolean>) {
 val adapter=dialog.listView.adapter
 requireThat((0 until adapter.getCount()).map {adapter.isEnabled(it)}==expected,"adapter enabled states differ")
 requireThat(dialog.listView.children.map {it.isEnabled}==expected,"mounted row enabled states differ")
 if(expected.any {!it})requireThat(!adapter.areAllItemsEnabled(),"ListView fast path incorrectly enables every row")
 requireThat(dialog.listView.children.map {(it as TextView).text.toString()}==listOf("Play","Move up","Move down","Remove"),"native action labels changed")
}
// Only API wiring and message/capability lifetime are modeled, never text paint,
// line layout or scrolling. Android's native setMessage scroll area is a separate
// real-SDK/runtime acceptance obligation.
fun fullName(actions:AlertDialog):AlertDialog {
 requireThat(actions.neutralLabel=="Full name","no reachable native Full name disclosure")
 actions.pressNeutral();AlertDialog.drainButtons()
 val detail=AlertDialog.shown.last()
 requireThat(detail!==actions && detail.isShowing && actions.dismissed,"Full name did not replace action authority")
 requireThat(detail.heading=="Track name" && detail.positiveLabel=="Done","native read-only detail chrome changed")
 requireThat(!detail.hasList && detail.action==null && detail.neutral==null,"read-only detail acquired queue actions")
 return detail
}
fun Fixture.names(vararg names:String) {
 val queue=service.snapshot.optJSONArray("queue")!!
 names.forEachIndexed {i,name->queue.getJSONObject(i).getJSONObject("track").put("title",name)}
}
fun main() {
 for(boundary in listOf("dismiss","disconnect","destroy","new-list","new-action","new-detail","service-replacement")) {
  test("outer-list-$boundary-retires-window-and-retained-clear") {
   val f=Fixture(11,12,13);val old=f.queueDialog()
   val replacement=PlaybackService().also {it.snapshot=f.service.snapshot}
   when(boundary) {
    "dismiss"->old.dismiss()
    "disconnect"->f.connection().onServiceDisconnected(android.content.ComponentName())
    "destroy"->f.activity.onDestroy()
    "new-list"->f.queueDialog()
    "new-action"->f.actions(0)
    "new-detail"->fullName(f.actions(1))
    else->f.connection().onServiceConnected(android.content.ComponentName(),replacement.LocalBinder())
   }
   // Deliberately bypass native input suppression, before the posted cleanup.
   old.rawNeutral()
   requireThat(f.service.calls.isEmpty() && replacement.calls.isEmpty(),"$boundary retained Clear dispatched")
   requireThat(old.dismissed && !old.isShowing,"$boundary stranded outer window")
   AlertDialog.drainDismissals();old.rawNeutral()
   requireThat(f.service.calls.isEmpty() && replacement.calls.isEmpty(),"$boundary cleanup revived Clear")
  }
  test("outer-list-$boundary-retained-row-refused") {
   val f=Fixture(11,12,13);val old=f.queueDialog()
   when(boundary) {
    "dismiss"->old.dismiss()
    "disconnect"->f.connection().onServiceDisconnected(android.content.ComponentName())
    "destroy"->f.activity.onDestroy()
    "new-list"->f.queueDialog()
    "new-action"->f.actions(0)
    "new-detail"->fullName(f.actions(1))
    else->f.connection().onServiceConnected(android.content.ComponentName(),PlaybackService().also {it.snapshot=f.service.snapshot}.LocalBinder())
   }
   val count=AlertDialog.shown.size;old.raw(1);AlertDialog.drainDismissals();old.raw(1)
   requireThat(AlertDialog.shown.size==count && f.service.calls.isEmpty(),"$boundary retained row opened a new action")
  }
 }
 for(next in listOf("list","action","detail")) test("outer-list-delayed-cleanup-preserves-new-$next") {
  val f=Fixture(11,12,13);val old=f.queueDialog();old.dismiss()
  val fresh=when(next) {"list"->f.queueDialog();"action"->f.actions(0);else->fullName(f.actions(1))}
  AlertDialog.drainDismissals();old.rawNeutral();old.raw(2)
  requireThat(fresh.isShowing && f.service.calls.isEmpty(),"old list cleanup retired or replaced new $next")
  when(next) {
   "list"->{fresh.pressNeutral();AlertDialog.drainButtons();f.sent("queue_clear")}
   "action"->{f.publish(13,11,12);states(fresh,listOf(true,true,true,true));fresh.choose(1);f.sent("queue_move",11,0)}
   else->{f.activity.onDestroy();requireThat(fresh.dismissed,"old list cleanup stranded new detail")}
  }
 }
 test("outer-list-row-retires-list-before-native-auto-dismiss-preserves-action") {
  val f=Fixture(11,12,13);val old=f.queueDialog();old.raw(1);val fresh=AlertDialog.shown.last()
  requireThat(old.dismissed && fresh!==old && fresh.isShowing,"row did not retire outer authority before opening action")
  old.rawNeutral();old.raw(0);old.dismiss();AlertDialog.drainDismissals()
  requireThat(f.service.calls.isEmpty() && fresh.isShowing,"retired outer callback superseded current action")
  states(fresh,listOf(true,true,true,true));fresh.choose(0);f.sent("queue_play",12)
 }
 test("outer-list-clear-listener-retires-before-native-auto-dismiss") {
  val f=Fixture(11,12,13);val old=f.queueDialog();old.pressNeutral();AlertDialog.nextButtonMessage()
  f.sent("queue_clear");requireThat(old.dismissed,"Clear listener left outer authority alive")
  old.rawNeutral();old.raw(1);f.sent("queue_clear")
  val fresh=f.actions(0);AlertDialog.drainButtons();AlertDialog.drainDismissals()
  requireThat(fresh.isShowing,"old Clear dismiss message closed new action")
  f.service.calls.clear();fresh.choose(2);f.sent("queue_move",11,1)
 }
 for(next in listOf("list","action","detail")) test("outer-list-queued-clear-after-new-$next-refused") {
  val f=Fixture(11,12,13);val old=f.queueDialog();old.pressNeutral()
  val fresh=when(next) {"list"->f.queueDialog();"action"->f.actions(0);else->fullName(f.actions(1))}
  AlertDialog.drainButtons();AlertDialog.drainDismissals()
  requireThat(f.service.calls.isEmpty() && fresh.isShowing,"queued stale Clear dispatched or retired new $next")
  f.activity.onDestroy();requireThat(fresh.dismissed,"new $next lost teardown owner")
 }
 for(boundary in listOf("disconnect","destroy","new-list","service-replacement")) test("outer-list-$boundary-closes-window-before-cleanup-message") {
  val f=Fixture(11,12,13);val old=f.queueDialog()
  when(boundary) {
   "disconnect"->f.connection().onServiceDisconnected(android.content.ComponentName())
   "destroy"->f.activity.onDestroy()
   "new-list"->f.queueDialog()
   else->f.connection().onServiceConnected(android.content.ComponentName(),PlaybackService().also {it.snapshot=f.service.snapshot}.LocalBinder())
  }
  requireThat(old.dismissed && !old.isShowing,"$boundary left outer window showing before posted cleanup")
 }
 for(boundary in listOf("disconnect","destroy","service-replacement")) test("outer-list-queued-clear-after-$boundary-refused") {
  val f=Fixture(11,12,13);val old=f.queueDialog();old.pressNeutral()
  val replacement=PlaybackService().also {it.snapshot=f.service.snapshot}
  when(boundary) {
   "disconnect"->f.connection().onServiceDisconnected(android.content.ComponentName())
   "destroy"->f.activity.onDestroy()
   else->f.connection().onServiceConnected(android.content.ComponentName(),replacement.LocalBinder())
  }
  AlertDialog.drainButtons();AlertDialog.drainDismissals()
  requireThat(f.service.calls.isEmpty() && replacement.calls.isEmpty(),"queued Clear survived $boundary")
 }
 test("outer-list-service-replacement-retires-action-and-detail") {
  val f=Fixture(11,12,13);val action=f.actions(1);val detail=fullName(action)
  val replacement=PlaybackService().also {it.snapshot=f.service.snapshot}
  f.connection().onServiceConnected(android.content.ComponentName(),replacement.LocalBinder())
  requireThat(detail.dismissed,"service replacement stranded detail")
  action.rawNeutral();for(i in 0..3)action.raw(i)
  val fresh=f.queueDialog();AlertDialog.drainDismissals();fresh.choose(1);AlertDialog.shown.last().choose(0)
  requireThat(f.service.calls.isEmpty() && replacement.calls==listOf(PlaybackService.Call("queue_play",12,null)),"replacement did not retain valid new row dispatch")
 }
 test("full-name-reachable-complete-long-unicode") {
  val name="SYNTHETIC QA — 長い夜 / e\u0301 · 🎶 " + "بدون اختصار — alternate recording ".repeat(1024)
  val f=Fixture(11,12,13);f.names(name,"QA Short",name);val d=f.actions(2)
  states(d,listOf(true,true,false,true));val detail=fullName(d)
  requireThat(detail.message==name,"long Unicode title was truncated or normalized")
  requireThat(f.service.calls.isEmpty(),"reading title dispatched playback")
 }
 test("full-name-short-current-and-browse-duplicates") {
  val f=Fixture(11,12,13);f.names("QA Short","QA Short","QA Short")
  val current=f.actions(0);requireThat(current.heading=="Current · QA Short","neutral Current marker lost")
  requireThat(fullName(current).message=="QA Short","Current marker contaminated metadata")
  val browse=f.actions(2);requireThat(browse.heading=="QA Short","browse duplicate acquired Current marker")
  requireThat(fullName(browse).message=="QA Short","short title changed")
  requireThat(f.service.snapshot.optLong("selected_occurrence")==11L && f.service.calls.isEmpty(),"browse changed ownership")
 }
 test("full-name-done-does-not-revive-dismissed-action") {
  val f=Fixture(11,12,13);val d=f.actions(1);val detail=fullName(d);detail.done();AlertDialog.drainButtons()
  requireThat(detail.dismissed,"Done did not dismiss detail");for(action in 0..3)d.raw(action)
  d.rawNeutral();AlertDialog.drainDismissals();for(action in 0..3)d.raw(action)
  requireThat(AlertDialog.shown.last()===detail && f.service.calls.isEmpty(),"closed detail revived old capability")
 }
 test("full-name-back-cancel-does-not-revive-dismissed-action") {
  val f=Fixture(11,12,13);val d=f.actions(1);val detail=fullName(d);detail.dismiss();d.rawNeutral()
  for(action in 0..3)d.raw(action)
  requireThat(AlertDialog.shown.last()===detail && f.service.calls.isEmpty(),"cancel revived old capability")
 }
 for(lifecycle in listOf("disconnect","destroy","supersede")) test("full-name-$lifecycle-retires-detail") {
  val f=Fixture(11,12,13);val d=f.actions(1);val detail=fullName(d)
  when(lifecycle) {"disconnect"->f.connection().onServiceDisconnected(android.content.ComponentName());"destroy"->f.activity.onDestroy();else->f.actions(0)}
  requireThat(detail.dismissed,"$lifecycle stranded read-only detail");d.rawNeutral()
  for(action in 0..3)d.raw(action)
  requireThat(f.service.calls.isEmpty(),"$lifecycle revived old capability")
 }
 test("full-name-old-dismiss-does-not-strand-new-action") {
  val f=Fixture(11,12,13);val old=f.actions(1);val detail=fullName(old);val fresh=f.actions(0)
  AlertDialog.drainDismissals();detail.done();AlertDialog.drainButtons();old.rawNeutral()
  f.publish(13,11,12);states(fresh,listOf(true,true,true,true));fresh.choose(1);f.sent("queue_move",11,0)
 }
 test("full-name-old-detail-dismiss-does-not-clear-new-detail") {
  val f=Fixture(11,12,13);val old=fullName(f.actions(1));val fresh=fullName(f.actions(2))
  AlertDialog.drainDismissals();requireThat(old.dismissed && fresh.isShowing,"old cleanup retired new detail")
  f.activity.onDestroy();requireThat(fresh.dismissed,"old cleanup stranded new detail")
 }
 test("full-name-reorder-keeps-clicked-name-and-occurrence") {
  val f=Fixture(11,12,13);f.names("First","Clicked 🎵","Last");val d=f.actions(1)
  f.queue(12,11,13);requireThat(fullName(d).message=="Clicked 🎵","reorder changed clicked metadata")
  requireThat(f.service.calls.isEmpty(),"read-only reorder dispatched")
 }
 for(lifecycle in listOf("dismiss","disconnect","destroy","supersede","remove")) test("retained-full-name-$lifecycle-refused") {
  val f=Fixture(11,12,13);val d=f.actions(1);requireThat(d.neutralLabel=="Full name","missing Full name control")
  when(lifecycle) {"dismiss"->d.dismiss();"disconnect"->f.connection().onServiceDisconnected(android.content.ComponentName());"destroy"->f.activity.onDestroy();"supersede"->f.actions(0);else->f.publish(11,13)}
  val count=AlertDialog.shown.size;d.rawNeutral();AlertDialog.drainDismissals();d.rawNeutral()
  requireThat(AlertDialog.shown.size==count && f.service.calls.isEmpty(),"retired Full name reopened or dispatched")
 }
 test("full-name-button-message-retires-actions-before-native-dismiss-message") {
  val f=Fixture(11,12,13);val d=f.actions(1);requireThat(d.neutralLabel=="Full name","missing Full name control")
  d.pressNeutral();AlertDialog.nextButtonMessage();val detail=AlertDialog.shown.last()
  requireThat(d.dismissed && detail!==d && detail.isShowing,"button listener left action authority alive")
  for(action in 0..3)d.raw(action)
  requireThat(f.service.calls.isEmpty(),"button/dismiss message gap dispatched")
  val fresh=f.actions(0);AlertDialog.drainButtons();AlertDialog.drainDismissals()
  f.publish(13,11,12);states(fresh,listOf(true,true,true,true));fresh.choose(1);f.sent("queue_move",11,0)
 }
 test("queued-full-name-button-after-supersession-refuses-open") {
  val f=Fixture(11,12,13);val old=f.actions(1);requireThat(old.neutralLabel=="Full name","missing Full name control")
  old.pressNeutral();val fresh=f.actions(0);val count=AlertDialog.shown.size;AlertDialog.drainButtons();AlertDialog.drainDismissals()
  requireThat(AlertDialog.shown.size==count && fresh.isShowing,"queued old button stranded new action")
  fresh.choose(2);f.sent("queue_move",11,1)
 }
 test("first-move-up-disabled-on-adapter-and-row") {val f=Fixture(11,12,13);val d=f.actions(0);states(d,listOf(true,false,true,true));d.choose(1);requireThat(f.service.calls.isEmpty(),"disabled up dispatched")}
 test("last-move-down-disabled-on-adapter-and-row") {val f=Fixture(11,12,13);val d=f.actions(2);states(d,listOf(true,true,false,true));d.choose(2);requireThat(f.service.calls.isEmpty(),"disabled down dispatched")}
 test("single-both-moves-disabled-play-remove-enabled") {val f=Fixture(11);states(f.actions(0),listOf(true,false,false,true))}
 test("interior-both-moves-enabled") {val f=Fixture(11,12,13);states(f.actions(1),listOf(true,true,true,true))}
 test("interior-up-exact-occurrence") {val f=Fixture(11,12,13);f.actions(1).choose(1);f.sent("queue_move",12,0)}
 test("interior-down-exact-occurrence") {val f=Fixture(11,12,13);f.actions(1).choose(2);f.sent("queue_move",12,2)}
 test("play-unchanged-duplicate-recording-occurrence") {val f=Fixture(11,12,13);f.actions(1).choose(0);f.sent("queue_play",12)}
 test("remove-unchanged-duplicate-recording-occurrence") {val f=Fixture(11,12,13);f.actions(2).choose(3);f.sent("queue_remove",13)}
 test("clear-unchanged") {val f=Fixture(11,12,13);f.queueDialog().clear();f.sent("queue_clear")}
 test("done-does-not-dispatch") {val f=Fixture(11);f.queueDialog().dismiss();requireThat(f.service.calls.isEmpty(),"Done dispatched")}
 test("retained-reorder-up-resolves-current-index") {val f=Fixture(11,12,13,14);val d=f.actions(1);f.queue(11,13,12,14);d.raw(1);f.sent("queue_move",12,1)}
 test("retained-reorder-down-resolves-current-index") {val f=Fixture(11,12,13,14);val d=f.actions(1);f.queue(12,11,13,14);d.raw(2);f.sent("queue_move",12,1)}
 test("retained-reorder-to-first-refuses-up") {val f=Fixture(11,12,13);val d=f.actions(1);f.queue(12,11,13);d.raw(1);requireThat(f.service.calls.isEmpty(),"stale boundary up dispatched")}
 test("retained-reorder-to-last-refuses-down") {val f=Fixture(11,12,13);val d=f.actions(1);f.queue(11,13,12);d.raw(2);requireThat(f.service.calls.isEmpty(),"stale boundary down dispatched")}
 for(action in 0..3) test("retained-removed-occurrence-refuses-action-$action") {val f=Fixture(11,12,13);val d=f.actions(1);f.queue(11,13);d.raw(action);requireThat(f.service.calls.isEmpty(),"removed occurrence dispatched")}
 test("retained-queue-disclosure-resolves-before-actions-open") {val f=Fixture(11,12,13);val q=f.queueDialog();f.queue(12,11,13);q.choose(1);val d=AlertDialog.shown.last();states(d,listOf(true,false,true,true));d.choose(2);f.sent("queue_move",12,1)}
 test("retained-queue-disclosure-removed-occurrence-refuses-actions") {val f=Fixture(11,12,13);val q=f.queueDialog();f.queue(11,13);q.choose(1);requireThat(AlertDialog.shown.last()===q,"removed occurrence opened enabled actions")}
 test("live-boundary-refresh-reuses-and-resets-mounted-rows") {val f=Fixture(11,12,13);val d=f.actions(1);val old=d.listView.children.toList();f.publish(12,11,13);states(d,listOf(true,false,true,true));f.publish(11,13,12);states(d,listOf(true,true,false,true));f.publish(11,12,13);states(d,listOf(true,true,true,true));requireThat(old.zip(d.listView.children).all {it.first===it.second},"fixture failed to recycle rows")}
 test("live-removal-disables-all-occurrence-actions") {val f=Fixture(11,12,13);val d=f.actions(1);f.publish(11,13);states(d,listOf(false,false,false,false));d.raw(2);requireThat(f.service.calls.isEmpty(),"removed mounted action dispatched")}
 test("dismissed-retained-action-refuses-dispatch") {val f=Fixture(11,12,13);val d=f.actions(1);d.dismiss();d.raw(2);requireThat(f.service.calls.isEmpty(),"dismissed disclosure dispatched")}
 test("retained-play-after-reorder-keeps-occurrence") {val f=Fixture(11,12,13);val d=f.actions(1);f.queue(12,11,13);d.raw(0);f.sent("queue_play",12)}
 test("retained-remove-after-reorder-keeps-occurrence") {val f=Fixture(11,12,13);val d=f.actions(1);f.queue(11,13,12);d.raw(3);f.sent("queue_remove",12)}
 test("disconnect-retires-action-dialog") {val f=Fixture(11,12,13);val d=f.actions(1);f.connection().onServiceDisconnected(android.content.ComponentName());requireThat(d.dismissed,"disconnected disclosure remains mounted");d.raw(2);requireThat(f.service.calls.isEmpty(),"disconnected action dispatched")}
 test("destroy-retires-action-dialog") {val f=Fixture(11,12,13);val d=f.actions(1);f.activity.onDestroy();requireThat(d.dismissed,"destroyed disclosure remains mounted");d.raw(2);requireThat(f.service.calls.isEmpty(),"destroyed action dispatched")}
 test("superseding-action-dialog-retires-old-callback") {val f=Fixture(11,12,13);val old=f.actions(1);val current=f.actions(0);requireThat(old.dismissed,"old disclosure remains mounted");old.raw(2);requireThat(f.service.calls.isEmpty(),"superseded action dispatched");current.choose(2);f.sent("queue_move",11,1)}
 test("disclosure-refresh-preserves-single-service-listener") {val f=Fixture(11,12,13);val listener=f.service.listener;f.actions(1);requireThat(f.service.listener===listener,"disclosure stole service listener");f.publish(12,11,13);requireThat(f.service.listener===listener,"refresh stole service listener")}
 test("empty-queue-clear-unchanged") {val f=Fixture();f.queueDialog().clear();f.sent("queue_clear")}
 test("first-raw-up-refused") {val f=Fixture(11,12,13);f.actions(0).raw(1);requireThat(f.service.calls.isEmpty(),"raw first up dispatched")}
 test("last-raw-down-refused") {val f=Fixture(11,12,13);f.actions(2).raw(2);requireThat(f.service.calls.isEmpty(),"raw last down dispatched")}
 test("after-dismiss-message-retained-callback-is-retired") {val f=Fixture(11,12,13);val d=f.actions(1);d.dismiss();AlertDialog.drainDismissals();d.raw(2);requireThat(f.service.calls.isEmpty(),"dismiss handler did not retire callback")}
 test("delayed-old-dismiss-does-not-clear-new-adapter") {val f=Fixture(11,12,13);val old=f.actions(1);val fresh=f.actions(0);AlertDialog.drainDismissals();f.publish(13,11,12);states(fresh,listOf(true,true,true,true));fresh.choose(1);f.sent("queue_move",11,0)}
 test("facade-dismiss-posts-captured-listener-after-show-state-closes") {val context=android.app.Activity();var calls=0;val d=AlertDialog.Builder(context).setItems(arrayOf("Synthetic")){_,_->}.create();requireThat(!d.isShowing,"created dialog already showing");d.setOnDismissListener {calls++};d.show();requireThat(d.isShowing,"shown dialog not showing");d.dismiss();requireThat(!d.isShowing && calls==0,"dismiss was not immediate-state/posted-listener");d.setOnDismissListener {calls+=100};AlertDialog.drainDismissals();requireThat(calls==1,"posted dismiss did not capture original listener")}
 test("after-destroy-message-retained-callback-is-retired") {val f=Fixture(11,12,13);val d=f.actions(1);f.activity.onDestroy();AlertDialog.drainDismissals();for(action in 0..3)d.raw(action);requireThat(f.service.calls.isEmpty(),"destroy handler did not retire callback")}
 test("after-supersession-message-old-callback-refuses-fresh-still-dispatches") {val f=Fixture(11,12,13);val old=f.actions(1);val fresh=f.actions(0);AlertDialog.drainDismissals();for(action in 0..3)old.raw(action);requireThat(f.service.calls.isEmpty(),"old callback revived after dismiss message");fresh.choose(2);f.sent("queue_move",11,1)}
 test("after-disconnect-message-retained-callback-is-retired") {val f=Fixture(11,12,13);val d=f.actions(1);f.connection().onServiceDisconnected(android.content.ComponentName());AlertDialog.drainDismissals();for(action in 0..3)d.raw(action);requireThat(f.service.calls.isEmpty(),"disconnected callback revived")}
 check(failures==0){"$failures queue dialog regressions"}
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=ROOT)
    parser.add_argument('--output', type=Path, help='Keep compiler/runtime logs and an exact receipt')
    args = parser.parse_args()
    production = args.source_root.resolve() / ACTIVITY
    source_bytes = production.read_bytes()
    java = java_home()
    env = dict(os.environ, JAVA_HOME=str(java), JAVA_TOOL_OPTIONS='-XX:ActiveProcessorCount=2')
    with tempfile.TemporaryDirectory(prefix='queue-dialog-', dir=os.environ.get('TMPDIR')) as tmp:
        work = Path(tmp)
        sources = []
        for name, text in {**FACADES, 'Probe.kt': PROBE, 'MainActivity.kt': source_bytes.decode()}.items():
            path = work / name
            path.write_text(text)
            sources.append(str(path))
        compile_argv = [kotlin_compiler(), *sources, '-nowarn', '-include-runtime', '-d', str(work / 'probe.jar')]
        compiled = subprocess.run(compile_argv, env=env, capture_output=True, text=True, timeout=120)
        print(compiled.stdout + compiled.stderr, end='')
        ran = None
        run_argv = [str(java / 'bin/java'), '-jar', str(work / 'probe.jar')]
        if compiled.returncode == 0:
            ran = subprocess.run(run_argv, env=env, capture_output=True, text=True, timeout=30)
            print(ran.stdout + ran.stderr, end='')
        receipt = dict(productionSha256=hashlib.sha256(source_bytes).hexdigest(),
                       testSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                       compileArgv=compile_argv, compileExit=compiled.returncode,
                       runArgv=run_argv, runExit=ran.returncode if ran else None,
                       passNames=[line[5:] for line in ran.stdout.splitlines() if line.startswith('PASS ')] if ran else [],
                       failures=[line[5:] for line in ran.stdout.splitlines() if line.startswith('FAIL ')] if ran else [])
        if args.output:
            args.output.mkdir(parents=True, exist_ok=True)
            (args.output / 'compiler.log').write_text(compiled.stdout + compiled.stderr)
            (args.output / 'runtime.log').write_text(ran.stdout + ran.stderr if ran else 'NOT RUN\n')
            for name in ('compiler.log', 'runtime.log'):
                receipt[name + 'Sha256'] = hashlib.sha256((args.output / name).read_bytes()).hexdigest()
            (args.output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        raise SystemExit(compiled.returncode or (ran.returncode if ran else 1))


if __name__ == '__main__':
    main()
