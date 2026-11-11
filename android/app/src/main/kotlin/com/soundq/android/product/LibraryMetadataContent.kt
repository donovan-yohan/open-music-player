package com.soundq.android.product

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.soundq.designsystem.SoundQ
import com.soundq.designsystem.LocalMediaRowCompactMetadata

/** Duration is measured first; optional analysis uses the remainder, complete speech is retained. */
@Composable internal fun LibraryMetadataContent(fields:List<LibraryMetadataField>) {
    if(fields.isEmpty())return
    val compact=LocalMediaRowCompactMetadata.current
    val first=fields.first()
    val density=LocalDensity.current
    val style=if(compact)SoundQ.typography.mono.copy(lineHeight=with(density){34.dp.toSp()}) else SoundQ.typography.caption
    Row(Modifier.testTag("library-row-metadata").semantics {contentDescription=fields.joinToString(", "){it.spoken}}) {
        // A breakable unknown token still needs its complete single-line width.
        Text(first.display,Modifier.width(IntrinsicSize.Max),color=SoundQ.colors.muted,style=style,maxLines=1,softWrap=false)
        if(!compact&&fields.size>1)Text(" · "+fields.drop(1).joinToString(" · "){it.display},Modifier.weight(1f,fill=false),
            color=SoundQ.colors.muted,style=SoundQ.typography.caption,maxLines=1,softWrap=false,overflow=TextOverflow.Ellipsis)
    }
}
