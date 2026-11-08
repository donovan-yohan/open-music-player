package com.soundq.android.data

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.util.concurrent.CompletableFuture

/** Revocable capability; refresh preserves identity, account intents replace it. */
class AccountScope internal constructor(internal val owner: AccountSession, internal val epoch: Long, val accountId: String)
/** No dispatch consumes no credential and must never enter adoption or persistence. */
internal sealed interface RefreshExchange {
    class Rotated(val tokens: SecretTokens) : RefreshExchange
    data object Undispatched : RefreshExchange
}
class AccountSession(val endpoint: ApiEndpoint, private val store: SessionStore) {
    private val mutable = MutableStateFlow<AuthState>(AuthState.Restoring)
    val state: StateFlow<AuthState> = mutable
    private var epoch = 0L
    private val revisions = MutableStateFlow(0L)
    /** Capability identity changes even when equal auth states are conflated. */
    val scopeRevision: StateFlow<Long> = revisions
    private var tokens: SecretTokens? = null
    private var deviceAccount: String? = null
    private var deviceAdmission: Long? = null
    private var pending: SecretTokens? = null
    private var rejectedStore = false
    private var restoreAllowed = true
    private var expectedLocalAccount:String?=null
    // Availability comes only from the ordinary endpoint-bound decoder or a successful secure save.
    private var savedAccount:String?=null
    private var savedRecordRead=false
    @Synchronized internal fun expectLocalAccount(account:String?) {expectedLocalAccount=account}
    private var localLocked = false
    private var beforeLocalLock: AuthState = AuthState.Restoring
    private var promptSerial = 0L
    private var lockedFromEpoch:Long?=null
    private var resumedFromEpoch:Long?=null
    private var localResumeStart:Long?=null
    class LocalUnlockTicket internal constructor(internal val owner:AccountSession,internal val epoch:Long,internal val serial:Long)
    /** Lifecycle eligibility follows accepted identity, not a temporarily absent dispatch capability. */
    @Synchronized internal fun lockEnrolledLocal(account:String):Boolean {
        if(expectedLocalAccount!=account)return false
        val acceptedAccount=deviceAccount?:tokens?.accountId?:pending?.accountId
        val restoring=mutable.value is AuthState.Restoring || (mutable.value is AuthState.Pending&&restoration?.let {owns(it.first)}==true)
        if(if(acceptedAccount==null)!restoring else acceptedAccount!=account)return false
        return lockLocal()
    }
    /** Revokes all captured operations but retains this owner's accepted credentials and queue identity. */
    @Synchronized fun lockLocal(): Boolean {
        if(localLocked)return false
        if(mutable.value !is AuthState.SignedIn && mutable.value !is AuthState.DeviceOnly && mutable.value !is AuthState.Restoring && !(mutable.value is AuthState.Pending&&restoration?.let {owns(it.first)}==true) && !(mutable.value is AuthState.SaveRequired&&pending!=null))return false
        lockedFromEpoch=epoch;resumedFromEpoch=null
        if(localResumeStart==null)localResumeStart=epoch
        // An explicit online attempt must not become an automatic replay after device unlock.
        val explicitOnline=mutable.value is AuthState.Pending&&onlineRestore?.intent?.let {owns(it)}==true
        beforeLocalLock=if(mutable.value is AuthState.Pending) {
            if(explicitOnline)AuthState.SignedOut() else AuthState.Restoring
        } else mutable.value
        // A loaded credential without an entered exchange is not resumable remote authority.
        // Entered rotation still retains its existing adoption/save-on-lock ownership below.
        if(explicitOnline&&refresh?.first!=epoch&&pending==null){tokens=null;deviceAccount=null}
        localLocked=true;epoch++;promptSerial++
        mutable.value=AuthState.LocalLocked
        revisions.value=epoch
        return true
    }
    @Synchronized fun localUnlockTicket():LocalUnlockTicket? = if(localLocked)LocalUnlockTicket(this,epoch,++promptSerial)else null
    @Synchronized fun cancelLocalUnlock() {promptSerial++}
    @Synchronized fun completeLocalUnlock(ticket:LocalUnlockTicket):Boolean {
        if(!localLocked||refresh!=null||ticket.owner!==this||ticket.epoch!=epoch||ticket.serial!=promptSerial)return false
        resumedFromEpoch=lockedFromEpoch;lockedFromEpoch=null
        localLocked=false;epoch++;promptSerial++;mutable.value=beforeLocalLock
        revisions.value=epoch
        return true
    }
    @Synchronized fun resumesLocal(scope:AccountScope):Boolean = !localLocked&&resumedFromEpoch!=null&&scope.owner===this&&localResumeStart?.let {scope.epoch in it until epoch}==true&&(deviceAccount?:tokens?.accountId)==scope.accountId
    private var refresh: Pair<Long, CompletableFuture<Boolean>>? = null
    @Synchronized fun beginIntent(): Long {
        localLocked=false;promptSerial++;lockedFromEpoch=null;resumedFromEpoch=null
        localResumeStart=null
        epoch++; tokens = null; deviceAccount = null; deviceAdmission = null; pending = null; mutable.value = AuthState.Pending
        revisions.value=epoch
        return epoch
    }
    @Synchronized internal fun rotationCurrent(scope:AccountScope):Boolean = current(scope)||(localLocked&&scope.owner===this&&scope.epoch==lockedFromEpoch&&tokens?.accountId==scope.accountId)
    @Synchronized fun beginAuthentication():Long? = if(localLocked)null else beginIntent()
    @Synchronized fun version(): Long = epoch
    /** Atomic public-state/epoch observation; never grants dispatch authority. */
    @Synchronized internal fun observation()=Pair(mutable.value,epoch)
    @Synchronized fun owns(intent: Long) = intent == epoch
    private val storeLock = Any()
    fun accept(intent: Long, tokens: SecretTokens): Boolean {
        synchronized(this) {
            if (!owns(intent)) return false
            pending = tokens
            deviceAdmission = null
        }
        return retrySave(intent)
    }
    @Synchronized private fun saveCurrent(intent:Long)=owns(intent)||(localLocked&&lockedFromEpoch==intent)
    fun retrySave(intent: Long = version()): Boolean = synchronized(storeLock) {
        val accepted = synchronized(this) {
            if (!saveCurrent(intent)) return false
            if (rejectedStore) { tokens = null; pending = null; mutable.value = AuthState.SignedOut(SafeFailure.Reason.StoreRejected); return false }
            pending ?: return false
        }
        try { store.save(endpoint, accepted) } catch (_: Exception) {
            synchronized(this) { if (saveCurrent(intent) && pending === accepted) {if(localLocked)beforeLocalLock=AuthState.SaveRequired() else mutable.value = AuthState.SaveRequired()} }
            return false
        }
        synchronized(this) {
            if (!saveCurrent(intent) || pending !== accepted) return false
            tokens = accepted; pending = null; restoreAllowed = true
            savedAccount=accepted.accountId;savedRecordRead=true
            if(localLocked)beforeLocalLock=AuthState.SignedIn(accepted.accountId) else mutable.value = AuthState.SignedIn(accepted.accountId)
            true
        }
    }
    @Synchronized fun capture(): AccountScope? = if(localLocked)null else (deviceAccount ?: tokens?.accountId)?.let { AccountScope(this, epoch, it) }
    @Synchronized fun current(scope: AccountScope): Boolean = !localLocked && scope.owner === this && scope.epoch == epoch && (deviceAccount ?: tokens?.accountId) == scope.accountId
    @Synchronized fun remoteCurrent(scope: AccountScope): Boolean = current(scope) && deviceAccount == null && tokens != null
    @Synchronized fun checkRemote(scope: AccountScope) { if (!remoteCurrent(scope)) throw SafeFailure(SafeFailure.Reason.Retired) }
    @Synchronized fun access(scope: AccountScope): String { checkRemote(scope); return tokens!!.access }
    @Synchronized fun checkScope(scope: AccountScope) { if (!current(scope)) throw SafeFailure(SafeFailure.Reason.Retired) }
    @Synchronized fun failure(intent: Long, reason: SafeFailure.Reason, uncertain: Boolean = false) {
        if (owns(intent)) mutable.value = AuthState.SignedOut(reason, uncertain)
    }
    /** Local revocation has no disk/network work; the captured cleanup cannot retire a replacement. */
    class Retirement internal constructor(internal val intent: Long, internal val access: String?)
    @Synchronized fun revoke(): Retirement {
        val access = tokens?.access
        expectedLocalAccount=null
        localLocked=false;promptSerial++;lockedFromEpoch=null;resumedFromEpoch=null
        localResumeStart=null
        epoch++; tokens = null; deviceAccount = null; deviceAdmission = null; pending = null; restoreAllowed = false
        savedAccount=null;savedRecordRead=true
        mutable.value = AuthState.SignedOut()
        revisions.value=epoch
        return Retirement(epoch, access)
    }
    fun clearRetired(retirement: Retirement) = synchronized(storeLock) {
        val allowed = synchronized(this) { owns(retirement.intent) && !rejectedStore }
        if (!allowed) return@synchronized
        try { store.clear() } catch (_: Exception) {
            synchronized(this) { if (owns(retirement.intent)) { rejectedStore = true; mutable.value = AuthState.SignedOut(SafeFailure.Reason.StoreRejected) } }
        }
    }
    fun retire(): Long { val retired = revoke(); clearRetired(retired); return retired.intent }
    fun discardRejectedStore() {
        val retired = revoke()
        synchronized(storeLock) {
            if (!owns(retired.intent)) return
            try { store.clear(); synchronized(this) { if (owns(retired.intent)) { rejectedStore = false; mutable.value = AuthState.SignedOut() } } }
            catch (_: Exception) { synchronized(this) { if (owns(retired.intent)) mutable.value = AuthState.SignedOut(SafeFailure.Reason.StoreRejected) } }
        }
    }
    private var restoration: Pair<Long, CompletableFuture<Boolean>>? = null
    /** Explicit, one-shot authority from the rendered device-only session, never account-ID rebinding. */
    class OnlineRestoreTicket internal constructor(internal val scope:AccountScope,internal val deviceOnly:Boolean=true) {
        internal var entered=false
        internal var consumed=false
        internal var intent:Long?=null
    }
    private var onlineRestore:OnlineRestoreTicket?=null
    @Synchronized fun claimOnlineRestore(scope:AccountScope):OnlineRestoreTicket? {
        if(!current(scope)||mutable.value !is AuthState.DeviceOnly||!restoreAllowed||rejectedStore)return null
        if(onlineRestore?.let {!it.consumed&&it.scope.epoch==epoch}==true)return null
        return OnlineRestoreTicket(scope).also {onlineRestore=it}
    }
    @Synchronized fun canReconnectSaved():Boolean = restoreAllowed&&!rejectedStore&&savedAccount!=null&&mutable.value is AuthState.SignedOut
    @Synchronized fun claimSavedRestore():OnlineRestoreTicket? {
        if(!canReconnectSaved()||onlineRestore?.let {!it.consumed&&it.scope.epoch==epoch}==true)return null
        return OnlineRestoreTicket(AccountScope(this,epoch,savedAccount!!),deviceOnly=false).also {onlineRestore=it}
    }
    /** Job completion also calls this when cancellation happens before its body can run. */
    @Synchronized fun abandonOnlineRestore(ticket:OnlineRestoreTicket) {
        if(onlineRestore!==ticket||ticket.entered)return
        ticket.consumed=true;onlineRestore=null
    }
    fun restoreOnline(ticket:OnlineRestoreTicket,exchange:(AccountScope)->Boolean):Boolean {
        val intent:Long
        val flight:CompletableFuture<Boolean>
        synchronized(this) {
            if(onlineRestore!==ticket||ticket.consumed||ticket.entered||ticket.scope.owner!==this||ticket.scope.epoch!=epoch||!restoreAllowed||rejectedStore)return false
            if(ticket.deviceOnly) {
                if(!current(ticket.scope)||mutable.value !is AuthState.DeviceOnly)return false
            } else if(!canReconnectSaved()||savedAccount!=ticket.scope.accountId)return false
            ticket.entered=true;ticket.consumed=true
            intent=beginIntent();ticket.intent=intent;flight=CompletableFuture();restoration=intent to flight
        }
        return try {runRestoration(intent,flight,ticket.scope.accountId,exchange)} finally {
            synchronized(this) {if(onlineRestore===ticket)onlineRestore=null}
        }
    }
    /** Claim on the action thread, before scheduling disk IO. Retires any held online restoration. */
    @Synchronized fun canListenOffline():Boolean = deviceDownloadsAvailable()&&(!savedRecordRead||savedAccount!=null)
    private fun deviceDownloadsAvailable():Boolean {
        val restoring=restoration?.let {owns(it.first)}==true
        return restoreAllowed&&!rejectedStore&&(mutable.value is AuthState.Restoring||mutable.value is AuthState.SignedOut||
            (mutable.value is AuthState.Pending&&restoring&&pending==null))
    }
    @Synchronized internal fun claimDeviceDownloads(): Long? {
        if (!deviceDownloadsAvailable()) return null
        return beginIntent().also {deviceAdmission = it}
    }
    fun useDeviceDownloads(): Boolean = claimDeviceDownloads()?.let(::loadDeviceDownloads) ?: false
    /** Read the ordinary endpoint-bound encrypted record; no refresh, JWT inference or durable write. */
    internal fun loadDeviceDownloads(intent: Long): Boolean = synchronized(storeLock) {
        synchronized(this) {
            if (!owns(intent) || deviceAdmission != intent) return false
        }
        try {
            val saved = store.load(endpoint)
            synchronized(this) {require(expectedLocalAccount==null||saved?.accountId==expectedLocalAccount)}
            synchronized(this) {
                if (!owns(intent) || deviceAdmission != intent || !restoreAllowed || rejectedStore) return false
                deviceAdmission = null
                tokens = null; pending = null
                deviceAccount = saved?.accountId
                savedAccount=saved?.accountId;savedRecordRead=true
                mutable.value = if (saved == null) AuthState.SignedOut() else AuthState.DeviceOnly(saved.accountId)
                saved != null
            }
        } catch (_: Exception) {
            synchronized(this) { if (owns(intent)) { tokens = null; deviceAccount = null; rejectedStore = true; mutable.value = AuthState.SignedOut(SafeFailure.Reason.StoreRejected) } }
            false
        }
    }
    /** Claim before disk decode, shared by startup and explicit recovery; never hold a monitor over network. */
    fun restore(exchange: (AccountScope) -> Boolean): Boolean {
        val flight: CompletableFuture<Boolean>
        val intent: Long
        val winner: Boolean
        synchronized(this) {
            val existing = restoration
            if (existing != null && owns(existing.first)) {
                intent = existing.first; flight = existing.second; winner = false
            } else {
                if (!restoreAllowed || (mutable.value !is AuthState.Restoring && mutable.value !is AuthState.SignedOut)) return false
                intent = beginIntent(); flight = CompletableFuture(); restoration = intent to flight; winner = true
            }
        }
        if (!winner) return flight.get()
        return runRestoration(intent,flight,null,exchange)
    }
    /** Startup and explicit device exit share decode, exchange, secure-save and terminal cleanup. */
    private fun runRestoration(intent:Long,flight:CompletableFuture<Boolean>,account:String?,exchange:(AccountScope)->Boolean):Boolean {
        var restored = false
        try {
            val scope = loadRestored(intent,account)
            restored = scope != null && exchange(scope)
        } catch (_: Exception) { /* Explicit recovery remains available; no automatic replay. */ }
        finally {
            synchronized(this) {
                if (owns(intent) && mutable.value is AuthState.Pending) {
                    tokens = null; pending = null; mutable.value = AuthState.SignedOut()
                }
                if (restoration?.second === flight) restoration = null
            }
            flight.complete(restored)
        }
        return flight.get()
    }
    private fun loadRestored(intent: Long, account:String?=null): AccountScope? = synchronized(storeLock) {
        if (!owns(intent)) return null
        try {
            val saved = store.load(endpoint)
            synchronized(this) {require(expectedLocalAccount==null||saved?.accountId==expectedLocalAccount)}
            require(account==null||saved?.accountId==account)
            synchronized(this) {
                if (!owns(intent)) return null
                savedAccount=saved?.accountId;savedRecordRead=true
                if (saved != null) { tokens = saved; capture() }
                else { tokens = null; mutable.value = AuthState.SignedOut(); null }
            }
        } catch (_: Exception) {
            synchronized(this) { if (owns(intent)) { tokens = null; rejectedStore = true; mutable.value = AuthState.SignedOut(SafeFailure.Reason.StoreRejected) } }
            null
        }
    }
    /** One exchange across all API consumers; no uncertain exchange replay. */
    fun refresh(scope: AccountScope, attemptedAccess: String? = null, exchange: (String) -> SecretTokens): Boolean =
        refreshExchange(scope,attemptedAccess) { RefreshExchange.Rotated(exchange(it)) }
    internal fun refreshExchange(scope: AccountScope, attemptedAccess: String? = null, exchange: (String) -> RefreshExchange): Boolean {
        val flight: CompletableFuture<Boolean>
        val before: SecretTokens
        synchronized(this) {
            if (!remoteCurrent(scope)) return false
            before = tokens!!
            if (attemptedAccess != null && before.access != attemptedAccess) return true
            val existing = refresh
            if (existing != null && existing.first == epoch) {
                flight = existing.second
            } else {
                flight = CompletableFuture()
                refresh = epoch to flight
            }
            // Only the creator performs the exchange. Claim with a marker independent of the monitor.
        }
        val winner = synchronized(flight) {
            if (flight.isDone || claimed.contains(flight)) false else { claimed.add(flight); true }
        }
        if (!winner) return flight.get()
        try {
            checkScope(scope)
            when(val result = exchange(before.refresh)) {
                RefreshExchange.Undispatched -> flight.complete(false)
                is RefreshExchange.Rotated -> {
                    val rotated = result.tokens
                    val adopt = synchronized(this) {
                        if (!rotationCurrent(scope) || tokens !== before || rotated.accountId != scope.accountId) null
                        else {
                            pending = rotated
                            // Old refresh token has been consumed; do not keep using it when persistence fails.
                            tokens = null
                            epoch
                        }
                    }
                    flight.complete(adopt != null && retrySave(adopt))
                }
            }
        } catch (error: Exception) {
            synchronized(this) {
                if (rotationCurrent(scope)) {
                    epoch++; tokens = null; pending = null
                    localResumeStart=null
                    // Preserve durable bytes on uncertainty; no automatic refresh replay after local unlock.
                    val failed=AuthState.SignedOut(if (error is SafeFailure) error.reason else SafeFailure.Reason.Network, uncertain = true)
                    if(localLocked){beforeLocalLock=failed;lockedFromEpoch=null}else mutable.value=failed
                    revisions.value=epoch
                }
            }
            flight.complete(false)
        } finally {
            synchronized(this) { if (refresh?.second === flight) refresh = null }
            synchronized(flight) { claimed.remove(flight) }
        }
        return flight.get()
    }
    private val claimed = java.util.Collections.newSetFromMap(java.util.concurrent.ConcurrentHashMap<CompletableFuture<Boolean>, Boolean>())
}
