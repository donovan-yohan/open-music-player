package com.soundq.android.product.discovery

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.soundq.android.data.discovery.SourceProvider
import com.soundq.designsystem.SoundQ

/** SoundQ's text badge identifies the source without reusing a provider logo. */
@Composable internal fun DiscoveryProviderMark(provider:SourceProvider,modifier:Modifier=Modifier) {
    val abbreviation=when(provider) {
        SourceProvider.YouTube -> "YT"
        SourceProvider.SoundCloud -> "SC"
    }
    val shape=RoundedCornerShape(3.dp)
    val colors=SoundQ.colors
    Text(abbreviation,
        modifier.background(colors.surface,shape).border(1.dp,colors.border,shape)
            .clearAndSetSemantics {contentDescription="Source: ${provider.label}"}
            .padding(horizontal=4.dp,vertical=2.dp),
        color=colors.text,style=SoundQ.typography.mono.copy(fontSize=11.sp,lineHeight=13.sp),
        maxLines=1,softWrap=false)
}
