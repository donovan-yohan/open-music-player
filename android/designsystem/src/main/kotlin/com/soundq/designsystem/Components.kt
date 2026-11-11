package com.soundq.designsystem

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.*
import androidx.compose.foundation.layout.*
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.input.*
import androidx.compose.ui.tooling.preview.Preview

@Composable fun SoundQIconButton(icon: SoundQIcon, label: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, selected: Boolean = false, outlined: Boolean = true) {
    SoundQIconButtonContent(label,onClick,modifier,enabled,selected,outlined) {tint->SoundQIcon(icon,null,tint=tint)}
}
@Composable fun SoundQIconButton(icon: SoundQPlayerIcon, label: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, selected: Boolean = false, outlined: Boolean = true) {
    SoundQIconButtonContent(label,onClick,modifier,enabled,selected,outlined) {tint->SoundQIcon(icon,null,tint=tint)}
}
@Composable private fun SoundQIconButtonContent(label:String,onClick:()->Unit,modifier:Modifier,enabled:Boolean,selected:Boolean,outlined:Boolean,content:@Composable (Color)->Unit) {
    val interactions = remember { MutableInteractionSource() }
    val focused by interactions.collectIsFocusedAsState()
    val colors = SoundQ.colors
    val motion=SoundQ.motion.selection
    val background by key(colors) { animateColorAsState(if (selected) colors.raised else colors.background, tween(motion.durationMillis, easing = motion.easing), label = "selection") }
    val chrome=if(outlined)Modifier.border(SoundQ.sizes.border,if(focused)colors.focus else if(selected)colors.primary else colors.border)
        else Modifier.soundQCellFocus(focused)
    Box(modifier.sizeIn(minWidth = SoundQ.sizes.target, minHeight = SoundQ.sizes.target)
        .background(background)
        .then(chrome)
        .semantics { contentDescription = label; this.selected = selected }
        .clickable(interactionSource = interactions, indication = LocalIndication.current, enabled = enabled, role = Role.Button, onClick = onClick)
        .padding(SoundQ.spacing.medium), contentAlignment = Alignment.Center) {
        content(if (!enabled) colors.disabled else if (selected) colors.primary else colors.text)
    }
}
/** Focus is transient ink inside the cell; structural grid edges belong to its parent. */
@Composable internal fun Modifier.soundQCellFocus(focused:Boolean,onPrimary:Boolean=false):Modifier {
    val color=if(onPrimary)SoundQ.colors.onPrimary else SoundQ.colors.focus
    val width=SoundQ.sizes.focus
    return drawWithContent {
        drawContent()
        if(focused) {
            val stroke=width.toPx()
            val inset=2.dp.toPx()+stroke/2
            drawRect(color,topLeft=Offset(inset,inset),size=Size((size.width-inset*2).coerceAtLeast(0f),(size.height-inset*2).coerceAtLeast(0f)),style=Stroke(stroke))
        }
    }
}
enum class SoundQButtonVariant { Primary, Secondary, Quiet }
@Composable fun SoundQButton(label: String, onClick: () -> Unit, modifier: Modifier = Modifier, variant: SoundQButtonVariant = SoundQButtonVariant.Primary, enabled: Boolean = true) {
    val c = SoundQ.colors
    val bg = when(variant) { SoundQButtonVariant.Primary -> c.primary; SoundQButtonVariant.Secondary -> c.surface; SoundQButtonVariant.Quiet -> Color.Transparent }
    Button(onClick, modifier.heightIn(min = SoundQ.sizes.target), enabled = enabled, shape = RectangleShape,
        colors = ButtonDefaults.buttonColors(containerColor = bg, contentColor = if (variant == SoundQButtonVariant.Primary) c.onPrimary else c.text, disabledContainerColor = c.disabledSurface, disabledContentColor = c.disabled),
        border = if (variant == SoundQButtonVariant.Secondary) BorderStroke(SoundQ.sizes.border, c.border) else null,
        contentPadding = PaddingValues(horizontal = SoundQ.spacing.large, vertical = SoundQ.spacing.medium)) {
        Text(label, style = SoundQ.typography.body)
    }
}
@Composable fun SoundQTextField(value: String, onValueChange: (String) -> Unit, label: String, modifier: Modifier = Modifier, enabled: Boolean = true, secure: Boolean = false, error: String? = null) {
    val c = SoundQ.colors
    OutlinedTextField(value = value, onValueChange = onValueChange, modifier = modifier.fillMaxWidth(),
        enabled = enabled, textStyle = SoundQ.typography.body, label = { Text(label) },
        singleLine = true, isError = error != null,
        supportingText = if (error == null) null else ({ Text(error) }),
        visualTransformation = if (secure) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = if (secure) KeyboardType.Password else KeyboardType.Text),
        shape = RectangleShape,
        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = c.focus, unfocusedBorderColor = c.inputBorder, cursorColor = c.focus,
            focusedTextColor = c.text, unfocusedTextColor = c.text, errorBorderColor = c.error, errorCursorColor = c.error,
            disabledTextColor = c.disabled, disabledBorderColor = c.border),
    )
}
@Composable fun SoundQDivider(modifier: Modifier = Modifier) { HorizontalDivider(modifier, thickness = SoundQ.sizes.border, color = SoundQ.colors.border) }
/** Slot/data in and action out; no DTO, playback, or navigation dependencies. */
@Composable fun SoundQRow(title: String, subtitle: String, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, leading: (@Composable () -> Unit)? = null, trailing: (@Composable () -> Unit)? = null, role: Role = Role.Button, rowModifier: Modifier = Modifier, supportingContent: (@Composable () -> Unit)? = null) {
    // The shared boundary belongs to the row's hit/semantics surface too.
    // Keeping it outside leaves an unowned one-border strip between targets.
    Column(modifier.fillMaxWidth()
        .semantics(mergeDescendants = true) { this.selected = selected }
        .clickable(enabled = enabled, role = role, onClick = onClick)) {
        Row(rowModifier.fillMaxWidth().heightIn(min = SoundQ.sizes.row)
            .background(if (selected) SoundQ.colors.surface else SoundQ.colors.background)
            .padding(vertical = SoundQ.spacing.medium), horizontalArrangement = Arrangement.spacedBy(SoundQ.spacing.medium), verticalAlignment = Alignment.CenterVertically) {
            leading?.invoke()
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(SoundQ.spacing.small)) {
                Text(title, color = if (!enabled) SoundQ.colors.disabled else if (selected) SoundQ.colors.primary else SoundQ.colors.text, style = SoundQ.typography.title)
                Text(subtitle, color = SoundQ.colors.muted, style = SoundQ.typography.caption)
                supportingContent?.invoke()
            }
            trailing?.invoke()
        }
        SoundQDivider()
    }
}
@Preview(fontScale = 2f, widthDp = 360, showBackground = true)
@Composable private fun LargeTextPreview() { SoundQTheme { SoundQRow("A long synthetic fixture title that wraps", "No playback connected", true, {}) } }
