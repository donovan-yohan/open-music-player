#!/usr/bin/env python3
"""Compile exact duration helper bodies and Jam's Text expression, not mounted UI.

Only helper visibility/names are adapted to share a dependency-free host namespace.
The app's full real-caller JUnit test remains the consuming integration gate.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
PRODUCT=ROOT/'app/src/main/kotlin/com/soundq/android/product'
CALLERS=[('QueuePanel.kt','queueTime','queueTime'),
    ('playlists/PlaylistDetailScreen.kt','mixTime','mixTime'),
    ('timeline/StackedTimeline.kt','timelineTime','timelineTime'),
    ('trackdetails/TrackDetailsSheet.kt','detailsDuration','detailsDuration'),
    ('discovery/DiscoverScreen.kt','duration','discoveryDuration'),
    ('catalog/CatalogScreen.kt','duration','catalogDuration')]

def helper(source,name):
    start=source.index('fun '+name+'(')
    end=source.index('\n',start)
    line=source[start:end]
    # Block helpers can be multiline; interpolation braces are balanced too.
    opening=line.find('{')
    if opening>=0 and (line.find('=')<0 or opening<line.find('=')):
        i=start+opening;depth=1;i+=1
        while depth:
            depth+=(source[i]=='{')-(source[i]=='}');i+=1
        return source[start:i]
    return line

bodies=[]
for path,name,alias in CALLERS:
    body=helper((PRODUCT/path).read_text(),name)
    bodies.append(body.replace('fun '+name+'(','fun '+alias+'(',1))
jam=(PRODUCT/'jam/JamHostPanel.kt').read_text()
line=next(line for line in jam.splitlines() if 'if(source.durationMs>0)Text(' in line)
expression=line.split('Text(',1)[1].split(',style=',1)[0]
bodies.append('data class JamSource(val durationMs:Long)\nfun jamTime(ms:Long):String {val source=JamSource(ms);return '+expression+'}')
main='''
fun main() {
    val callers=listOf<Pair<String,(Long)->String>>("queue" to ::queueTime,"playlist" to ::mixTime,
        "timeline" to ::timelineTime,"details" to {detailsDuration(it)},"discovery" to ::discoveryDuration,
        "catalog" to {catalogDuration(it)},"jam" to ::jamTime)
    var checks=0
    for((ms,expected) in listOf(3599999L to "59:59",3600000L to "01:00:00",12372000L to "03:26:12",
        360000000L to "100:00:00",Long.MAX_VALUE to "2562047788015:12:55")) {
        for((name,format) in callers) {check(format(ms)==expected){"$name($ms): ${format(ms)} != $expected"};checks++}
    }
    check(detailsDuration(null)=="Not available");checks++
    check(detailsDuration(-1)=="Not available");checks++
    check(discoveryDuration(-1)=="Duration unavailable");checks++
    check(catalogDuration(null)=="Duration unavailable");checks++
    check(catalogDuration(0)=="Duration unavailable");checks++
    // Preserve existing invalid/sentinel conventions at the callers as well as the shared formatter.
    check(queueTime(-60000)=="-1:00");checks++
    check(mixTime(-60000)=="-1:00");checks++
    check(timelineTime(-60000)=="0:00");checks++
    check(catalogDuration(-60000)=="-1:00");checks++
    println("PASS $checks exact production duration helper/expression assertions (not mounted callers)")
}
'''
with tempfile.TemporaryDirectory(prefix='soundq-long-clocks-',dir=os.environ['TMPDIR']) as temp:
    work=Path(temp)
    source=work/'Callers.kt'
    source.write_text('import com.soundq.designsystem.formatSongTime\n'+'\n'.join(bodies)+'\n'+main)
    jar=work/'clocks.jar'
    subprocess.run(['kotlinc','-J-Xmx512m','-J-XX:ActiveProcessorCount=1',str(ROOT/'designsystem/src/main/kotlin/com/soundq/designsystem/CompactSongTiming.kt'),str(source),'-include-runtime','-d',str(jar)],check=True)
    subprocess.run(['java','-Xmx256m','-XX:ActiveProcessorCount=1','-jar',str(jar)],check=True)
