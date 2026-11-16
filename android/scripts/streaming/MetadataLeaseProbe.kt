package com.soundq.android.playback.nativeengine

import android.system.Os
import android.system.StructStat
import java.io.FileDescriptor
import java.nio.ByteBuffer

/** Actual lease/parser with explicit host syscall/route facades, NOT Android IO. */
internal fun main() {
    var tests=0
    val failures=mutableListOf<String>()
    fun run(name:String,body:()->Unit) {
        try {body();tests++;println("PASS $name")}
        catch(error:Throwable) {failures+=name;println("FAIL $name: $error")}
    }
    fun fixture(current:()->Boolean={true},route:()->Boolean={true}):OriginalAudioReadLease {
        val fd=FileDescriptor();val stamp=StructStat().apply {st_size=4_000_000_000L}
        val a=ByteArray(960).apply {this[0]=0xff.toByte();this[1]=0xfb.toByte();this[2]=0xe4.toByte()}
        val tag=a.copyOf().apply {"Xing".toByteArray().copyInto(this,36)}
        val entry=Os.Entry(ByteArray(0),stamp) {p,b,o,n ->
            repeat(n){i -> val at=p+i;b[o+i]=if(at<960)tag[at.toInt()]else a[((at-960)%960).toInt()]};n
        }
        Os.entries[fd]=entry;Os.paths["/synthetic/mp3"]=entry
        return OriginalAudioReadLease.borrow(fd,0,stamp.st_size,"/synthetic/mp3",current,routeCurrent=route).also {it.beginOperation()}
    }
    fun set(lease:OriginalAudioReadLease,name:String,value:Long) {
        lease.javaClass.getDeclaredField(name).apply {isAccessible=true;setLong(lease,value)}
    }
    fun cap(name:String)=OriginalAudioReadLease::class.java.getDeclaredField(name).run {isAccessible=true;getLong(null)}
    fun refused(lease:OriginalAudioReadLease,message:String,body:()->Unit) {
        val failure=runCatching(body).exceptionOrNull();check(failure!=null && failure.message!!.contains(message)) {"Expected $message; got $failure"}
        check(!lease.active);check(runCatching {lease.beginOperation()}.isFailure)
    }
    run("actualLeaseFreshObserved48kXingDeepResume") {
        fixture().use {lease ->
            val p=Mp3OriginalFrames(lease.length,lease::readAt,48000,2,lease)
            lease.beginOperation();p.seek(599L*48000);lease.beginOperation();p.seek(0);lease.beginOperation()
            val beforeBytes=lease.totalReadBytes;val beforeCalls=lease.totalReadCalls;val beforeStats=Os.stats
            val first=2018L*48000-48000
            p.seek(first);check(p.sampleFrame==first/1152*1152)
            val scanBytes=lease.totalReadBytes-beforeBytes;val scanCalls=lease.totalReadCalls-beforeCalls
            check(scanBytes==4*scanCalls && scanBytes<400000)
            check(Os.stats-beforeStats in 2..100) {"Batch validation was missing or per-header: ${Os.stats-beforeStats}"}
            val out=ByteBuffer.allocate(2048);check(p.read(out)==960);check(out[0]==0xff.toByte())
            println("observed deep scan bytes=$scanBytes calls=$scanCalls fullStatChecks=${Os.stats-beforeStats}")
        }
    }
    run("actualLeaseMetadataCapsRetainExisting24HourMp3AddressRange") {
        fixture().use {lease ->
            val p=Mp3OriginalFrames(lease.length,lease::readAt,48000,2,lease)
            lease.beginOperation()
            val first=86400L*48000-48000
            p.seek(first);check(p.sampleFrame==first/1152*1152)
            check(lease.totalMetadataCalls>3_500_000)
            check(lease.totalReadBytes==lease.totalMetadataBytes)
        }
    }
    run("metadataBatchDoesNotQuerySourcePerFourByteHeader") {
        var routeChecks=0
        fixture(route={routeChecks++;true}).use {lease ->
            routeChecks=0
            lease.metadataScan {b ->repeat(4096){b.readAt(0,ByteArray(4),0,4)};check(routeChecks==1);b.step();check(routeChecks==2)}
            check(routeChecks==3)
        }
    }
    for(mode in listOf("route","named","descriptor"))run("${mode}MutationInsideBatchRefusedBeforePublication") {
        var valid=true
        fixture(route={valid}).use {lease ->
            var published=false
            refused(lease,"changed") {
                lease.metadataScan {b ->
                    b.readAt(0,ByteArray(4),0,4)
                    when(mode) {
                        "route"->valid=false
                        "named"->Os.paths[lease.path]=Os.Entry(ByteArray(0),StructStat().apply {st_ino=99})
                        else->Os.paths.getValue(lease.path).stat.st_size--
                    }
                    // No full route/stat check until the bounded boundary, by contract.
                    repeat(4096){b.step()}
                    published=true
                }
            }
            check(!published)
        }
    }
    run("routeReplacementImmediatelyBeforeScanReturnCannotPublishCheckpoint") {
        var valid=true
        fixture(route={valid}).use {lease ->
            val parser=Mp3OriginalFrames(lease.length,lease::readAt,48000,2,lease)
            lease.beginOperation();var reads=0
            Os.beforeRead={if(++reads==50)valid=false}
            try {
                refused(lease,"changed") {parser.seek(49L*1152)}
                check(runCatching {parser.seek(0)}.isFailure)
                check(runCatching {parser.read(ByteBuffer.allocate(2048))}.isFailure)
                check(runCatching {parser.sampleFrame}.isFailure)
                val maps=parser.javaClass.declaredFields.filter {Map::class.java.isAssignableFrom(it.type)}
                check(maps.all {it.isAccessible=true;(it.get(parser) as Map<*,*>).isEmpty()})
            } finally {Os.beforeRead=null}
        }
    }
    run("cheapRevocationAbortsInsideBatchWithoutNextRead") {
        var current=true
        fixture(current={current}).use {lease ->
            refused(lease,"retired") {lease.metadataScan {b ->b.step();current=false;b.step()}}
        }
    }
    for(kind in listOf("lexical","operation","thread"))run("${kind}StaleCapabilityIsSticky") {
        fixture().use {lease ->
            lateinit var saved:OriginalMetadataBatch
            if(kind=="thread") {
                refused(lease,"Original source read failed") {
                    lease.metadataScan {b ->
                        val t=Thread {check(runCatching {b.step()}.isFailure)};t.start();t.join()
                    }
                }
            } else {
                lease.metadataScan {saved=it;it.step()}
                if(kind=="operation")lease.beginOperation()
                refused(lease,"Stale metadata capability") {saved.step()}
            }
        }
    }
    for((field,limit,message) in listOf(
        Triple("metadataBytes","MAX_METADATA_BYTES","byte budget"),
        Triple("metadataCalls","MAX_METADATA_CALLS","call budget"),
        Triple("metadataSteps","MAX_METADATA_STEPS","work budget")
    ))run("independent${field}ExhaustionDoesNotResetAtBatchOrScan") {
        fixture().use {lease ->
            lease.metadataScan {it.step()}
            // Precharge the real private counter, not a smaller production cap.
            // Cross a genuine 4096-step validation boundary before exhaustion;
            // other counters remain independently far below their own limits.
            set(lease,field,cap(limit)-5000*(if(field=="metadataBytes")4L else 1L))
            refused(lease,message) {lease.metadataScan {b ->repeat(5001) {
                if(field=="metadataSteps")b.step()else b.readAt(0,ByteArray(4),0,4)
            }}}
        }
    }
    run("metadataSharesOperationDeadline") {
        fixture().use {lease ->set(lease,"deadline",0);refused(lease,"deadline") {lease.metadataScan {it.step()}}}
    }
    run("deadlineExpiringDuringFinalFullValidationCannotPublishResult") {
        lateinit var source:OriginalAudioReadLease
        var armed=false
        source=fixture(route={if(armed)set(source,"deadline",0);true})
        source.use {lease ->refused(lease,"deadline") {lease.metadataScan {armed=true;42}}}
    }
    for(kind in listOf("revoke","current"))run("${kind}DuringFinalFullValidationCannotPublishCheckpoint") {
        lateinit var source:OriginalAudioReadLease
        var live=true;var armed=false;var routeChecks=0
        source=fixture(current={live},route={
            if(armed && ++routeChecks==2) {
                if(kind=="revoke")source.revoke()else live=false
            }
            true // The captured route is genuinely unchanged despite retirement.
        })
        source.use {lease ->
            val parser=Mp3OriginalFrames(lease.length,lease::readAt,48000,2,lease)
            lease.beginOperation();armed=true
            refused(lease,"retired") {parser.seek(49L*1152)}
            check(routeChecks==2) {"Did not reach the final route validation: $routeChecks"}
            check(runCatching {parser.sampleFrame}.isFailure)
            check(runCatching {parser.seek(0)}.isFailure)
            check(runCatching {parser.read(ByteBuffer.allocate(2048))}.isFailure)
            val maps=parser.javaClass.declaredFields.filter {Map::class.java.isAssignableFrom(it.type)}
            check(maps.isNotEmpty() && maps.all {it.isAccessible=true;(it.get(parser) as Map<*,*>).isEmpty()})
        }
    }
    for(kind in listOf("revoke","current","deadline"))run("${kind}DuringIntermediateFullValidationPreventsNextPread") {
        lateinit var source:OriginalAudioReadLease
        var live=true;var armed=false;var routeChecks=0;var reads=0
        source=fixture(current={live},route={
            routeChecks++
            if(armed)when(kind) {
                "revoke"->source.revoke()
                "current"->live=false
                else->set(source,"deadline",0)
            }
            true
        })
        source.use {lease ->
            routeChecks=0;Os.beforeRead={reads++}
            try {
                refused(lease,if(kind=="deadline")"deadline" else "retired") {
                    lease.metadataScan {b ->
                        val buffer=ByteArray(4)
                        repeat(4096){b.readAt(0,buffer,0,4)}
                        check(routeChecks==1 && reads==4096)
                        armed=true
                        b.readAt(0,buffer,0,4)
                    }
                }
                check(routeChecks==2) {"Did not reach intermediate validation: $routeChecks"}
                check(reads==4096) {"Post-validation $kind admitted next pread: $reads"}
                check(lease.totalMetadataCalls==4096L && lease.totalReadCalls==4096L)
                check(lease.totalMetadataBytes==16384L && lease.totalReadBytes==16384L)
            } finally {Os.beforeRead=null}
        }
    }
    run("unchangedRouteSurvivesIntermediateAndFinalFullValidation") {
        var routeChecks=0;var reads=0
        fixture(route={routeChecks++;true}).use {lease ->
            routeChecks=0;Os.beforeRead={reads++}
            try {
                val result=lease.metadataScan {b ->
                    val buffer=ByteArray(4)
                    repeat(4097){b.readAt(0,buffer,0,4);check(buffer[0]==0xff.toByte())}
                    check(routeChecks==2);42
                }
                check(result==42 && routeChecks==3 && reads==4097 && lease.active)
                check(lease.totalMetadataCalls==4097L && lease.totalReadCalls==4097L)
                check(lease.totalMetadataBytes==16388L && lease.totalReadBytes==16388L)
            } finally {Os.beforeRead=null}
        }
    }
    run("operationCannotRenewInsideMetadataScan") {
        fixture().use {lease ->refused(lease,"Cannot renew") {lease.metadataScan {lease.beginOperation()}}}
    }
    run("structuralReadCannotBecomePayloadRead") {
        fixture().use {lease ->refused(lease,"") {lease.metadataScan {it.readAt(0,ByteArray(65536),0,65536)}}}
    }
    run("normalPayloadByteBudgetUnchangedAfterSuccessfulMetadataWork") {
        fixture().use {lease ->
            lease.metadataScan {it.readAt(0,ByteArray(4),0,4)}
            val buffer=ByteArray(65536)
            repeat(512){lease.readAt(it*65536L,buffer,0,buffer.size)}
            refused(lease,"Original decoder read budget") {lease.readAt(0,buffer,0,buffer.size)}
        }
    }
    run("normalPayloadCallBudgetUnchanged") {
        fixture().use {lease ->repeat(8192){lease.readAt(0,ByteArray(1),0,1)};refused(lease,"call budget") {lease.readAt(0,ByteArray(1),0,1)}}
    }
    run("aggregateCountersIncludeMetadataAndPayloadExactly") {
        fixture().use {lease ->
            lease.metadataScan {it.readAt(0,ByteArray(4),0,4)};lease.readAt(0,ByteArray(7),0,7)
            check(lease.totalReadBytes==11L && lease.totalReadCalls==2L)
            check(lease.totalMetadataBytes==4L && lease.totalMetadataCalls==1L)
        }
    }
    println("PASS metadata actual-source controls: $tests")
    check(failures.isEmpty()) {"Failed metadata controls: $failures"}
}
