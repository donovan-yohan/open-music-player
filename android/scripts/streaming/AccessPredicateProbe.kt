package com.soundq.android.readprobe

import android.content.ContentResolver
import android.os.ParcelFileDescriptor
import android.system.Os
import com.soundq.android.playback.nativeengine.OriginalAudioReadLease

/** Exact extracted AndroidAudioAccess.openOriginal + production lease; platform calls are host facades. */
fun main() {
    var passed=0
    val failures=mutableListOf<String>()
    fun run(name:String,body:()->Unit) {
        try {body();passed++;println("PASS $name")}
        catch(error:Throwable) {failures+=name;println("FAIL $name: $error")}
        finally {Os.beforeRead=null}
    }
    fun fixture(body:(Platform,ContentResolver,OriginalAudioReadLease)->Unit) {
        val resolver=ContentResolver()
        val platform=Platform(resolver)
        platform.openOriginal("content://media/external/audio/media/1",{platform.liveChecks++;platform.live},{}).use {lease ->
            lease.beginOperation();platform.accessChecks=0;platform.liveChecks=0
            body(platform,resolver,lease)
        }
        check(ParcelFileDescriptor.open.isEmpty())
    }
    fun refused(lease:OriginalAudioReadLease,body:()->Unit) {
        val error=runCatching(body).exceptionOrNull()
        check(error is java.util.concurrent.CancellationException) {"Expected access/current retirement; got $error"}
        check(!lease.active && runCatching {lease.beginOperation()}.isFailure)
    }
    run("actualAdapterThousandsOfHeadersBoundExpensiveAccessChecks") {
        fixture {p,_,lease ->
            val result=lease.metadataScan {b ->
                val buffer=ByteArray(4)
                repeat(8193){b.readAt(0,buffer,0,4);check(buffer.contentEquals(byteArrayOf(1,2,3,4)))}
                42
            }
            println("observed adapter metadata reads=${lease.totalMetadataCalls} accessChecks=${p.accessChecks} cheapChecks=${p.liveChecks}")
            check(result==42 && lease.active && lease.totalMetadataCalls==8193L)
            check(p.liveChecks>=2*8193) {"Cheap liveness was not checked per structural request"}
            check(p.accessChecks in 4..8) {"Expected bounded full-access validation, got ${p.accessChecks} permission evaluations for 8193 headers"}
        }
    }
    for(kind in listOf("account","source"))run("actualAdapter${kind}RetiresWithinBatchBeforeNextRead") {
        fixture {p,_,lease ->
            val before=Os.reads
            refused(lease) {lease.metadataScan {b ->
                b.readAt(0,ByteArray(4),0,4)
                if(kind=="account")p.live=false else lease.revoke()
                b.readAt(0,ByteArray(4),0,4)
            }}
            check(Os.reads-before==1L)
        }
    }
    run("actualAdapterPermissionLostInsideBatchRefusesAtBoundary") {
        fixture {p,_,lease ->
            val before=Os.reads
            refused(lease) {lease.metadataScan {b ->
                repeat(4096){b.readAt(0,ByteArray(4),0,4)}
                p.allowed=false
                b.readAt(0,ByteArray(4),0,4)
            }}
            check(Os.reads-before==4096L)
        }
    }
    for(boundary in listOf("intermediate","final"))run("actualAdapterPermissionLostDuring${boundary}ValidationRefused") {
        fixture {p,r,lease ->
            val before=Os.reads
            var armed=false;var validated=false;var published=false
            r.beforeQuery={if(armed){validated=true;p.allowed=false}}
            refused(lease) {lease.metadataScan {b ->
                if(boundary=="intermediate") {
                    repeat(4096){b.readAt(0,ByteArray(4),0,4)}
                    armed=true;b.readAt(0,ByteArray(4),0,4)
                } else {b.readAt(0,ByteArray(4),0,4);armed=true}
                42
            }.also {published=true}}
            check(validated && !published)
            check(Os.reads-before==if(boundary=="intermediate")4096L else 1L)
        }
    }
    for(boundary in listOf("intermediate","final"))run("actualAdapterCurrentLostDuring${boundary}AccessValidationRefused") {
        fixture {p,_,lease ->
            val before=Os.reads;var armed=false;var validated=false
            p.accessObserved={if(armed){validated=true;p.live=false}}
            refused(lease) {lease.metadataScan {b ->
                if(boundary=="intermediate") {
                    repeat(4096){b.readAt(0,ByteArray(4),0,4)}
                    armed=true;b.readAt(0,ByteArray(4),0,4)
                } else {b.readAt(0,ByteArray(4),0,4);armed=true}
            }}
            check(validated)
            check(Os.reads-before==if(boundary=="intermediate")4096L else 1L)
        }
    }
    for(phase in listOf("before","after"))run("actualAdapterPayloadPermissionChecked${phase}Read") {
        fixture {p,_,lease ->
            val before=Os.reads
            if(phase=="before")p.allowed=false else Os.beforeRead={p.allowed=false}
            refused(lease) {lease.readAt(0,ByteArray(4),0,4)}
            check(Os.reads-before==if(phase=="before")0L else 1L)
        }
    }
    run("actualAdapterUnchangedPayloadChecksAccessOnEveryRead") {
        fixture {p,_,lease ->
            repeat(3){check(lease.readAt(0,ByteArray(4),0,4)==4)}
            check(p.accessChecks>=6 && lease.active)
        }
    }
    for(authority in listOf("media","test"))for(phase in listOf("before","after","unchanged","checkCurrent"))run("${authority}_normal_${phase}_current_retirement") {
        val p=Platform(ContentResolver())
        p.openOriginal("content://$authority/external/audio/media/1",{p.liveChecks++;p.live},{}).use {lease ->
            lease.beginOperation();p.accessChecks=0;p.liveChecks=0
            val before=Os.reads
            var retiredDuringAccess=false
            p.accessObserved={
                if(!retiredDuringAccess && (phase=="before" || phase=="checkCurrent" || phase=="after" && Os.reads>before)) {
                    retiredDuringAccess=true;p.live=false
                }
            }
            var published=false
            val error=runCatching {
                if(phase=="checkCurrent")lease.checkCurrent()
                else check(lease.readAt(0,ByteArray(4),0,4)==4)
                published=true
            }.exceptionOrNull()
            val reads=Os.reads-before
            if(phase=="unchanged")check(error==null && published && reads==1L && p.live)
            else {
                check(retiredDuringAccess)
                check(error is java.util.concurrent.CancellationException && !published) {"Retired current escaped: $error, published=$published"}
                check(reads==if(phase=="after")1L else 0L) {"Unexpected pread count=$reads"}
            }
        }
        check(ParcelFileDescriptor.open.isEmpty())
    }
    println("access-predicate controls passed=$passed failed=${failures.size}")
    check(failures.isEmpty()) {"Failed access-predicate controls: $failures"}
}
