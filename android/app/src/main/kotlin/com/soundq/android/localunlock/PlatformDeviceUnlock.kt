package com.soundq.android.localunlock

import android.app.KeyguardManager
import android.content.Context
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts

/** The OS owns every biometric/PIN/password surface. No credentials enter app fields. */
class PlatformDeviceUnlock(private val activity:ComponentActivity) {
    private var result:((Boolean)->Unit)?=null
    private var signal:CancellationSignal?=null
    private var serial=0L
    private var credentialSerial:Long?=null
    val active get()=result!=null
    val credentialActivityPending get()=credentialSerial!=null
    private val credential=activity.registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {value -> val captured=credentialSerial;credentialSerial=null;if(captured!=null)finish(captured,value.resultCode==android.app.Activity.RESULT_OK)}
    fun available():Boolean {
        val keyguard=activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if(!keyguard.isDeviceSecure)return false
        return if(Build.VERSION.SDK_INT>=30) {
            activity.getSystemService(BiometricManager::class.java).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.DEVICE_CREDENTIAL)==BiometricManager.BIOMETRIC_SUCCESS
        }else true
    }
    fun authenticate(reason:String,done:(Boolean)->Unit) {
        if(credentialSerial!=null){done(false);return}
        cancel()
        if(!available()){done(false);return}
        result=done
        val captured=++serial
        try {
            if(Build.VERSION.SDK_INT>=30) {
                val cancellation=CancellationSignal();signal=cancellation
                BiometricPrompt.Builder(activity).setTitle("Unlock SoundQ").setSubtitle(reason)
                    .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.DEVICE_CREDENTIAL)
                    .build().authenticate(cancellation,activity.mainExecutor,object:BiometricPrompt.AuthenticationCallback() {
                        override fun onAuthenticationSucceeded(value:BiometricPrompt.AuthenticationResult){finish(captured,true)}
                        override fun onAuthenticationError(code:Int,message:CharSequence){finish(captured,false)}
                    })
            }else {
                @Suppress("DEPRECATION") val intent=(activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).createConfirmDeviceCredentialIntent("Unlock SoundQ",reason)
                if(intent==null)finish(captured,false)else {credentialSerial=captured;credential.launch(intent)}
            }
        }catch(_:Exception){credentialSerial=null;finish(captured,false)}
    }
    private fun finish(captured:Long,success:Boolean) {if(captured!=serial)return;val callback=result;result=null;signal=null;callback?.invoke(success)}
    fun cancel() {serial++;val old=signal;signal=null;result=null;old?.cancel()}
}
