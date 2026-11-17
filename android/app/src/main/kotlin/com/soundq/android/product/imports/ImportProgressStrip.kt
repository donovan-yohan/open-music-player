package com.soundq.android.product.imports

import androidx.compose.foundation.layout.*
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.soundq.android.data.imports.ImportBatchProgress
import com.soundq.android.product.ProductViewModel
import com.soundq.designsystem.*

/** Root app lifetime, deliberately independent of tabs, ImportView and playback ticks. */
@Composable internal fun ImportProgressLifecycle(model:ProductViewModel) {
    val lifecycle=LocalLifecycleOwner.current.lifecycle
    DisposableEffect(model,lifecycle) {
        fun sync() {model.importProgressForeground(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))}
        val observer=LifecycleEventObserver {_,_->sync()}
        lifecycle.addObserver(observer);sync()
        onDispose {model.importProgressForeground(false);lifecycle.removeObserver(observer)}
    }
}

@Composable internal fun ImportProgressStrip(model:ProductViewModel,onOpen:()->Unit) {
    val progress by model.importProgress.collectAsStateWithLifecycle()
    val captured=progress?.takeIf(model::ownsImportProgress) ?: return
    ImportProgressContent(captured,
        {if(model.ownsImportProgress(captured))onOpen()},
        {model.dismissImportProgress(captured)})
}

/** No wrapper, spacer or reserved height is emitted at idle. */
@Composable internal fun ImportProgressContent(progress:ImportBatchProgress?,onOpen:()->Unit,onDismiss:()->Unit) {
    if(progress==null)return
    Row(Modifier.fillMaxWidth().heightIn(min=48.dp).padding(start=SoundQ.spacing.gutter),verticalAlignment=Alignment.CenterVertically,
        horizontalArrangement=Arrangement.spacedBy(SoundQ.spacing.small)) {
        if(progress.active>0)CircularProgressIndicator(Modifier.size(16.dp),color=SoundQ.colors.primary,strokeWidth=2.dp)
        Text(importProgressText(progress),Modifier.weight(1f).semantics {liveRegion=LiveRegionMode.Polite},
            style=SoundQ.typography.caption,color=SoundQ.colors.text)
        SoundQIconButton(SoundQIcon.Info,"Open Imports",onOpen,outlined=false)
        SoundQIconButton(SoundQIcon.Close,"Dismiss import progress",onDismiss,outlined=false)
    }
    SoundQDivider()
}

internal fun importProgressText(progress:ImportBatchProgress):String {
    val facts=buildList {
        if(progress.active>0)add("${progress.active} active")
        if(progress.complete>0)add("${progress.complete} complete")
        if(progress.failed>0)add("${progress.failed} failed")
        if(progress.unknown>0)add("${progress.unknown} unknown")
        if(progress.needsChecking)add("Check Imports")
    }
    return "This batch · "+facts.joinToString(" · ")
}
