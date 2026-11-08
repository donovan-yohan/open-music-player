package com.soundq.android.localunlock

import com.soundq.android.data.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.*
import kotlinx.serialization.json.*

data class LocalUnlockState(val ready:Boolean=false,val enrolled:Boolean=false,val pending:Boolean=false,val error:String?=null)
class UnlockRequest internal constructor(internal val serial:Long,internal val version:Long,internal val account:String?,internal val enable:Boolean?,internal val ticket:AccountSession.LocalUnlockTicket?)
/** Non-secret enrollment metadata only. AccountSession remains the sole credential/capability owner. */
class LocalUnlock(private val file:File,private val session:AccountSession) {
    private val mutable=MutableStateFlow(LocalUnlockState())
    val state:StateFlow<LocalUnlockState> = mutable
    private var serial=0L
    private var enrolledAccount:String?=null
    private var rejected=false
    private var accepted:ByteArray?=null
    @Synchronized fun loadBeforeRestore() {
        try {
            require(!Files.isSymbolicLink(file.toPath()))
            if(Files.exists(file.toPath(),NOFOLLOW_LINKS)) {
                require(Files.isRegularFile(file.toPath(),NOFOLLOW_LINKS)&&file.length() in 1..4096)
                val raw=file.readBytes();val o=Json.parseToJsonElement(raw.toString(Charsets.UTF_8)).jsonObject
                require(o.keys==setOf("version","endpoint","account")&&o.getValue("version").jsonPrimitive.int==1)
                require(o.getValue("endpoint").jsonPrimitive.content==session.endpoint.identity)
                enrolledAccount=o.getValue("account").jsonPrimitive.content.also {require(it.isNotBlank()&&it.length<=1024)};accepted=raw
            }
        }catch(_:Exception){rejected=true}
        session.expectLocalAccount(enrolledAccount)
        if(enrolledAccount!=null||rejected)session.lockLocal()
        mutable.value=LocalUnlockState(true,enrolledAccount!=null,error=if(rejected)"Local unlock record is unreadable. Sign in with your password to replace it." else null)
    }
    @Synchronized fun requestEnrollment(enable:Boolean):UnlockRequest? {
        val s=session.capture() ?: return null
        if(!mutable.value.ready||mutable.value.pending||rejected)return null
        mutable.value=mutable.value.copy(pending=true,error=null)
        return UnlockRequest(++serial,session.version(),s.accountId,enable,null)
    }
    @Synchronized fun requestUnlock():UnlockRequest? {
        val ticket=session.localUnlockTicket() ?: return null
        if(rejected){session.cancelLocalUnlock();return null}
        mutable.value=mutable.value.copy(pending=true,error=null)
        return UnlockRequest(++serial,session.version(),null,null,ticket)
    }
    @Synchronized fun complete(request:UnlockRequest,authenticated:Boolean,valid:()->Boolean):Boolean {
        if(request.serial!=serial)return false
        if(request.version!=session.version()){mutable.value=mutable.value.copy(pending=false);return false}
        serial++
        if(!authenticated||!valid()) {mutable.value=mutable.value.copy(pending=false,error="Device unlock was canceled or unavailable. Try again or sign in with your password.");return false}
        if(request.ticket!=null) {
            val ok=session.completeLocalUnlock(request.ticket)
            mutable.value=mutable.value.copy(pending=false,error=if(ok)null else "Session changed. Try again.")
            return ok
        }
        val s=session.capture() ?: return false
        if(s.accountId!=request.account)return false
        return try {
            unchanged()
            if(request.enable==true) {
                val raw=buildJsonObject {put("version",1);put("endpoint",session.endpoint.identity);put("account",s.accountId)}.toString().toByteArray()
                file.parentFile!!.mkdirs();val temp=Files.createTempFile(file.parentFile!!.toPath(),"local-unlock-",".new")
                try {FileOutputStream(temp.toFile()).use {it.write(raw);it.fd.sync()};check(valid()&&session.current(s));Files.move(temp,file.toPath(),ATOMIC_MOVE,REPLACE_EXISTING)}finally {Files.deleteIfExists(temp)}
                accepted=raw;enrolledAccount=s.accountId
            }else {if(file.exists())check(file.delete());accepted=null;enrolledAccount=null}
            session.expectLocalAccount(enrolledAccount)
            mutable.value=LocalUnlockState(true,enrolledAccount!=null);true
        }catch(_:Exception){mutable.value=mutable.value.copy(pending=false,error="Local unlock could not be saved. The previous choice is unchanged.");false}
    }
    private fun unchanged() {
        require(!Files.isSymbolicLink(file.toPath()))
        val now=if(file.exists()){require(file.length() in 1..4096);file.readBytes()}else null
        check(if(now==null)accepted==null else accepted?.contentEquals(now)==true)
    }
    @Synchronized fun cancel() {serial++;session.cancelLocalUnlock();mutable.value=mutable.value.copy(pending=false)}
    @Synchronized fun lock():Boolean {
        val account=enrolledAccount ?: return false
        cancel()
        return session.lockEnrolledLocal(account)
    }
    /** Call after synchronous session revocation, before a replacement can enroll. */
    @Synchronized fun retire(version:Long) {
        cancel()
        if(!session.owns(version))return
        try {unchanged();if(file.exists())check(file.delete());enrolledAccount=null;accepted=null;rejected=false;mutable.value=LocalUnlockState(true)}
        catch(_:Exception){rejected=true;mutable.value=mutable.value.copy(error="Local unlock record could not be removed.")}
    }
    @Synchronized fun passwordFallback(version:Long=session.version(),valid:()->Boolean={true}):Long {
        if(!valid()||!session.owns(version))return session.version()
        val retired=session.revoke();cancel()
        // Explicit fallback authorizes discarding the rejected enrollment, not the encrypted session format.
        if(file.exists()&&!file.delete()){rejected=true;mutable.value=LocalUnlockState(true,error="Could not remove local unlock. Try sign out again.")}
        else {enrolledAccount=null;accepted=null;rejected=false;mutable.value=LocalUnlockState(true)}
        session.clearRetired(retired);return retired.intent
    }
}
