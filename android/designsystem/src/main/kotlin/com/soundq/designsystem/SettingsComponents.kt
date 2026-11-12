package com.soundq.designsystem

import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import soundq.design.generated.SoundQComposeTokens as T

/** Named aliases of existing generated dimensions. No new token values. */
object SoundQSettingsMetrics {
    val gutter: Dp get() = SoundQ.spacing.gutter
    val rowMin: Dp = T.PRIMITIVE_DIMENSION_PX56
    val supportingRowMin: Dp get() = SoundQ.sizes.row
    val appBarMin: Dp = T.PRIMITIVE_DIMENSION_PX56
    val appBarLargeMin: Dp = T.PRIMITIVE_DIMENSION_PX64
    val firstSectionTop: Dp get() = SoundQ.spacing.large
    val sectionTop: Dp = T.PRIMITIVE_DIMENSION_PX24
    val sectionBottom: Dp = T.PRIMITIVE_DIMENSION_PX8
    val backInset: Dp = T.PRIMITIVE_DIMENSION_PX8
    val bottomPadding: Dp = T.PRIMITIVE_DIMENSION_PX24
    const val valueFraction = 0.38f
    const val stackedFontScale = 1.3f
}

@Composable private fun mirrored(): Modifier = if (LocalLayoutDirection.current == LayoutDirection.Rtl) Modifier.scale(-1f, 1f) else Modifier

/** Full-screen settings page: pinned Back app bar, one scrolling column with zero horizontal padding. */
@Composable fun SoundQSettingsScaffold(
    title: String, onBack: () -> Unit, modifier: Modifier = Modifier,
    scrollState: ScrollState = rememberScrollState(),
    content: @Composable ColumnScope.() -> Unit,
) {
    val large = LocalDensity.current.fontScale >= SoundQSettingsMetrics.stackedFontScale
    Column(modifier.widthIn(max = SoundQ.sizes.appMax).fillMaxSize().background(SoundQ.colors.background)) {
        Row(Modifier.fillMaxWidth().heightIn(min = if (large) SoundQSettingsMetrics.appBarLargeMin else SoundQSettingsMetrics.appBarMin)
            .padding(start = SoundQSettingsMetrics.backInset, end = SoundQSettingsMetrics.gutter),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(SoundQ.spacing.medium)) {
            SoundQIconButton(SoundQIcon.Back, "Back", onBack, mirrored(), outlined = false)
            Text(title, Modifier.weight(1f).semantics { heading() }, style = SoundQ.typography.title, color = SoundQ.colors.text)
        }
        SoundQDivider()
        Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(scrollState)) {
            content()
            Spacer(Modifier.height(SoundQSettingsMetrics.bottomPadding))
        }
    }
}

@Composable fun SoundQSettingsSectionLabel(title: String, first: Boolean = false, modifier: Modifier = Modifier) {
    Text(title, modifier.fillMaxWidth()
        .padding(start = SoundQSettingsMetrics.gutter, end = SoundQSettingsMetrics.gutter,
            top = if (first) SoundQSettingsMetrics.firstSectionTop else SoundQSettingsMetrics.sectionTop,
            bottom = SoundQSettingsMetrics.sectionBottom)
        .semantics { heading() },
        style = SoundQ.typography.caption.copy(fontWeight = FontWeight.SemiBold), color = SoundQ.colors.muted)
}

/** Concise status/action blocks own the same gutter as rows; they never sit flush with the edge. */
@Composable fun SoundQSettingsBlock(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.fillMaxWidth().padding(horizontal = SoundQSettingsMetrics.gutter), verticalArrangement = Arrangement.spacedBy(SoundQ.spacing.medium), content = content)
}

@Composable private fun SettingsRowFrame(
    title: String, supporting: String?, value: String?, enabled: Boolean, selected: Boolean,
    interactive: Modifier, interactions: MutableInteractionSource?, technical: Boolean = false,
    trailing: (@Composable () -> Unit)?,
) {
    // Technical identifiers (endpoint, build) wrap at full width under the title instead of a narrow value column.
    val stacked = technical || LocalDensity.current.fontScale >= SoundQSettingsMetrics.stackedFontScale
    val focused = interactions?.collectIsFocusedAsState()?.value == true
    Column(interactive.fillMaxWidth().background(if (selected) SoundQ.colors.surface else SoundQ.colors.background).soundQCellFocus(focused)) {
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val content = maxWidth - SoundQSettingsMetrics.gutter * 2
            Row(Modifier.fillMaxWidth()
                .heightIn(min = if (supporting != null || (stacked && value != null)) SoundQSettingsMetrics.supportingRowMin else SoundQSettingsMetrics.rowMin)
                .padding(horizontal = SoundQSettingsMetrics.gutter, vertical = SoundQ.spacing.medium),
                horizontalArrangement = Arrangement.spacedBy(SoundQ.spacing.medium), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(SoundQ.spacing.small)) {
                    Text(title, style = SoundQ.typography.title,
                        color = if (!enabled) SoundQ.colors.disabled else if (selected) SoundQ.colors.primary else SoundQ.colors.text)
                    supporting?.let { Text(it, style = SoundQ.typography.caption, color = SoundQ.colors.muted) }
                    if (stacked && value != null) Text(value, style = if (technical) SoundQ.typography.mono else SoundQ.typography.caption, color = SoundQ.colors.muted)
                }
                if (!stacked && value != null) Text(value, Modifier.widthIn(max = content * SoundQSettingsMetrics.valueFraction),
                    style = SoundQ.typography.caption, color = SoundQ.colors.muted, textAlign = TextAlign.End)
                trailing?.invoke()
            }
        }
        SoundQDivider()
    }
}

/**
 * Navigation (onClick, automatic chevron), action (onClick + explicit empty trailing) or read-only (no onClick).
 * One merged accessibility node; the chevron and divider are decorative.
 */
@Composable fun SoundQSettingsRow(
    title: String, supporting: String? = null, value: String? = null,
    enabled: Boolean = true, onClick: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
    technical: Boolean = false,
    trailing: (@Composable () -> Unit)? = null,
) {
    val interactions = remember { MutableInteractionSource() }
    val interactive = if (onClick != null) modifier.clickable(interactions, LocalIndication.current, enabled = enabled, role = Role.Button, onClick = onClick)
        .semantics(mergeDescendants = true) {}
        else modifier.semantics(mergeDescendants = true) {}
    val chevron: (@Composable () -> Unit)? = trailing ?: if (onClick != null) ({
        SoundQIcon(SoundQIcon.Next, null, mirrored(), tint = if (enabled) SoundQ.colors.muted else SoundQ.colors.disabled)
    }) else null
    SettingsRowFrame(title, supporting, value, enabled, false, interactive, if (onClick != null) interactions else null, technical, chevron)
}

@Composable private fun settingsSwitchColors() = SwitchDefaults.colors(
    checkedThumbColor = SoundQ.colors.onPrimary, checkedTrackColor = SoundQ.colors.primary, checkedBorderColor = SoundQ.colors.primary,
    uncheckedThumbColor = SoundQ.colors.muted, uncheckedTrackColor = SoundQ.colors.surface, uncheckedBorderColor = SoundQ.colors.inputBorder,
    disabledCheckedThumbColor = SoundQ.colors.disabledSurface, disabledCheckedTrackColor = SoundQ.colors.disabled, disabledCheckedBorderColor = SoundQ.colors.disabled,
    disabledUncheckedThumbColor = SoundQ.colors.disabled, disabledUncheckedTrackColor = SoundQ.colors.disabledSurface, disabledUncheckedBorderColor = SoundQ.colors.border,
)

/** The whole row is the switch target; the trailing Switch is decorative so it never takes a second focus or click. */
@Composable fun SoundQSettingsSwitchRow(
    title: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit,
    supporting: String? = null, enabled: Boolean = true,
    modifier: Modifier = Modifier,
) {
    val interactions = remember { MutableInteractionSource() }
    SettingsRowFrame(title, supporting, null, enabled, false,
        modifier.toggleable(checked, interactions, LocalIndication.current, enabled, Role.Switch, onCheckedChange),
        interactions) { Switch(checked, null, enabled = enabled, colors = settingsSwitchColors()) }
}

/** Single-select option inside a selectableGroup. Selection is carried by the radio mark and state, not colour alone. */
@Composable fun SoundQSettingsChoiceRow(
    title: String, selected: Boolean, onSelect: () -> Unit,
    supporting: String? = null, enabled: Boolean = true,
    modifier: Modifier = Modifier,
) {
    val interactions = remember { MutableInteractionSource() }
    SettingsRowFrame(title, supporting, null, enabled, selected,
        modifier.selectable(selected, interactions, LocalIndication.current, enabled, Role.RadioButton, onSelect),
        interactions) {
        RadioButton(selected, null, enabled = enabled, colors = RadioButtonDefaults.colors(selectedColor = SoundQ.colors.primary,
            unselectedColor = SoundQ.colors.muted, disabledSelectedColor = SoundQ.colors.disabled, disabledUnselectedColor = SoundQ.colors.disabled))
    }
}
