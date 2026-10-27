package com.soundq.nativepreview

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.graphics.drawable.StateListDrawable
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.TextView
import kotlin.math.roundToInt

/** Small View styling helpers; no navigation, playback or collection ownership. */
internal class SoundQViews(val context: Context) {
    val background = context.getColor(R.color.soundq_background)
    val surface = context.getColor(R.color.soundq_surface)
    val raised = context.getColor(R.color.soundq_surface_raised)
    val primary = context.getColor(R.color.soundq_text_primary)
    val secondary = context.getColor(R.color.soundq_text_secondary)
    val outline = context.getColor(R.color.soundq_outline)
    val orange = context.getColor(R.color.soundq_orange)
    val cyan = context.getColor(R.color.soundq_accent)
    val error = context.getColor(R.color.soundq_error)
    val regular = context.resources.getFont(R.font.soundq_regular)
    val medium = context.resources.getFont(R.font.soundq_medium)
    val bold = context.resources.getFont(R.font.soundq_bold)
    val mono = context.resources.getFont(R.font.soundq_mono)
    fun dp(value: Int) = (value * context.resources.displayMetrics.density).roundToInt()
    fun label(value: String, size: Float, muted: Boolean = false) = TextView(context).apply {
        text = value; textSize = size; typeface = regular
        setTextColor(if (muted) secondary else primary)
        includeFontPadding = true
    }
    fun panel(fill: Int = surface, stroke: Int = outline, radius: Int = 0) = GradientDrawable().apply {
        setColor(fill); setStroke(dp(1),stroke); cornerRadius = dp(radius).toFloat()
    }
    fun interaction(selected: Boolean = false) = StateListDrawable().apply {
        addState(intArrayOf(android.R.attr.state_focused),panel(if(selected) raised else surface,cyan))
        addState(intArrayOf(android.R.attr.state_hovered),panel(raised,cyan))
        addState(intArrayOf(),panel(if(selected) raised else background,if(selected) orange else outline))
    }
    fun primaryInteraction() = StateListDrawable().apply {
        addState(intArrayOf(-android.R.attr.state_enabled),panel(orange,orange))
        addState(intArrayOf(android.R.attr.state_focused),panel(orange,cyan))
        addState(intArrayOf(android.R.attr.state_hovered),panel(orange,cyan))
        addState(intArrayOf(android.R.attr.state_pressed),panel(orange,cyan))
        addState(intArrayOf(),panel(orange,orange))
    }
    fun button(value: String, action: () -> Unit) = Button(context).apply {
        text = value; textSize = 14f; typeface = medium; isAllCaps = false
        minimumWidth = dp(48); minimumHeight = dp(48)
        minWidth = dp(48); minHeight = dp(48)
        setPadding(dp(12),dp(8),dp(12),dp(8)); gravity = Gravity.CENTER
        setTextColor(primary)
        background = RippleDrawable(ColorStateList.valueOf(cyan and 0x00ffffff or 0x33000000),interaction(),null)
        stateListAnimator = null; elevation = 0f
        setOnClickListener { action() }
    }
    fun mark(button: Button, selected: Boolean) {
        button.isSelected = selected
        button.setTextColor(if(selected) orange else primary)
        button.background = RippleDrawable(ColorStateList.valueOf(0x3339c6b6),interaction(selected),null)
    }
    fun availability(view: View, enabled: Boolean) {
        view.isEnabled = enabled
        view.alpha = if(enabled) 1f else 0.5f
    }
}
