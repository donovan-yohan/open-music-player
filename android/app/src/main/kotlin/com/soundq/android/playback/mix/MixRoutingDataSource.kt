package com.soundq.android.playback.mix

import androidx.media3.datasource.*
import android.net.Uri

/** Selects a loader, never an output or transport. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class MixRoutingDataSource(private val ordinary:DataSource,private val mixed:DataSource):DataSource {
    private var selected:DataSource?=null
    override fun addTransferListener(listener:TransferListener){ordinary.addTransferListener(listener);mixed.addTransferListener(listener)}
    override fun open(spec:DataSpec):Long {check(selected==null);selected=if(spec.uri.scheme=="soundqmix")mixed else ordinary;return selected!!.open(spec)}
    override fun read(buffer:ByteArray,offset:Int,length:Int)=selected!!.read(buffer,offset,length)
    override fun getUri():Uri?=selected?.uri
    override fun close(){try {selected?.close()}finally {selected=null}}
}
