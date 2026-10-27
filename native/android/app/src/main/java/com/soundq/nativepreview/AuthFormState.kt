package com.soundq.nativepreview

/** Ephemeral presentation/admission only. Rust owns authentication and credentials.
 * Never retain passwords (including confirmation) in this state or snapshots.
 */
internal class AuthFormState {
    enum class Mode { SIGN_IN, REGISTER }
    data class Ticket(val serial: Long, val presentation: Long, val epoch: Long, val account: Long)
    var mode = Mode.SIGN_IN
        private set
    var presentation = 1L
        private set
    private var serial = 0L
    var pending: Ticket? = null
        private set
    var errors: Map<String,String> = emptyMap()
        private set
    var failure: String? = null
        private set
    var publicationRetired = false
        private set
    var succeeded = false
        private set

    fun changeMode(value: Mode): Boolean {
        if (pending != null) return false
        retire(); mode = value
        return true
    }
    // Retirement is not remote cancellation: keep admission held until terminal.
    fun retire() { if(pending != null) publicationRetired = true; presentation++; errors = emptyMap(); failure = null; succeeded = false }
    fun edited() { retire() }
    fun owns(ticket: Ticket) = pending == ticket && presentation == ticket.presentation
    fun begin(username: String, email: String, password: String, confirmation: String, epoch: Long, account: Long): Ticket? {
        if (pending != null) return null
        errors = if (mode == Mode.REGISTER) validate(username,email,password,confirmation) else
            buildMap { if(email.isEmpty()) put("email","Please enter your email"); if(password.isEmpty()) put("password","Please enter a password") }
        failure = null; succeeded = false
        if (errors.isNotEmpty()) return null
        return Ticket(++serial,presentation,epoch,account).also {pending=it;publicationRetired=false}
    }
    fun finish(ticket: Ticket, ok: Boolean, code: String, epoch: Long, account: Long): Boolean {
        if (pending != ticket) return false
        val current = owns(ticket) && ticket.epoch == epoch && ticket.account == account
        pending = null
        if (!current) return false
        succeeded = ok
        failure = if(ok) null else feedback(code,mode)
        return true
    }
    companion object {
        // Match Flutter raw UTF-16/ASCII email rules, then Go/Rust wire bytes.
        // Trimming only at dispatch is deliberate; never trim a password.
        // Dart String.trim's Unicode White_Space plus BOM, identical on both adapters.
        fun trimmed(value: String) = value.trim { it in '\u0009'..'\u000D' || it in " \u0085\u00A0\u1680\u2028\u2029\u202F\u205F\u3000\uFEFF" || it in '\u2000'..'\u200A' }
        private val emailPattern = Regex("^[A-Za-z0-9_\\-.]+@([A-Za-z0-9_\\-]+\\.)+[A-Za-z0-9_\\-]{2,4}$")
        private val wireEmailPattern = Regex("^[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}$")
        fun validate(username: String, email: String, password: String, confirmation: String): Map<String,String> = buildMap {
            if(username.isEmpty()) put("username","Please enter a username")
            else if(username.length !in 3..50 || trimmed(username).toByteArray(Charsets.UTF_8).size !in 3..50) put("username","Username must be 3–50 characters and bytes")
            if(email.isEmpty()) put("email","Please enter your email")
            else if(!emailPattern.matches(email) || !wireEmailPattern.matches(trimmed(email)) || trimmed(email).toByteArray(Charsets.UTF_8).size > 254) put("email","Please enter a valid email")
            if(password.isEmpty()) put("password","Please enter a password")
            else if(password.length < 8 || password.toByteArray(Charsets.UTF_8).size !in 8..1024) put("password","Password must be at least 8 characters (up to 1024 bytes)")
            if(confirmation.isEmpty()) put("confirmation","Please confirm your password")
            else if(!password.toByteArray(Charsets.UTF_8).contentEquals(confirmation.toByteArray(Charsets.UTF_8))) put("confirmation","Passwords do not match")
        }
        fun feedback(code: String, mode: Mode): String = when(code) {
            "command_backpressure" -> "SoundQ is busy. Try again."
            "authentication_failed", "authentication_refused", "rate_limited", "invalid_credentials", "http_400", "http_401", "http_403", "http_409", "http_422" -> if(mode == Mode.REGISTER) "Account creation was refused. Check your details or sign in." else "Sign in was refused. Check your email and password."
            else -> if(mode == Mode.REGISTER) "Account creation is unconfirmed. Sign in to check before trying again." else "Sign in could not be confirmed. Try again."
        }
    }
}
