#!/usr/bin/env python3
"""Execute the player's exact seek/EOF reconciliation with declared deck facades."""
import argparse
from pathlib import Path
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--build', type=Path, required=True)
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
source = (root/'app/src/main/kotlin/com/soundq/android/playback/nativeengine/NativeCallbackPlayer.kt').read_text()
start = source.index('        val seekTarget = desiredSeek')
end = source.index('\n        if (eof) {', start)
body = source[start:end]
a.build.mkdir(parents=True, exist_ok=True)
fixture = '''
package callbackseek
object Player { const val STATE_ENDED=4;const val STATE_READY=3;const val STATE_BUFFERING=2 }
data class Deck(val positionMs:Long,val durationMs:Long,val eofCount:Long,val ready:Boolean=true)
class Probe(var desiredSeek:Long?,var submittedSeek:Long?,var eofCount:Long) {
 var position=0L;var playback=Player.STATE_READY;var acknowledgedSeekPosition:Long?=null
 fun seekNative(target:Long) { error("Unexpected pending seek $target") }
 fun observe(deck:Deck):Boolean {
 BODY
 return eof
 }
}
fun main() {
 check(Probe(3000,3000,0).observe(Deck(3000,3000,1))) { "Endpoint seek ACK swallowed new completion" }
 check(!Probe(0,0,0).observe(Deck(0,3000,1))) { "Backward seek must fence earlier EOF" }
 check(Probe(null,null,0).observe(Deck(3000,3000,1))) { "Natural EOF must complete" }
 check(!Probe(null,null,1).observe(Deck(3000,3000,1))) { "EOF must not duplicate" }
 println("PASS exact player seek/EOF reconciliation")
}
'''.replace('BODY', body)
kt = a.build/'CallbackSeekAck.kt'
kt.write_text(fixture)
jar = a.build/'probe.jar'
subprocess.run(['kotlinc','-J-Xmx512m','-J-XX:ActiveProcessorCount=1',str(kt),'-include-runtime','-d',str(jar)], check=True)
subprocess.run(['java','-XX:ActiveProcessorCount=1','-jar',str(jar)], check=True)
