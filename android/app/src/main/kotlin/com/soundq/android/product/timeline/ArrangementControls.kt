package com.soundq.android.product.timeline

import androidx.compose.material3.Text
import androidx.compose.runtime.*
import com.soundq.android.data.timeline.TimelineDocument
import com.soundq.android.product.ProductViewModel
import com.soundq.designsystem.*
import kotlinx.coroutines.*

@Composable internal fun ArrangementControls(model:ProductViewModel,document:TimelineDocument,valid:()->Boolean,setBusy:(Boolean)->Unit,busy:Boolean) {
    val jobs=rememberCoroutineScope()
    val scope=remember {model.graph.session.capture()}
    val save=model.graph.arrangementSave
    val state by save.state.collectAsState()
    val playback by model.playback.collectAsState()
    var name by remember {mutableStateOf("Arrangement")}
    var id by remember {mutableStateOf("")}
    var message by remember {mutableStateOf<String?>(null)}
    LaunchedEffect(scope){if(scope!=null)save.enter(scope)}
    fun execute(work:(()->Unit)?) {save.schedule(jobs,work)}
    TimelineFadeControls(model,document,valid,setBusy,busy)
    SoundQButton("Cancel pending mixed audition",{model.graph.timeline.cancelAudition();model.controller.pause();setBusy(false)},enabled=busy,variant=SoundQButtonVariant.Quiet)
    SoundQButton("Apply and audition mixed arrangement",{
        if(!busy&&valid()) {
            val request=scope?.let {model.graph.timeline.captureAudition(it,document,valid)}
            if(request!=null) {
                setBusy(true)
                model.controller.applyArrangement(document,request,{valid()&&scope.let {model.graph.timeline.accepts(it,document)}}) {accepted ->
                    setBusy(false);if(accepted==null)model.graph.timeline.retireAudition(request)
                    message=if(accepted==null)"Arrangement refused. Check rate-one timing, connection and downloaded sources." else "Revision ${accepted.revision} installed. Playback progress reports the existing player."
                }
            }
        }
    },enabled=!busy&&document.clips.isNotEmpty()&&playback.canAuditionArrangement)
    if(!playback.canAuditionArrangement)Text("Arrangement playback is not available in this build.",style=SoundQ.typography.caption)
    SoundQTextField(name,{name=it},"Arrangement name",enabled=!busy&&!state.busy)
    SoundQButton("Save arrangement",{if(scope!=null)execute(save.save(scope,document,name,valid))},enabled=!busy&&!state.busy&&!state.blocked&&document.clips.isNotEmpty()&&name.isNotBlank(),variant=SoundQButtonVariant.Secondary)
    state.saved?.let {Text("Saved mix ${it.id} · version ${it.version}",style=SoundQ.typography.mono)}
    SoundQTextField(id,{id=it},"Saved mix ID for GET readback",enabled=!state.busy)
    SoundQButton("Read back saved arrangement (GET)",{if(scope!=null)execute(save.readback(scope,id,document,valid))},enabled=!state.busy&&id.isNotBlank(),variant=SoundQButtonVariant.Quiet)
    (state.message ?: message)?.let {Text(it,style=SoundQ.typography.caption)}
}
