#!/usr/bin/env python3
"""Actual owner helper and Compose SaveableStateRegistry. Not a mounted ProductApp test."""
import argparse, os, subprocess, zipfile
from pathlib import Path
from host_probe import directory, gradle_cache, kotlin_plugin, android_jar
p=argparse.ArgumentParser();p.add_argument('--out',required=True,type=Path);a=p.parse_args()
o=a.out;o.mkdir(parents=True,exist_ok=True)
r=Path(__file__).resolve().parents[1]
cache=gradle_cache()/'modules-2/files-2.1'
aar=next(cache.glob('androidx.compose.runtime/runtime-saveable-android/1.12.1/*/*.aar'))
with zipfile.ZipFile(aar) as z:(o/'saveable.jar').write_bytes(z.read('classes.jar'))
runtime=next(cache.glob('androidx.compose.runtime/runtime-android/1.12.1/*/*.aar'))
with zipfile.ZipFile(runtime) as z:(o/'runtime.jar').write_bytes(z.read('classes.jar'))
cp=os.pathsep.join(map(str,[o/'saveable.jar',o/'runtime.jar',*cache.glob('androidx.collection/collection-jvm/*/*/*.jar'),*cache.glob('org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.10.2/*/*.jar')]))
(o/'Check.kt').write_text('''package com.soundq.android.product.acquisition
import androidx.compose.runtime.saveable.SaveableStateRegistry
fun main() {
 val a=PlaylistSavedOwner("https://one.test/api/v1","A")
 val b=PlaylistSavedOwner("https://one.test/api/v1","B")
 val server=PlaylistSavedOwner("https://two.test/api/v1","A")
 val job="123e4567-e89b-12d3-a456-426614174092"
 val draft=listOf("private URL","private name","private description","42","1")
 val registry=SaveableStateRegistry(null){true}
 registry.registerProvider(a.providerKey){draft}
 registry.registerProvider("return-job"){a.saveJob(job)}
 val saved=registry.performSave()
 for(owner in listOf(b,server)) {
   val restored=SaveableStateRegistry(saved){true}
   check(restored.consumeRestored(owner.providerKey)==null){"another owner consumed the draft"}
   @Suppress("UNCHECKED_CAST") val payload=restored.consumeRestored("return-job") as List<String>
   check(owner.restoreJob(payload)==null){"another owner resumed the exact job"}
 }
 val restored=SaveableStateRegistry(saved){true}
 check(restored.consumeRestored(a.copy().providerKey)==draft)
 @Suppress("UNCHECKED_CAST") val payload=restored.consumeRestored("return-job") as List<String>
 check(a.copy().restoreJob(payload)==job)
 for(invalid in listOf(emptyList(),listOf(job),payload+"extra",payload.toMutableList().also{it[0]="2"},payload.toMutableList().also{it[3]="not-a-job"},payload.toMutableList().also{it[3]="00000000-0000-0000-0000-000000000000"}))check(a.restoreJob(invalid)==null)
 check(PlaylistSavedOwner("a:b","c").providerKey!=PlaylistSavedOwner("a","b:c").providerKey)
 println("PASS real SaveableStateRegistry owner namespace, same-owner full draft/exact job, account/server refusal, version and malformed job refusal")
}
''')
src=r/'app/src/main/kotlin/com/soundq/android/product/acquisition/PlaylistSavedOwner.kt'
compile=subprocess.run(['kotlinc',str(src),str(o/'Check.kt'),'-cp',str(o/'saveable.jar'),'-include-runtime','-d',str(o/'check.jar')],capture_output=True,text=True)
(o/'compile.log').write_text(compile.stdout+compile.stderr);print(compile.stdout+compile.stderr);assert compile.returncode==0
run=subprocess.run(['java','-cp',str(o/'check.jar')+os.pathsep+cp,'com.soundq.android.product.acquisition.CheckKt'],capture_output=True,text=True)
(o/'runtime.log').write_text(run.stdout+run.stderr);print(run.stdout+run.stderr);raise SystemExit(run.returncode)
