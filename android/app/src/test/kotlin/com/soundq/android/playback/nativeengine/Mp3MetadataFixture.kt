package com.soundq.android.playback.nativeengine

/** Parser grammar fixture only. Lease limits/lifetimes use the actual lease probe. */
internal fun mp3MetadataFixture(read:(Long,ByteArray,Int,Int)->Int,validate:()->Unit={}):OriginalMetadataReader = object:OriginalMetadataReader {
    override fun <T> metadataScan(scan:(OriginalMetadataBatch)->T):T {
        validate();var live=true;var steps=0
        val batch=object:OriginalMetadataBatch {
            override fun step(){check(live);if(++steps%4096==0)validate()}
            override fun readAt(position:Long,buffer:ByteArray,bufferOffset:Int,size:Int):Int {
                step();require(size in 1..16);return read(position,buffer,bufferOffset,size)
            }
        }
        try {val result=scan(batch);validate();return result}finally {live=false}
    }
}
