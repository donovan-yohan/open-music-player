package com.soundq.android.playback.nativeengine
import android.media.MediaCodec
import com.soundq.android.data.device.*
import java.io.File
import java.util.concurrent.*
/** Intentionally RED on the retained whole-file preparer. The positive first-PCM
 * barrier is reached while tail/EOS remains held, not a scheduling guess. */
fun main(args:Array<String>) {
    val directory=File(args.single()).apply {mkdirs()}
    val access=AndroidAudioAccess();val pool=Executors.newSingleThreadExecutor()
    try {
        access.finish.countDown()
        val task=pool.submit<File>{PhoneAudioStage(access,directory).prepare("synthetic-provider",AudioContentProof(4,"synthetic-proof")){true}}
        check(MediaCodec.firstPcm.await(5,TimeUnit.SECONDS))
        check(task.isDone) {"DESIRED INVARIANT FAILED: first PCM exists, but source admission still waits for tail/EOS"}
    } finally {MediaCodec.eos.countDown();pool.shutdown();check(pool.awaitTermination(5,TimeUnit.SECONDS))}
}
