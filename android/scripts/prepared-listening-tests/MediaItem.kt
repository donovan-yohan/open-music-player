package androidx.media3.common
import android.net.Uri
class MediaItem(val mediaId:String,val localConfiguration:LocalConfiguration?) {
 class LocalConfiguration(val uri:Uri)
 class Builder {private var id="";private var uri:Uri?=null;fun setMediaId(v:String)=apply{id=v};fun setUri(v:Uri)=apply{uri=v};fun build()=MediaItem(id,uri?.let(::LocalConfiguration))}
}
