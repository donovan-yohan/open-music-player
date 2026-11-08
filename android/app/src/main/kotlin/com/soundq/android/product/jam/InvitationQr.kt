package com.soundq.android.product.jam

import com.google.zxing.BarcodeFormat
import com.google.zxing.MultiFormatWriter
import com.google.zxing.EncodeHintType

/** Local QR data only. No invitation enters a renderer URL or log. */
internal fun invitationQr(link:String)=MultiFormatWriter().encode(link,BarcodeFormat.QR_CODE,256,256,mapOf(EncodeHintType.MARGIN to 4,EncodeHintType.CHARACTER_SET to "UTF-8"))
