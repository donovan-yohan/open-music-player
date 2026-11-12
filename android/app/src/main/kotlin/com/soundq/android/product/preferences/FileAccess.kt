package com.soundq.android.product.preferences

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.runtime.*
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.soundq.android.AppGraph
import com.soundq.android.data.AuthState

/** All files access is granted in system Settings; returning re-checks it (Android restarts the app when it changes).
 * Before Android 11 the equivalent storage permission lives on the app's own settings page. */
internal fun allFilesAccessIntents(packageName: String): List<Intent> = if (android.os.Build.VERSION.SDK_INT < 30)
    listOf(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
    else listOf(
        Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName")),
        Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION),
    )
internal fun openAllFilesAccess(context: android.content.Context) {
    for (intent in allFilesAccessIntents(context.packageName)) {
        try { context.startActivity(intent); return } catch (_: android.content.ActivityNotFoundException) {}
    }
}

/** The single phone-audio access action. [onResume] runs on every resume while mounted and unlocked, so the caller
 * can rescan when access changed outside the app. A locked or retired screen opens nothing. */
@Composable internal fun rememberFileAccess(graph: AppGraph, onResume: () -> Unit): () -> Unit {
    val context = androidx.compose.ui.platform.LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val alive = remember { java.util.concurrent.atomic.AtomicBoolean(true) }
    val currentResume by rememberUpdatedState(onResume)
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME && alive.get() && graph.session.state.value !is AuthState.LocalLocked) currentResume() }
        lifecycle.addObserver(observer)
        onDispose { alive.set(false); lifecycle.removeObserver(observer) }
    }
    return { if (alive.get() && graph.session.state.value !is AuthState.LocalLocked) openAllFilesAccess(context) }
}
