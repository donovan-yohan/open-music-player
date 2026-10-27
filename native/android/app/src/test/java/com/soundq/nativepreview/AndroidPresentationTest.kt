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
            val content = (activity.findViewById<ViewGroup>(android.R.id.content)).getChildAt(0)
            val root = (if (content is ScrollView) (content.getChildAt(0)) else content) as LinearLayout
            // Isolate the production root from OS bars/IME. Exact content constraint,
            // not a replacement layout algorithm; BoundedScroll still measures itself.
            (content.parent as ViewGroup).removeView(content)
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

    private fun measure(root: LinearLayout, compact: Boolean, contentHeight: Int = if (compact) 1120 else 2400) {
        val width = 1080
        val height = contentHeight
        val surface = (root.parent as? ScrollView) ?: root
        // Two normal Android passes establish rootView.height used by BoundedScroll.
        repeat(2) {
            surface.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
            surface.layout(0, 0, width, height)
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

    /** Attached production Activity/ViewRoot, real API34 MotionEvent routing.
     * Exact component content constraints; service/JNI/OS IME remain separate.
     * Offset/focus setup is not counted as gesture progress or mounted acceptance.
     */
    @Test fun attachedNestedScrollOwnership() {
        RuntimeEnvironment.setQualifiers("w411dp-h426dp-420dpi")
        RuntimeEnvironment.setFontScale(1.6f)
        val app = RuntimeEnvironment.getApplication()
        shadowOf(app).declareComponentUnbindable(ComponentName(app, PlaybackService::class.java))
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup().visible()
        val activity = controller.get()
        try {
            val outer = activity.findViewById<ViewGroup>(android.R.id.content).getChildAt(0) as ScrollView
            val root = outer.getChildAt(0) as LinearLayout
            (field(activity, "login").parent as View).visibility = View.GONE
            field(activity, "library").visibility = View.VISIBLE
            field(activity, "dock").visibility = View.VISIBLE
            field(activity, "empty").visibility = View.GONE
            field(activity, "retry").visibility = View.GONE
            (field(activity, "status") as TextView).text = "50 of 500 tracks"
            val query = field(activity, "query") as android.widget.EditText
            query.setText("zzsoundqnomatch")
            val inner = query.parent.parent as ScrollView
            val list = activity.fixtureList!!
            val adapter = MainActivity.Rows(SoundQViews(activity), {}, {}, {})
            list.adapter = adapter; adapter.submitList(listOf(row()))
            shadowOf(Looper.getMainLooper()).idle()
            fun visible(): Rect { val r = Rect(); query.getLocalVisibleRect(r); return r }
            fun state(label: String) {
                println("routing $label outer=${outer.scrollY}/${outer.height} inner=${inner.scrollY}/${inner.height} query=${query.width}x${query.height} visible=${visible()} nested=${inner.isNestedScrollingEnabled} axes=${outer.nestedScrollAxes} attached=${query.isAttachedToWindow} focus=${query.hasFocus()} selection=${query.selectionStart},${query.selectionEnd}")
            }
            fun event(action: Int, x: Float, y: Float, down: Long, time: Long) {
                val e = android.view.MotionEvent.obtain(down, time, action, x, y, 0)
                e.source = android.view.InputDevice.SOURCE_TOUCHSCREEN
                try { assertTrue("routing: attached native root dispatch", activity.dispatchTouchEvent(e)) }
                finally { e.recycle() }
            }
            for (height in listOf(311, 1057)) {
                // Constrain the real attached content, not an unattached replacement.
                outer.layoutParams = android.widget.FrameLayout.LayoutParams(1080, height)
                outer.setPadding(0, 0, 0, 0)
                repeat(3) {
                    activity.window.decorView.measure(View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY),
                        View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
                    activity.window.decorView.layout(0, 0, 1080, height)
                }
                assertTrue("routing: attached production editor", query.isAttachedToWindow)
                assertEquals("routing: exact content height", height, outer.height)
                assertTrue("routing: finite weighted lazy rows", list.height > 0 && list.height <= root.height)
                assertNotNull("routing: mounted lazy row", list.findViewHolderForAdapterPosition(0))
                val cell = Rect(0, 0, query.width, query.height)
                val cellInTools = Rect(cell)
                (query.parent as ViewGroup).offsetDescendantRectToMyCoords(query, cellInTools)
                // Top-clipped by one native pixel; sufficient real inner range.
                inner.scrollTo(0, cellInTools.top + 1)
                outer.scrollTo(0, 14)
                val qpos = IntArray(2); query.getLocationOnScreen(qpos)
                val down = android.os.SystemClock.uptimeMillis()
                event(android.view.MotionEvent.ACTION_DOWN, 500f, qpos[1] + 70f, down, down)
                event(android.view.MotionEvent.ACTION_UP, 500f, qpos[1] + 70f, down, down + 20)
                shadowOf(Looper.getMainLooper()).idle()
                // Reapply fixture boundary after ordinary native focus recovery.
                inner.scrollTo(0, cellInTools.top + 1); outer.scrollTo(0, 14)
                assertTrue("routing: ordinary pointer focus", query.hasFocus())
                val selection = listOf(query.selectionStart, query.selectionEnd)
                val beforeOuter = outer.scrollY; val beforeInner = inner.scrollY
                assertTrue("routing: meaningful clipped fixture", visible() != cell)
                val ip = IntArray(2); inner.getLocationOnScreen(ip)
                val startY = ip[1] + 16f
                val t = android.os.SystemClock.uptimeMillis()
                state("before height=$height")
                event(android.view.MotionEvent.ACTION_DOWN, 8f, startY, t, t)
                var travel = 0
                try {
                    // Ordinary gutter drag downward, stop at exact full native cell.
                    val limit = android.view.ViewConfiguration.get(activity).scaledTouchSlop * 2 + 16
                    while (travel < limit && visible() != cell) {
                        travel++
                        event(android.view.MotionEvent.ACTION_MOVE, 8f, startY + travel, t, t + travel * 8)
                    }
                } finally {
                    repeat(3) { event(android.view.MotionEvent.ACTION_MOVE, 8f, startY + travel, t, t + travel * 8 + (it + 1) * 60) }
                    event(android.view.MotionEvent.ACTION_UP, 8f, startY + travel, t, t + travel * 8 + 240)
                }
                state("after height=$height travel=$travel outerDelta=${outer.scrollY-beforeOuter} innerDelta=${inner.scrollY-beforeInner}")
                assertTrue("routing: child consumes native vertical drag", inner.scrollY < beforeInner)
                assertEquals("routing: parent does not steal child gesture", beforeOuter, outer.scrollY)
                assertEquals("routing: gesture exposes complete editor", cell, visible())
                assertEquals("routing: text preserved", "zzsoundqnomatch", query.text.toString())
                assertTrue("routing: focus preserved", query.hasFocus())
                assertEquals("routing: selection preserved", selection, listOf(query.selectionStart, query.selectionEnd))
                assertNull("routing: no service/domain command", shadowOf(app).peekNextStartedService())
            }
        } finally { controller.pause().stop().destroy() }
    }

    @Test fun normalAllocationBeforeAndAfterDock() { allocation(false) }
    @Test fun compactAllocationBeforeAndAfterDock() { allocation(true) }

    private fun recovery(compact: Boolean) = shell(compact) { activity, root, list, adapter ->
        val messages = linkedMapOf(
            "emptyLiked" to "No liked tracks match. Choose All tracks or change your search.",
            "loading" to "Loading your library…",
            "noMatch" to "No tracks match. Change your search and try again.",
            "error" to "Library couldn't load. Use Refresh to try again.")
        for (selected in listOf(true, false)) for ((state, message) in messages) {
            field(activity, "dock").visibility = if (selected) View.VISIBLE else View.GONE
            val empty = field(activity, "empty") as TextView
            empty.text = message
            empty.visibility = View.VISIBLE
            (field(activity, "status") as TextView).text = if (state == "error")
                "Search is too long. Shorten it and search again." else "0 of 0 tracks"
            adapter.submitList(null)
            adapter.submitList(emptyList())
            shadowOf(Looper.getMainLooper()).idle()
            measure(root, compact)
            val label = "recovery compact=$compact selected=$selected state=$state"
            println("$label tools=${(field(activity, "query").parent!!.parent as View).height} empty=${empty.height} list=${list.height}")
            for (name in listOf("query", "all", "liked", "search", "refresh", "more")) {
                reveal(root, field(activity, name), compact, "$label/$name")
            }
            assertEquals("$label: complete message retained", message, empty.text.toString())
            assertEquals("$label: no message line cap", Int.MAX_VALUE, empty.maxLines)
            assertNull("$label: no message truncation", empty.ellipsize)
            val reference = TextView(activity).apply { textSize = 16f }
            assertEquals("$label: native message 16sp", reference.textSize, empty.textSize)
            assertEquals("$label: native query 16sp", reference.textSize, (field(activity, "query") as TextView).textSize)
            reference.textSize = 14f
            for (name in listOf("all", "liked", "search", "refresh", "more"))
                assertEquals("$label: native action 14sp", reference.textSize, (field(activity, name) as TextView).textSize)
            // The complete message may exceed a compact viewport. Reveal every
            // full native text line through the ordinary ScrollView, not a cap.
            for (line in 0 until empty.lineCount) {
                val top = empty.totalPaddingTop + empty.layout.getLineTop(line)
                val bottom = empty.totalPaddingTop + empty.layout.getLineBottom(line)
                empty.requestRectangleOnScreen(Rect(0, top, empty.width, bottom), true)
                measure(root, compact)
                val visible = Rect()
                assertTrue("$label: message line $line visible", empty.getLocalVisibleRect(visible))
                assertTrue("$label: complete message line $line", visible.top <= top && visible.bottom >= bottom)
            }
            assertEquals("$label: no phantom rows", 0, adapter.itemCount)
        }
    }

    @Test fun normalEmptyRecoveryBeforeAndAfterDock() { recovery(false) }
    @Test fun compactEmptyRecoveryBeforeAndAfterDock() { recovery(true) }

    /** Exact effective 311px content from the failed device capture. Detached
     * component constraints, NOT software-keyboard or input-dispatch acceptance. */
    @Test fun compactKeyboardConstrainedRecoveryFamily() { keyboardFamily(true) }
    @Test fun normalKeyboardConstrainedRecoveryFamily() { keyboardFamily(false) }
    private fun keyboardFamily(compact: Boolean) {
        shell(compact) { activity, root, list, adapter ->
            val messages = linkedMapOf("populated" to "", "empty" to "No liked tracks match. Choose All tracks or change your search.",
                "noMatch" to "No tracks match. Change your search and try again.",
                "refusal" to "Library couldn't load. Use Refresh to try again.")
            for (height in listOf(311, if (compact) 1120 else 2400)) for (selected in listOf(true, false)) for ((state, message) in messages) {
                field(activity, "dock").visibility = if (selected) View.VISIBLE else View.GONE
                val empty = field(activity, "empty") as TextView
                empty.text = message; empty.visibility = if (message.isEmpty()) View.GONE else View.VISIBLE
                val status = field(activity, "status") as TextView
                status.text = if (state == "refusal") "Search is too long. Shorten it and search again." else if (state == "populated") "1 of 500 tracks" else "0 of 0 tracks"
                adapter.submitList(null); adapter.submitList(if (state == "populated") listOf(row()) else emptyList())
                shadowOf(Looper.getMainLooper()).idle()
                measure(root, compact, height)
                val label = "keyboard content=$height compact=$compact selected=$selected state=$state"
                println("$label root=${root.height} shell=${(root.parent as? View)?.height} library=${field(activity, "library").height} tools=${(field(activity, "query").parent.parent as View).height} list=${list.height} dock=${field(activity, "dock").height}")
                for (name in listOf("query", "search", "refresh")) {
                    val view = field(activity, name)
                    var ancestor = view.parent
                    while (ancestor is View) {
                        if (ancestor is ScrollView) assertTrue("$label/$name: ancestor admits complete cell", ancestor.height >= view.height)
                        ancestor = ancestor.parent
                    }
                    view.requestRectangleOnScreen(Rect(0, 0, view.width, view.height), true)
                    measure(root, compact, height)
                    val rect = Rect()
                    assertTrue("$label/$name: native reveal", view.getLocalVisibleRect(rect))
                    assertEquals("$label/$name: complete height", view.height, rect.height())
                    assertEquals("$label/$name: complete width", view.width, rect.width())
                    // Constrained shell may scroll rows out while editing. Keep a
                    // finite lazy row viewport; simultaneous visibility is not required.
                    if (state == "populated") {
                        assertTrue("$label: finite row viewport", list.height > 0 && list.height <= root.height)
                        assertNotNull("$label: lazy mounted row", list.findViewHolderForAdapterPosition(0))
                    }
                }
                val query = field(activity, "query") as android.widget.EditText
                assertTrue("$label: ordinary focus", query.requestFocus())
                assertTrue("$label: native editor", query.onCheckIsTextEditor())
                assertNotNull("$label: native input connection", query.onCreateInputConnection(android.view.inputmethod.EditorInfo()))
                query.requestRectangleOnScreen(Rect(0, 0, query.width, query.height), true)
                measure(root, compact, height)
                val visible = Rect(); assertTrue("$label: focused editor visible", query.getLocalVisibleRect(visible))
                assertEquals("$label: focused editor complete", query.height, visible.height())
                val reference = TextView(activity).apply { textSize = 16f }
                assertEquals("$label: native query font", reference.textSize, query.textSize)
                for (feedback in listOf(status, empty).filter { it.visibility == View.VISIBLE }) {
                    assertEquals("$label: no feedback cap", Int.MAX_VALUE, feedback.maxLines)
                    assertNull("$label: no feedback truncation", feedback.ellipsize)
                    for (line in 0 until feedback.lineCount) {
                        val top = feedback.totalPaddingTop + feedback.layout.getLineTop(line)
                        val bottom = feedback.totalPaddingTop + feedback.layout.getLineBottom(line)
                        feedback.requestRectangleOnScreen(Rect(0, top, feedback.width, bottom), true)
                        measure(root, compact, height)
                        val rect = Rect(); assertTrue("$label: feedback visible", feedback.getLocalVisibleRect(rect))
                        assertTrue("$label: full feedback line", rect.top <= top && rect.bottom >= bottom)
                    }
                }
                println("$label query=${query.height} list=${list.height}")
            }
        }
    }

    /** Actual usable content, not nominal display height. Each pass and each
     * clipping scroll ancestor must admit a full native control, with no cap. */
    @Test fun compactPostRefusalCorrectionAllocation() = shell(true) { activity, root, list, adapter ->
        val query = field(activity, "query") as android.widget.EditText
        val status = field(activity, "status") as TextView
        val empty = field(activity, "empty") as TextView
        val refusal = "Search is too long. Shorten it and search again."
        fun geometry() = listOf(root, root.parent as View, field(activity, "library"),
            query.parent.parent as View, list, field(activity, "dock"), query, status).map {
            listOf(it.measuredHeight, it.height, it.minimumHeight)
        }
        fun stable(height: Int, label: String) {
            measure(root, true, height)
            val expected = geometry()
            repeat(6) {
                measure(root, true, height)
                assertEquals("$label: stable repeated native allocation pass=$it", expected, geometry())
            }
            assertTrue("$label: finite weighted lazy rows", list.height > 0 && list.height <= root.height)
            assertTrue("$label: RecyclerView remains weighted", (list.layoutParams as LinearLayout.LayoutParams).weight > 0)
            println("$label geometry=$expected query=${query.height} statusLines=${status.lineCount} status=${status.text}")
        }
        fun full(view: View, height: Int, label: String) {
            var parent = view.parent
            while (parent is View) {
                if (parent is ScrollView) {
                    assertTrue("$label: ancestor admits complete native cell", parent.height - parent.paddingTop - parent.paddingBottom >= view.height)
                    assertTrue("$label: ancestor admits complete native width", parent.width - parent.paddingLeft - parent.paddingRight >= view.width)
                }
                parent = parent.parent
            }
            view.requestRectangleOnScreen(Rect(0, 0, view.width, view.height), true)
            measure(root, true, height)
            val visible = Rect()
            assertTrue("$label: native reveal", view.getLocalVisibleRect(visible))
            assertEquals("$label: full local visible cell", Rect(0, 0, view.width, view.height), visible)
            parent = view.parent
            while (parent is ViewGroup) {
                if (parent is ScrollView) {
                    val cell = Rect(0, 0, view.width, view.height)
                    parent.offsetDescendantRectToMyCoords(view, cell)
                    val clip = Rect(); assertTrue("$label: ancestor visible", parent.getLocalVisibleRect(clip))
                    assertTrue("$label: full cell through each scroll ancestor cell=$cell clip=$clip", clip.contains(cell))
                }
                parent = parent.parent
            }
        }
        val messages = linkedMapOf("refusal" to "Library couldn't load. Use Refresh to try again.",
            "populated" to "", "loading" to "Loading your library…",
            "empty" to "No liked tracks match. Choose All tracks or change your search.",
            "no-match" to "No tracks match. Change your search and try again.")
        // First iteration exactly reproduces the stopped keyboard-hidden failure.
        for (height in listOf(1057, 311, 1120, 1057)) for (selected in listOf(true, false)) for ((state, message) in messages) {
            field(activity, "dock").visibility = if (selected) View.VISIBLE else View.GONE
            empty.text = message; empty.visibility = if (message.isEmpty()) View.GONE else View.VISIBLE
            status.text = if (state == "refusal") refusal else if (state == "loading") "Loading Library… Showing your previous results." else "1 of 500 tracks"
            adapter.submitList(null); adapter.submitList(if (state == "populated" || state == "loading") listOf(row()) else emptyList())
            shadowOf(Looper.getMainLooper()).idle()
            val label = "correction content=$height selected=$selected state=$state"
            stable(height, label)
            for (name in listOf("query", "all", "liked", "search", "refresh", "more") + if (selected) listOf("play", "seek", "previous", "next") else emptyList())
                full(field(activity, name), height, "$label/$name")
            for (feedback in listOf(status, empty).filter { it.visibility == View.VISIBLE }) {
                assertEquals("$label: uncapped full feedback", Int.MAX_VALUE, feedback.maxLines)
                assertNull("$label: untruncated full feedback", feedback.ellipsize)
                for (line in 0 until feedback.lineCount) {
                    val top = feedback.totalPaddingTop + feedback.layout.getLineTop(line)
                    val bottom = feedback.totalPaddingTop + feedback.layout.getLineBottom(line)
                    feedback.requestRectangleOnScreen(Rect(0, top, feedback.width, bottom), true)
                    measure(root, true, height)
                    val visible = Rect(); assertTrue(feedback.getLocalVisibleRect(visible))
                    assertTrue("$label: complete feedback line=$line", visible.left == 0 && visible.right == feedback.width && visible.top <= top && visible.bottom >= bottom)
                }
            }
            assertEquals(message, empty.text.toString())
            val reference = TextView(activity).apply { textSize = 16f }
            assertEquals(reference.textSize, query.textSize); assertEquals(reference.textSize, empty.textSize)
            reference.textSize = 13f; assertEquals(reference.textSize, status.textSize)
            reference.textSize = 14f
            for (name in listOf("all", "liked", "search", "refresh", "more")) assertEquals(reference.textSize, (field(activity, name) as TextView).textSize)
        }
        field(activity, "dock").visibility = View.VISIBLE
        status.text = refusal; empty.visibility = View.VISIBLE; empty.text = messages.getValue("refusal")
        query.setText("z".repeat(513)); stable(1057, "refusal to editing")
        full(query, 1057, "refusal to editing/query")
        assertTrue(query.requestFocus())
        val connection = query.onCreateInputConnection(android.view.inputmethod.EditorInfo())!!
        stable(311, "focused editing")
        full(query, 311, "focused editing/query")
        assertTrue(query.hasFocus()); assertTrue(connection.setSelection(0, query.text.length))
        assertTrue(connection.commitText("Native Fixture 500", 1)); assertEquals("Native Fixture 500", query.text.toString())
        status.text = "1 of 1 tracks"; empty.visibility = View.GONE
        adapter.submitList(null); adapter.submitList(listOf(row("Native Fixture 500")))
        shadowOf(Looper.getMainLooper()).idle()
        stable(311, "corrected focused result"); full(query, 311, "corrected focused result/query")
        // Component restoration; real software keyboard and Back are device gates.
        query.clearFocus(); stable(1057, "Back-sized restoration")
        full(query, 1057, "Back-sized restoration/query"); full(field(activity, "play"), 1057, "Back-sized restoration/play")
        assertEquals("Native Fixture 500", query.text.toString()); assertEquals(1, adapter.itemCount)
    }

    @Test fun realPlayNativePrimaryRasterAllStates() = shell(false) { activity, root, _, _ ->
        field(activity, "dock").visibility = View.VISIBLE
        measure(root, false)
        val play = field(activity, "play")
        val style = SoundQViews(activity)
        assertTrue("real play mounted in production dock", play.parent is LinearLayout && play.width > 0)
        assertEquals("real play semantic identity", "Play", play.contentDescription)
        assertTrue("real play keeps listener", play.hasOnClickListeners())
        val states = linkedMapOf("rest" to intArrayOf(android.R.attr.state_enabled),
            "focus" to intArrayOf(android.R.attr.state_enabled, android.R.attr.state_focused),
            "hover" to intArrayOf(android.R.attr.state_enabled, android.R.attr.state_hovered),
            "pressed" to intArrayOf(android.R.attr.state_enabled, android.R.attr.state_pressed),
            "disabled" to intArrayOf(-android.R.attr.state_enabled))
        for ((name, state) in states) {
            style.availability(play, name != "disabled")
            val drawable = play.background // actual production ImageButton, including its tint
            drawable.state = state
            drawable.setBounds(0, 0, 200, 120)
            drawable.jumpToCurrentState()
            val bitmap = Bitmap.createBitmap(200, 120, Bitmap.Config.ARGB_8888)
            drawable.draw(Canvas(bitmap))
            assertEquals("primary state=$name orange fill", style.orange, bitmap.getPixel(100, 60))
            val edge = if (name in listOf("focus", "hover", "pressed")) style.cyan else style.orange
            for ((x, y) in listOf(0 to 0, 199 to 0, 0 to 119, 199 to 119, 100 to 0))
                assertEquals("primary state=$name square state stroke $x,$y", edge, bitmap.getPixel(x, y))
            println("primary state=$name center=${bitmap.getPixel(100, 60)} edge=${bitmap.getPixel(100, 0)} alpha=${play.alpha}")
            bitmap.recycle()
        }
    }

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
