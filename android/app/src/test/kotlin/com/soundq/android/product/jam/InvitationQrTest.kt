package com.soundq.android.product.jam

import com.google.zxing.*
import com.google.zxing.common.*
import org.junit.Assert.*
import org.junit.Test

class InvitationQrTest {
    @Test fun locallyEncodedQrDecodesExactCapabilityWithoutQuery() {
        val link="https://guest.example.test/join#jamId=123e4567-e89b-42d3-a456-426614174000&invite=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        val matrix=invitationQr(link)
        val pixels=IntArray(matrix.width*matrix.height){i->if(matrix[i%matrix.width,i/matrix.width])0xff000000.toInt() else 0xffffffff.toInt()}
        val decoded=MultiFormatReader().decode(BinaryBitmap(HybridBinarizer(RGBLuminanceSource(matrix.width,matrix.height,pixels))))
        assertEquals(link,decoded.text)
        assertNull(java.net.URI(decoded.text).rawQuery)
    }
}
