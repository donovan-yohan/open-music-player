package com.soundq.designsystem

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

/** List continuation/navigation with the same artwork lane as a media row. */
@Composable fun SoundQListActionRow(label:String,onClick:()->Unit,enabled:Boolean=true,description:String=label) {
    val interactions=remember {MutableInteractionSource()}
    val focused by interactions.collectIsFocusedAsState()
    val ink=if(enabled)SoundQ.colors.primary else SoundQ.colors.disabled
    Row(Modifier.fillMaxWidth().heightIn(min=SoundQ.sizes.mediaRow)
        .background(SoundQ.colors.background).mediaRowBottomRule().soundQCellFocus(focused)
        .semantics(mergeDescendants=true) {contentDescription=description}
        .clickable(interactionSource=interactions,indication=androidx.compose.foundation.LocalIndication.current,
            enabled=enabled,role=Role.Button,onClick=onClick),verticalAlignment=Alignment.CenterVertically) {
        SoundQArtworkSlot(size=SoundQ.sizes.mediaRow,artwork={SoundQIcon(SoundQIcon.List,null,tint=ink)})
        Text(label,Modifier.weight(1f).padding(horizontal=8.dp,vertical=SoundQ.spacing.small),
            style=SoundQ.typography.title,color=ink,maxLines=2)
    }
}
