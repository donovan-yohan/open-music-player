package android.util

/** Logging boundary only; never a successful codec substitute. */
object Log {
    fun i(tag:String,message:String):Int=0
    fun e(tag:String,message:String,error:Throwable):Int=0
}
