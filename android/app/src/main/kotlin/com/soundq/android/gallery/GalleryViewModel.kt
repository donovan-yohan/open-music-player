package com.soundq.android.gallery

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.SavedStateHandle
import com.soundq.android.playback.ControllerProjection
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

class GalleryViewModel(application: Application, private val saved: SavedStateHandle) : AndroidViewModel(application) {
    private val mutable = MutableStateFlow(GalleryState(saved["query"] ?: "", saved["selected"], saved["reduced"] ?: false))
    val state = mutable.asStateFlow()
    private val controller = ControllerProjection(application)
    val playback = controller.state
    fun select(id: String) { mutable.value = mutable.value.reduce(GalleryAction.Select(id)); saved["selected"] = mutable.value.selectedId }
    fun query(value: String) { mutable.value = mutable.value.copy(query = value); saved["query"] = value }
    fun reduced(value: Boolean) { mutable.value = mutable.value.copy(reducedMotion = value); saved["reduced"] = value }
    override fun onCleared() { controller.close() }
}
