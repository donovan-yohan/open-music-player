package com.soundq.android.product.offline

import com.soundq.android.data.offline.DeviceDownload
import com.soundq.android.data.offline.DownloadStatus
import java.math.BigDecimal
import java.math.RoundingMode

/** Rounded display only. Exact storage evidence stays in the details view. */
internal fun readableStorageSize(bytes:Long):String {
    require(bytes>=0)
    val (unit,divisor)=when {
        bytes >= (1L shl 30)->"GiB" to (1L shl 30)
        bytes >= (1L shl 20)->"MiB" to (1L shl 20)
        bytes >= (1L shl 10)->"KiB" to (1L shl 10)
        else->return "$bytes B"
    }
    val value=BigDecimal.valueOf(bytes).divide(BigDecimal.valueOf(divisor),1,RoundingMode.HALF_UP).stripTrailingZeros().toPlainString()
    return "$value $unit"
}

internal fun downloadStatus(row:DeviceDownload,compact:Boolean=true):String = when(row.status) {
    DownloadStatus.Downloading->if(compact)"Downloading · ${readableStorageSize(row.bytes)} / ${row.expected?.let(::readableStorageSize) ?: "—"}" else "Downloading · ${row.bytes} / ${row.expected ?: "unknown"} bytes"
    DownloadStatus.Complete->if(compact)"Available offline" else "Available offline · ${row.bytes} bytes"
    DownloadStatus.Cancelled->"Download cancelled"
    DownloadStatus.Failed->if(compact)"Download failed" else "Download failed or device copy unavailable. Check device storage, then retry."
    DownloadStatus.Interrupted->if(compact)"Interrupted" else "Download interrupted. Retry to start again."
}
