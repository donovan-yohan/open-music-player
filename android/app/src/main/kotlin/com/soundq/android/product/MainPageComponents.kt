package com.soundq.android.product

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import com.soundq.android.R
import com.soundq.designsystem.SoundQMainPageHeader

/** Resource adapter only; all root-title geometry belongs to the design system. */
@Composable internal fun MainPageHeader(title:String,navigation:(@Composable ()->Unit)?=null,
    actions:@Composable RowScope.()->Unit={}) {
    SoundQMainPageHeader(title,brand={Image(painterResource(R.drawable.soundq_logo),null,Modifier.fillMaxSize())},
        navigation=navigation,actions=actions)
}
