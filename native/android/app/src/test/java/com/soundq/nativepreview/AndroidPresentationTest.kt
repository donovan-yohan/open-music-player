package com.soundq.nativepreview

import android.content.ComponentName
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Rect
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Real Activity, Android layout/scroll/RecyclerView and native Skia; no service/JNI.
 * The bind boundary is refused before onCreate: PlaybackService's constructor
 * initializes CoreBridge/JNI and must never be constructed by this UI-only gate.
 * Authenticated/selected visibility is supplied at the presentation boundary;
 * service/account admission remains covered by the registered Library probe.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class AndroidPresentationTest {
    private fun field(activity: MainActivity, name: String): View =
        MainActivity::class.java.getDeclaredField(name).apply { isAccessible = true }.get(activity) as View

    private fun <T> shell(compact: Boolean, body: (MainActivity, LinearLayout, RecyclerView, MainActivity.Rows) -> T): T {
        RuntimeEnvironment.setQualifiers(if (compact) "w411dp-h426dp-420dpi" else "w411dp-h914dp-420dpi")
        RuntimeEnvironment.setFontScale(if (compact) 1.6f else 1f)
        val app = RuntimeEnvironment.getApplication()
        val boundary = shadowOf(app)
        boundary.declareComponentUnbindable(ComponentName(app, PlaybackService::class.java))
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup().visible()
        val activity = controller.get()
        try {
            val root = (activity.findViewById<ViewGroup>(android.R.id.content)).getChildAt(0) as LinearLayout
            // Isolate the production root from OS bars/IME. Exact content constraint,
            // not a replacement layout algorithm; BoundedScroll still measures itself.
            (root.parent as ViewGroup).removeView(root)
            root.setPadding(0, 0, 0, 0)
            (field(activity, "login").parent as View).visibility = View.GONE
            field(activity, "library").visibility = View.VISIBLE
            field(activity, "empty").visibility = View.GONE
            (field(activity, "status") as TextView).text = "1 of 500 tracks"
            field(activity, "retry").visibility = View.GONE
            val list = activity.fixtureList!!
            val adapter = MainActivity.Rows(SoundQViews(activity), {}, {}, {})
            list.adapter = adapter
            adapter.submitList(listOf(row()))
            shadowOf(Looper.getMainLooper()).idle()
            assertNull("UI-only setup must not start a service", boundary.peekNextStartedService())
            assertEquals(if (compact) 1.6f else 1f, activity.resources.configuration.fontScale)
            return body(activity, root, list, adapter)
        } finally {
            controller.pause().stop().destroy()
        }
    }

    private fun row(title: String = "One") = MainActivity.Row(1, title, "Artist", 180000, false, false, true,
        LibraryBrowseState.RowOwner(1, 1, 1), null)

    private fun measure(root: LinearLayout, compact: Boolean) {
        val width = 1080
        val height = if (compact) 1120 else 2400
        // Two normal Android passes establish rootView.height used by BoundedScroll.
        repeat(2) {
            root.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
            root.layout(0, 0, width, height)
        }
    }

    private fun mountedRow(list: RecyclerView, label: String): MainActivity.Rows.Holder {
        assertTrue("$label: positive list viewport", list.height > 0)
        val holder = list.findViewHolderForAdapterPosition(0) as? MainActivity.Rows.Holder
        assertNotNull("$label: mounted row", holder)
        holder!!
        val visible = Rect()
        assertTrue("$label: positive mounted row", holder.row.getLocalVisibleRect(visible) && visible.height() > 0)
        assertTrue("$label: positive mounted heart", holder.heart.getLocalVisibleRect(visible) && visible.height() > 0)
        return holder
    }

    private fun reveal(root: LinearLayout, view: View, compact: Boolean, label: String) {
        view.requestRectangleOnScreen(Rect(0, 0, view.width, view.height), true)
        measure(root, compact)
        val rect = Rect()
        assertTrue("$label: native individually revealable", view.getLocalVisibleRect(rect))
        assertEquals("$label: complete width", view.width, rect.width())
        assertEquals("$label: complete height", view.height, rect.height())
        assertTrue("$label: nonempty cell", view.width > 0 && view.height > 0)
    }

    private fun allocation(compact: Boolean) = shell(compact) { activity, root, list, _ ->
        val sizes = listOf("query", "all", "liked", "search", "refresh", "more").associateWith {
            (field(activity, it) as TextView).textSize
        }
        for (selected in listOf(false, true)) {
            field(activity, "dock").visibility = if (selected) View.VISIBLE else View.GONE
            measure(root, compact)
            val label = "allocation compact=$compact selected=$selected"
            mountedRow(list, label)
            val controls = mutableListOf("query", "all", "liked", "search", "refresh", "more")
            if (selected) controls.addAll(listOf("seek", "previous", "next", "play"))
            for (name in controls) {
                reveal(root, field(activity, name), compact, "$label/$name")
                mountedRow(list, "$label after $name")
            }
            sizes.forEach { (name, size) -> assertEquals("$label: no font shrink $name", size, (field(activity, name) as TextView).textSize) }
            val reference = TextView(activity).apply { textSize = 16f }
            assertEquals("query remains native 16sp", reference.textSize, (field(activity, "query") as TextView).textSize)
            reference.textSize = 14f
            for (name in listOf("all", "liked", "search", "refresh", "more")) {
                assertEquals("$name remains native 14sp", reference.textSize, (field(activity, name) as TextView).textSize)
            }
            println("$label tools=${(field(activity, "query").parent!!.parent as View).height} list=${list.height} dock=${field(activity, "dock").height}")
            val tools = field(activity, "query").parent!!.parent as ScrollView
            assertTrue("native tools scroll range", tools.getChildAt(0).height >= tools.height)
            if (compact) assertTrue("compact tools actually overflow", tools.getChildAt(0).height > tools.height)
        }
    }

    @Test fun normalAllocationBeforeAndAfterDock() { allocation(false) }
    @Test fun compactAllocationBeforeAndAfterDock() { allocation(true) }

    @Test fun rowContentGridAndSeparateCallbacks() = shell(false) { activity, root, list, _ ->
        val events = mutableListOf<String>()
        val adapter = MainActivity.Rows(SoundQViews(activity), { events.add("select:${it.id}") },
            { events.add("heart:${it.id}") }, { events.add("details:${it.id}") })
        list.adapter = adapter
        adapter.submitList(listOf(row()))
        field(activity, "dock").visibility = View.GONE
        measure(root, false)
        val holder = mountedRow(list, "grid")
        assertEquals("grid: row spans RecyclerView content width", list.width - list.paddingLeft - list.paddingRight, holder.row.width)
        assertEquals("grid: trailing heart", holder.row.width - holder.row.paddingRight, holder.heart.right)
        val rowBitmap = Bitmap.createBitmap(holder.row.width, holder.row.height, Bitmap.Config.ARGB_8888)
        holder.row.draw(Canvas(rowBitmap))
        for (x in listOf(0, holder.row.width - 1)) {
            assertEquals("grid: full-width row paint", 255, Color.alpha(rowBitmap.getPixel(x, holder.row.height / 2)))
        }
        rowBitmap.recycle()
        val metadata = holder.row.getChildAt(1) as LinearLayout
        val params = metadata.layoutParams as LinearLayout.LayoutParams
        assertEquals("grid: flexible metadata", 1f, params.weight)
        assertTrue("grid: metadata has positive width", metadata.width > 0)
        assertTrue("grid: metadata never overlaps heart", metadata.right <= holder.heart.left)
        assertEquals("grid: natural title wrapping", Int.MAX_VALUE, holder.name.maxLines)
        // Listener identity control, not a device/pointer journey. The root is
        // detached for exact native content constraints, so View.post click
        // delivery has no ViewRoot handler; invoke the actual bound callbacks.
        holder.heart.performClick()
        assertEquals("heart callback is separate", listOf("heart:1"), events)
        val hit = Rect()
        holder.row.getHitRect(hit)
        assertEquals("full-width row hit span", list.width - list.paddingLeft - list.paddingRight, hit.width())
        holder.row.performClick()
        assertEquals("selection never toggles heart", listOf("heart:1", "select:1"), events)
        holder.row.performLongClick()
        assertEquals(listOf("heart:1", "select:1", "details:1"), events)
        val oldWidth = metadata.width
        // Reset the list to avoid an asynchronous DiffUtil publication here;
        // the actual mounted binder and RecyclerView still measure the long row.
        adapter.submitList(null)
        adapter.submitList(listOf(row("A naturally wrapping recording title with substantial metadata")))
        shadowOf(Looper.getMainLooper()).idle()
        measure(root, false)
        val long = mountedRow(list, "long metadata")
        assertEquals("metadata flexible slot stable", oldWidth, (long.row.getChildAt(1)).width)
        assertTrue("long title wraps rather than shrinks", long.name.lineCount > 1)
    }

    @Test fun squareNativeInteractionRasterAllStates() = shell(false) { activity, _, _, _ ->
        val style = SoundQViews(activity)
        val states = linkedMapOf(
            "rest" to intArrayOf(android.R.attr.state_enabled),
            "focus" to intArrayOf(android.R.attr.state_enabled, android.R.attr.state_focused),
            "hover" to intArrayOf(android.R.attr.state_enabled, android.R.attr.state_hovered),
            "pressed" to intArrayOf(android.R.attr.state_enabled, android.R.attr.state_pressed),
            "disabled" to intArrayOf(-android.R.attr.state_enabled))
        for (selected in listOf(false, true)) for ((stateName, state) in states) {
            val button = style.button("Raster") {}
            style.mark(button, selected)
            style.availability(button, stateName != "disabled")
            val backgrounds = listOf(style.interaction(selected), button.background)
            for ((index, drawable) in backgrounds.withIndex()) {
                drawable.state = state
                drawable.setBounds(0, 0, 200, 120)
                drawable.jumpToCurrentState()
                val bitmap = Bitmap.createBitmap(200, 120, Bitmap.Config.ARGB_8888)
                drawable.draw(Canvas(bitmap))
                // Native Skia alpha at all four corners distinguishes radius 4dp
                // from square. No getter/string oracle can stand in for these pixels.
                for ((x, y) in listOf(0 to 0, 199 to 0, 0 to 119, 199 to 119)) {
                    assertEquals("shape selected=$selected state=$stateName layer=$index corner=$x,$y", 255, Color.alpha(bitmap.getPixel(x, y)))
                }
                assertEquals("shape: painted center", 255, Color.alpha(bitmap.getPixel(100, 60)))
                bitmap.recycle()
            }
        }
    }
}
