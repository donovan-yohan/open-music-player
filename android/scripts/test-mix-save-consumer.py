#!/usr/bin/env python3
"""Compile the production Save button callback and enabled predicate with host boundary facades."""
from pathlib import Path
import argparse
p=argparse.ArgumentParser();p.add_argument('root',type=Path);p.add_argument('out',type=Path);a=p.parse_args()
s=(a.root/'android/app/src/main/kotlin/com/soundq/android/product/mix/MixScreen.kt').read_text()
start=s.index('SoundQButton("Save mix",')
# Existing callback contains balanced braces; scan the complete button invocation.
def end_call(start):
 depth=0;quoted=False;escaped=False
 for i in range(s.index('(',start),len(s)):
  c=s[i]
  if quoted:
   if escaped:escaped=False
   elif c=='\\':escaped=True
   elif c=='"':quoted=False
  elif c=='"':quoted=True
  elif c=='(':depth+=1
  elif c==')':
   depth-=1
   if depth==0:return i+1
button=s[start:end_call(start)]
admission=next(line.strip() for line in s.splitlines() if "fun writesAllowed()=" in line) if "fun writesAllowed()=" in s else "fun writesAllowed()=!busy&&!blockedWrite&&!exchangeWorking&&!route.owner.snapshot().blocksOtherWrites&&!route.owner.snapshot().pending"
a.out.mkdir(parents=True,exist_ok=True)
(a.out/'MixSaveConsumerTest.kt').write_text("""package com.soundq.android.mixconsumer
import org.junit.Assert.*
import org.junit.Test
import kotlinx.coroutines.*
class Saved(val id:String="saved",val clips:List<Int> = emptyList())
class Api {var writes=0;fun saveMix(scope:Any,plan:Saved,title:String,clips:List<Int>,valid:()->Boolean):Saved {writes++;return plan}}
class Graph {val api=Api()};class Model {val graph=Graph()}
class Exchange(val blocksOtherWrites:Boolean=true,val pending:Boolean=false)
class Owner {var state=Exchange();fun snapshot()=state}
class Route {val owner=Owner();fun current(c:Any)=true}
class Harness {
 val model=Model();val plan=Saved();var selected:Saved?=plan;var busy=false;var blockedWrite=false;var title="Draft";val scope:Any?=Any();var rows=listOf(plan)
 val exchange=Exchange();val exchangeState=exchange;var exchangeWorking=false;val route=Route();val capture=Any()
 var enabled=true;var action:()->Unit={}
 val valid={true}
 """+admission+"""
 fun select(saved:Saved){selected=saved}
 fun upsert(saved:Saved){rows=rows.map {if(it.id==saved.id)saved else it}}
 fun run(work:suspend ()->Unit){runBlocking {work()}}
 fun SoundQButton(label:String,onClick:()->Unit,enabled:Boolean){this.enabled=enabled;action=onClick}
 fun mount(){
"""+button+"""
 }
}
class MixSaveConsumerTest {
 @Test fun ordinarySaveStillAdmitsOneWrite(){val h=Harness();h.route.owner.state=Exchange(false);h.mount();assertTrue(h.enabled);h.action();assertEquals(1,h.model.graph.api.writes)}
 @Test fun uncertainImportDisablesExistingSaveButton(){val h=Harness();h.mount();assertFalse("Unresolved import must disable Save",h.enabled)}
 @Test fun retainedSaveCallbackCannotBypassUncertainImport(){val h=Harness();h.mount();h.action();assertEquals("Direct retained callback must not write",0,h.model.graph.api.writes)}
}
""")
