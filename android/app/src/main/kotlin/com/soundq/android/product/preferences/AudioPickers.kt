package com.soundq.android.product.preferences

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.*
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.soundq.android.AppGraph
import com.soundq.android.MainActivity
import com.soundq.android.data.AuthState

internal data class AudioPickerActions(val permission: () -> Unit, val file: () -> Unit, val folder: () -> Unit)

/** All files access is granted in system Settings; returning re-checks it (Android restarts the app when it changes). */
internal fun allFilesAccessIntents(packageName: String): List<Intent> = if (android.os.Build.VERSION.SDK_INT < 30) emptyList() else listOf(
    Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName")),
    Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION),
)
internal fun openAllFilesAccess(context: android.content.Context) {
    for (intent in allFilesAccessIntents(context.packageName)) {
        try { context.startActivity(intent); return } catch (_: android.content.ActivityNotFoundException) {}
    }
}

/** One captured user request. A replacement account, lock, close or stale callback cannot enroll a grant. */
@Composable internal fun rememberAudioPickers(
    graph: AppGraph,
    onFile: (Uri, Int, () -> Boolean) -> Unit,
    onFolder: (Uri, Int, () -> Boolean) -> Unit,
    onAccessChanged: () -> Unit,
): AudioPickerActions {
    val activity = androidx.activity.compose.LocalActivity.current as? MainActivity
    val context = androidx.compose.ui.platform.LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val alive = remember { java.util.concurrent.atomic.AtomicBoolean(true) }
    class Capture(val version: Long, val serial: Long)
    var sequence by remember { mutableLongStateOf(0) }
    var fileRequest by remember { mutableStateOf<Capture?>(null) }
    var folderRequest by remember { mutableStateOf<Capture?>(null) }
    val currentFile by rememberUpdatedState(onFile)
    val currentFolder by rememberUpdatedState(onFolder)
    val currentAccess by rememberUpdatedState(onAccessChanged)
    fun valid(captured: Capture) = alive.get() && sequence == captured.serial && graph.session.owns(captured.version) && graph.session.state.value !is AuthState.LocalLocked
    fun capture(): Capture? {
        if (!alive.get() || graph.session.state.value is AuthState.LocalLocked || fileRequest != null || folderRequest != null) return null
        return Capture(graph.session.version(), ++sequence)
    }
    val file = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val captured = fileRequest; fileRequest = null; activity?.localAudioPickerPending = false
        val data = result.data; val uri = data?.data
        if (captured != null && valid(captured) && result.resultCode == Activity.RESULT_OK && uri != null && uri.scheme == "content")
            currentFile(uri, data.flags) { valid(captured) }
    }
    val folder = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val captured = folderRequest; folderRequest = null; activity?.localAudioPickerPending = false
        val data = result.data; val uri = data?.data
        if (captured != null && valid(captured) && result.resultCode == Activity.RESULT_OK && uri != null && uri.scheme == "content")
            currentFolder(uri, data.flags) { valid(captured) }
    }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME && alive.get() && graph.session.state.value !is AuthState.LocalLocked) currentAccess() }
        lifecycle.addObserver(observer)
        onDispose { alive.set(false); sequence++; activity?.localAudioPickerPending = false; lifecycle.removeObserver(observer) }
    }
    return AudioPickerActions(
        permission = { if (capture() != null) openAllFilesAccess(context) },
        file = {
            capture()?.let { captured ->
                fileRequest = captured; activity?.localAudioPickerPending = true
                try { file.launch(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE); type = "audio/*"
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                }) } catch (_: Exception) { fileRequest = null; activity?.localAudioPickerPending = false }
            }
        },
        folder = {
            capture()?.let { captured ->
                folderRequest = captured; activity?.localAudioPickerPending = true
                try { folder.launch(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                }) } catch (_: Exception) { folderRequest = null; activity?.localAudioPickerPending = false }
            }
        },
    )
}
