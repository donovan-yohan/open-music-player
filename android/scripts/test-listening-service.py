#!/usr/bin/env python3
"""Execute the actual service persistence and Like methods with the real logical Player.
Only wraps declarations; no production method body is translated or duplicated.
"""
from pathlib import Path
import argparse,hashlib,json
p=argparse.ArgumentParser();p.add_argument('--generate',type=Path,required=True);a=p.parse_args()
root=Path(__file__).resolve().parents[1]
s=(root/'app/src/main/kotlin/com/soundq/android/playback/SoundQLibraryService.kt').read_text()
def block(marker):
 b=s.index(marker);i=s.index('{',b)+1;depth=1
 while depth:
  depth+=(s[i]=='{')-(s[i]=='}');i+=1
 return s[b:i]
markers=['    private fun queueFile(','    private fun scheduleSave(','    private suspend fun readSavedQueue(','    private fun savedItems(','    private fun currentLikeTarget(','    private fun savedCompatible(']
methods='\n'.join(block(m) for m in markers)
source='''package com.soundq.android.playback.listening
import android.os.Bundle
import android.net.Uri
import androidx.media3.common.*
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import com.soundq.android.playback.*
import kotlinx.coroutines.*
import java.util.concurrent.ConcurrentHashMap
internal class ActualListeningConsumers(val graph:AppGraph,val player:Player,val grants:ConcurrentHashMap<String,MediaGrant>,val jobs:CoroutineScope) {
 var account=graph.session.capture();var restoring=false;var rejectedQueue=false;var saveJob:Job?=null
 private data class LikeTarget(val item:MediaItem,val view:LibraryRepository.LikeView)
 private var likeReadItem:MediaItem?=null
 private fun refreshLikeButton(){}
 fun save(){scheduleSave()}
 fun file()=queueFile(account!!)
 suspend fun read()=readSavedQueue(account!!)
 fun restore(saved:QueueSnapshot){player.pause();player.setMediaItems(savedItems(account!!,saved),saved.selected,saved.position)}
 fun likeTrack():Long?=currentLikeTarget()?.view?.track?.id?.value
'''+methods+'\n}\n'
a.generate.mkdir(parents=True,exist_ok=True);(a.generate/'ActualListeningConsumers.kt').write_text(source)
(a.generate/'source-blocks.json').write_text(json.dumps({m:hashlib.sha256(block(m).encode()).hexdigest() for m in markers},indent=2))
