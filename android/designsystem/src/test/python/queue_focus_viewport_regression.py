#!/usr/bin/env python3
"""Run the production post-commit focus effect, without Gradle or a device.

This is a callback-boundary regression, NOT mounted Compose/layout acceptance.
Only platform layout/scroll/focus/frame primitives are modeled. The actual effect
body and QueueMoveIntent are read from production sources on every invocation.
Usage: python3 android/designsystem/src/test/python/queue_focus_viewport_regression.py
An optional OccurrenceQueue.kt path permits identical-fixture predecessor replay.
"""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

MODULE = Path(__file__).resolve().parents[3]
SOURCE = Path(sys.argv[1]) if len(sys.argv) > 1 else MODULE / "src/main/kotlin/com/soundq/designsystem/OccurrenceQueue.kt"
DRAG = MODULE / "src/main/kotlin/com/soundq/designsystem/QueueDrag.kt"
text = SOURCE.read_text()
start = text.index("    LaunchedEffect(order,focusAfter) {")
end = text.index("    val g=active", start)
effect = text[start:end]
print("production_sha256=" + hashlib.sha256(SOURCE.read_bytes()).hexdigest(), flush=True)
print("effect_sha256=" + hashlib.sha256(effect.encode()).hexdigest(), flush=True)

harness = r'''
package com.soundq.designsystem

import kotlin.coroutines.*

data class Item(val key:String,val index:Int,val offset:Int,val size:Int)
data class Layout(val visibleItemsInfo:List<Item>,val viewportStartOffset:Int,val viewportEndOffset:Int)
class ListState(var layoutInfo:Layout) {
    var origin=37
    val scrolls=mutableListOf<Int>()
    fun requestScrollToItem(index:Int,offset:Int) {check(index==0&&offset==37)}
    suspend fun scrollToItem(index:Int) {scrolls+=index;origin=1000+index}
}
class Requester {var requests=0;fun requestFocus(){requests++}}
var nextFrame:(()->Unit)?=null
suspend fun <T> withFrameNanos(block:(Long)->T):T {nextFrame?.also {nextFrame=null;it()};return block(0L)}
fun LaunchedEffect(vararg keys:Any?,block:suspend ()->Unit) {
    block.startCoroutine(object:Continuation<Unit> {
        override val context=EmptyCoroutineContext
        override fun resumeWith(result:kotlin.Result<Unit>){result.getOrThrow()}
    })
}
data class Result(val scrolls:List<Int>,val origin:Int,val focus:Int,val pending:Boolean)
fun exercise(layout:Layout,order:List<String> = listOf("b","c","a"),afterFrame:Layout?=null):Result {
    val list=ListState(layout)
    val requester=Requester()
    val focus=mapOf("a" to requester)
    var focusAfter:QueueMoveIntent?=QueueMoveIntent("a",listOf("a","b","c"),2)
    var focusViewport:Pair<Int,Int>?=0 to 37
    nextFrame=afterFrame?.let {updated->{list.layoutInfo=updated}}
__EFFECT__
    nextFrame=null
    return Result(list.scrolls,list.origin,requester.requests,focusAfter!=null)
}
fun main() {
    var failed=0
    fun case(name:String,test:()->Unit) {
        try {test();println("PASS $name")} catch(e:Throwable) {failed++;println("FAIL $name: ${e.message}")}
    }
    fun preserved(result:Result) {
        check(result.scrolls.isEmpty()&&result.origin==37){"fully visible moved row changed origin: $result"}
        check(result.focus==1&&!result.pending){"accepted move must restore focus exactly once: $result"}
    }
    fun revealed(result:Result) {
        check(result.scrolls==listOf(2)){"non-fully-visible moved occurrence must be reachable: $result"}
        check(result.focus==1&&!result.pending){"revealed moved row must restore focus: $result"}
    }
    fun layout(vararg items:Item,start:Int=0,end:Int=300)=Layout(items.toList(),start,end)
    case("all three rows visible: origin unchanged, focus restored") {
        preserved(exercise(layout(Item("b",0,0,80),Item("c",1,80,100),Item("a",2,180,90))))
    }
    case("exact viewport boundary is fully visible") {
        preserved(exercise(layout(Item("a",2,200,100))))
    }
    case("negative actual viewport start includes before-content padding") {
        preserved(exercise(layout(Item("a",2,-20,70),start=-20,end=250)))
    }
    case("partially clipped above") {revealed(exercise(layout(Item("a",2,-1,80))))}
    case("partially clipped below") {revealed(exercise(layout(Item("a",2,240,61))))}
    case("offscreen target still scrolls then focuses") {revealed(exercise(layout(Item("b",0,0,80))))}
    case("index alone cannot substitute a different occurrence") {revealed(exercise(layout(Item("other",2,0,80))))}
    case("old keyed index cannot certify new layout visibility") {revealed(exercise(layout(Item("a",0,0,80))))}
    case("sample committed layout after frame, not old keyed geometry") {
        preserved(exercise(layout(Item("a",0,0,80)),afterFrame=layout(Item("a",2,160,80))))
    }
    case("not-yet-committed order cannot focus or scroll") {
        val r=exercise(layout(Item("a",0,0,80)),order=listOf("a","b","c"))
        check(r.scrolls.isEmpty()&&r.focus==0&&r.pending){"uncommitted move was consumed: $r"}
    }
    case("different committed order retires focus without scroll") {
        val r=exercise(layout(Item("a",2,160,80)),order=listOf("c","b","a"))
        check(r.scrolls.isEmpty()&&r.focus==0&&!r.pending){"unrelated order adopted: $r"}
    }
    check(failed==0){"$failed viewport/focus cases failed"}
}
'''.replace("__EFFECT__", effect)

with tempfile.TemporaryDirectory(prefix="queue-focus-", dir=os.environ["TMPDIR"]) as directory:
    root = Path(directory)
    main = root / "QueueFocusRegression.kt"
    main.write_text(harness)
    jar = root / "regression.jar"
    subprocess.run(["kotlinc", "-J-XX:ActiveProcessorCount=1", "-Xbackend-threads=1", str(DRAG), str(main), "-include-runtime", "-d", str(jar)], check=True)
    subprocess.run(["java", "-XX:ActiveProcessorCount=1", "-jar", str(jar)], check=True)
