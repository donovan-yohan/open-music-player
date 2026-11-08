package com.soundq.android.product.timeline

import com.soundq.android.data.SafeFailure
import com.soundq.android.data.timeline.TrackWaveform
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Read state is separate from edit/Apply admission. Never expose transport exception text. */
internal sealed interface WaveformLoad {
    data object Waiting:WaveformLoad
    data object Loading:WaveformLoad
    data object Unavailable:WaveformLoad
    data class Loaded(val wave:TrackWaveform):WaveformLoad
    data class Failed(val message:String):WaveformLoad
}

internal suspend fun loadWaveform(ready:()->Boolean,fetch:()->TrackWaveform?):WaveformLoad {
    if(!ready())return WaveformLoad.Waiting
    return try {
        val wave=fetch()
        currentCoroutineContext().ensureActive()
        if(!ready() || wave==null)WaveformLoad.Waiting
        else if(wave.tiers.isEmpty())WaveformLoad.Unavailable
        else WaveformLoad.Loaded(wave)
    } catch(e:CancellationException){throw e}
    catch(e:SafeFailure){
        if(!ready()||e.reason==SafeFailure.Reason.Retired)WaveformLoad.Waiting
        else WaveformLoad.Failed(when(e.reason){
            SafeFailure.Reason.Network->"Could not reach server"
            SafeFailure.Reason.InvalidResponse->"Analysis response unavailable"
            SafeFailure.Reason.Refused->"Analysis request refused"
            SafeFailure.Reason.Endpoint->"Server configuration unavailable"
            else->"Could not load waveform"
        })
    } catch(_:Exception){
        currentCoroutineContext().ensureActive()
        if(ready())WaveformLoad.Failed("Could not load waveform") else WaveformLoad.Waiting
    }
}
