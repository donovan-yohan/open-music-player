package android.net
class Uri private constructor(private val value:String) {
 val scheme get()=value.substringBefore(":", "")
 override fun toString()=value
 companion object { @JvmStatic fun parse(s:String)=Uri(s); @JvmStatic fun fromFile(f:java.io.File)=Uri(f.toURI().toString()) }
}
