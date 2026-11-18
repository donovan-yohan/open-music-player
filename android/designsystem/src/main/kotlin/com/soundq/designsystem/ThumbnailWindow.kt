package com.soundq.designsystem

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.lazy.layout.LazyLayoutCacheWindow
import androidx.compose.runtime.*

/** Native idle-time precomposition/premeasurement, not a second list or a data-page read.
 * No behind window: reversal retires abandoned speculative compositions normally.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable fun rememberSoundQThumbnailListState():LazyListState = rememberLazyListState(
    cacheWindow=remember {LazyLayoutCacheWindow(aheadFraction=1f,behindFraction=0f)})

/** Only image consumers observe demand; row actions, geometry and scroll ownership are unchanged. */
val LocalSoundQThumbnailVisible=staticCompositionLocalOf<()->Boolean> {{true}}

@Composable fun SoundQThumbnailItem(state:LazyListState,key:Any,content:@Composable ()->Unit) {
    val visible=remember(state,key) {{state.layoutInfo.visibleItemsInfo.any {it.key==key}}}
    CompositionLocalProvider(LocalSoundQThumbnailVisible provides visible,content=content)
}
