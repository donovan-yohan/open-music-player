package com.soundq.nativepreview

import android.content.ComponentName
import android.graphics.Rect
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.ScrollView
import android.widget.TextView
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Actual Activity controls; refused service bind means no JNI/account/audio launch. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class RegistrationPresentationTest {
    private fun field(a: MainActivity, name: String) = MainActivity::class.java.getDeclaredField(name).apply {isAccessible=true}.get(a) as View
    private fun family(compact: Boolean) {
        RuntimeEnvironment.setQualifiers(if(compact) "w411dp-h426dp-420dpi" else "w411dp-h914dp-420dpi")
        RuntimeEnvironment.setFontScale(if(compact) 1.6f else 1f)
        val app=RuntimeEnvironment.getApplication()
        shadowOf(app).declareComponentUnbindable(ComponentName(app,PlaybackService::class.java))
        val controller=Robolectric.buildActivity(MainActivity::class.java).setup().visible()
        val a=controller.get()
        try {
            val content=a.findViewById<ViewGroup>(android.R.id.content).getChildAt(0) as ScrollView
            (content.parent as ViewGroup).removeView(content)
            val root=content.getChildAt(0) as ViewGroup
            field(a,"library").visibility=View.GONE;field(a,"dock").visibility=View.GONE
            field(a,"libraryNavigation").visibility=View.GONE;field(a,"queueNavigation").visibility=View.GONE
            (field(a,"status") as TextView).text=""
            val scroll=field(a,"login").parent as ScrollView
            fun measure(height:Int) {repeat(3) {content.measure(View.MeasureSpec.makeMeasureSpec(1080,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(height,View.MeasureSpec.EXACTLY));content.layout(0,0,1080,height)}}
            for(height in if(compact) listOf(1120,311,1057) else listOf(2400,1427)) {
                for(stage in listOf("empty","errors","pending","refused")) {
                    val state=AuthFormState();state.changeMode(AuthFormState.Mode.REGISTER)
                    if(stage=="errors") state.begin("","","","",1,1)
                    if(stage=="pending" || stage=="refused") {val ticket=state.begin("abc","a@b.co","secret-123","secret-123",1,1)!!;if(stage=="refused")state.finish(ticket,false,"network_unavailable",1,1)}
                    a.updateAuth(state,true);measure(height)
                    val label="auth compact=$compact height=$height stage=$stage"
                    assertEquals(View.VISIBLE,field(a,"username").visibility);assertEquals(View.VISIBLE,field(a,"confirmation").visibility)
                    assertFalse((field(a,"password") as EditText).isSaveEnabled);assertFalse((field(a,"confirmation") as EditText).isSaveEnabled)
                    for(name in listOf("username","email","password","confirmation","authFeedback","authSubmit","authMode")) {
                        val v=field(a,name)
                        if(v.height==0 && name=="authFeedback" && stage=="empty")continue
                        assertTrue("$label/$name: nonempty native allocation",v.width>0 && v.height>0)
                        assertTrue("$label/$name: ancestor admits complete cell",scroll.height>=v.height)
                        v.requestRectangleOnScreen(Rect(0,0,v.width,v.height),true);measure(height)
                        val rect=Rect();assertTrue("$label/$name: revealable",v.getLocalVisibleRect(rect))
                        assertEquals("$label/$name: complete width",v.width,rect.width());assertEquals("$label/$name: complete height",v.height,rect.height())
                        if(name!="authFeedback")assertEquals("$label/$name pending",stage!="pending",v.isEnabled)
                    }
                    val reference=TextView(a).apply {textSize=16f}
                    assertEquals(reference.textSize,(field(a,"password") as TextView).textSize)
                    assertTrue("$label: bounded scroll document",scroll.getChildAt(0).height>=scroll.height)
                    for(purpose in listOf("Username","Email","Password","Confirm password")) {
                        val persistent=visibleText(field(a,"login"),purpose)
                        assertEquals("REG-LABELS $label/$purpose persistent in empty/error/pending",1,persistent.size)
                        reveal(persistent.single(),::measure,height,"REG-LABELS $label/$purpose")
                    }
                    if(stage=="errors")assertNotNull((field(a,"username") as EditText).error)
                    if(stage=="refused")assertTrue((field(a,"authFeedback") as TextView).text.contains("unconfirmed"))
                    println(label)
                }
            }
            assertNull(shadowOf(app).peekNextStartedService())
        } finally {controller.pause().stop().destroy()}
    }
    private fun descendants(v: View): List<View> = listOf(v) + if(v is ViewGroup) (0 until v.childCount).flatMap {descendants(v.getChildAt(it))} else emptyList()
    private fun presentation(compact: Boolean = false, body: (MainActivity, ScrollView, (Int) -> Unit) -> Unit) {
        RuntimeEnvironment.setQualifiers(if(compact) "w411dp-h426dp-420dpi" else "w411dp-h914dp-420dpi")
        RuntimeEnvironment.setFontScale(if(compact) 1.6f else 1f)
        val app=RuntimeEnvironment.getApplication()
        shadowOf(app).declareComponentUnbindable(ComponentName(app,PlaybackService::class.java))
        val controller=Robolectric.buildActivity(MainActivity::class.java).setup().visible()
        val a=controller.get()
        try {
            val content=a.findViewById<ViewGroup>(android.R.id.content).getChildAt(0) as ScrollView
            (content.parent as ViewGroup).removeView(content)
            val measure: (Int) -> Unit = {height -> repeat(3) {
                content.measure(View.MeasureSpec.makeMeasureSpec(1080,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(height,View.MeasureSpec.EXACTLY))
                content.layout(0,0,1080,height)
            }}
            body(a,content,measure)
            assertNull("No service/JNI started",shadowOf(app).peekNextStartedService())
        } finally {controller.pause().stop().destroy()}
    }
    private fun visibleText(root: View, value: String) = descendants(root).filterIsInstance<TextView>().filter {it !is EditText && it.text.toString()==value && it.visibility==View.VISIBLE}
    private fun reveal(v: View, measure: (Int) -> Unit, height: Int, tag: String) {
        v.requestRectangleOnScreen(Rect(0,0,v.width,v.height),true);measure(height)
        val rect=Rect()
        assertTrue("$tag nonempty",v.width>0 && v.height>0)
        assertTrue("$tag visible",v.getLocalVisibleRect(rect))
        assertEquals("$tag full width",v.width,rect.width());assertEquals("$tag full height",v.height,rect.height())
        if(v is TextView) {
            assertNotNull("$tag native text layout",v.layout)
            for(i in 0 until v.layout.lineCount) assertEquals("$tag no ellipsis",0,v.layout.getEllipsisCount(i))
            assertTrue("$tag complete glyph line height",v.layout.height<=v.height-v.compoundPaddingTop-v.compoundPaddingBottom)
        }
    }
    private fun modeInstruction(compact: Boolean) = presentation(compact) {a,_,measure ->
        val state=AuthFormState()
        val login=field(a,"login")
        for(mode in listOf(AuthFormState.Mode.SIGN_IN,AuthFormState.Mode.REGISTER,AuthFormState.Mode.SIGN_IN)) {
            val height=if(compact) 1120 else 1920
            state.changeMode(mode);a.updateAuth(state,true);measure(height)
            val registration=mode==AuthFormState.Mode.REGISTER
            val expected=if(registration) "Create an account on your music server." else "Sign in to your music server."
            val labels=visibleText(login,expected)
            assertEquals("REG-MODE correct instruction for $mode",1,labels.size)
            assertTrue("REG-MODE no opposite instruction",visibleText(login,if(registration) "Sign in to your music server." else "Create an account on your music server.").isEmpty())
            reveal(labels.single(),measure,height,"REG-MODE $mode compact=$compact")
            assertEquals(if(registration) "Create account" else "Sign in",(field(a,"authSubmit") as TextView).text.toString())
            assertEquals(if(registration) "Back to sign in" else "Create account",(field(a,"authMode") as TextView).text.toString())
        }
    }
    @Test fun modeInstructionFollowsActualForm() = modeInstruction(false)
    @Test fun enlargedCompactModeInstructionFollowsActualForm() = modeInstruction(true)
    private fun populatedLabels(compact: Boolean) = presentation(compact) {a,_,measure ->
        val state=AuthFormState();state.changeMode(AuthFormState.Mode.REGISTER);a.updateAuth(state,true)
        val login=field(a,"login") as ViewGroup
        val fields=listOf("username" to "Username","email" to "Email","password" to "Password","confirmation" to "Confirm password")
        val identities=fields.associate {it.first to field(a,it.first)}
        val suppress=MainActivity::class.java.getDeclaredField("suppressAuthEdit").apply {isAccessible=true}
        suppress.setBoolean(a,true)
        fields.forEach {(name,_) -> (field(a,name) as EditText).setText(if(name=="email") "listener@example.test" else if(name=="username") "Listener" else "secret-123")}
        suppress.setBoolean(a,false)
        for(height in if(compact) listOf(1120,311,1057) else listOf(1920,1427)) {
            measure(height)
            for((name,purpose) in fields) {
                val editor=field(a,name) as EditText
                assertSame("REG-LABELS retains native editor",identities[name],editor)
                val labels=visibleText(login,purpose)
                assertEquals("REG-LABELS persistent populated $purpose",1,labels.size)
                val label=labels.single()
                assertEquals("REG-LABELS accessible association",editor.id,label.labelFor)
                assertNotEquals(View.NO_ID,editor.id)
                assertSame("REG-LABELS unchanged field parent",login,editor.parent)
                assertTrue(editor.requestFocus());editor.setSelection(3);measure(height)
                assertTrue("REG-LABELS native focus/caret",editor.hasFocus() && editor.isCursorVisible)
                assertEquals(3,editor.selectionStart);assertEquals(3,editor.selectionEnd)
                assertTrue("REG-LABELS native Done",editor.imeOptions and android.view.inputmethod.EditorInfo.IME_MASK_ACTION == android.view.inputmethod.EditorInfo.IME_ACTION_DONE)
                if(name=="password" || name=="confirmation") {
                    assertTrue("REG-LABELS secure native transformation",editor.transformationMethod is android.text.method.PasswordTransformationMethod)
                    assertFalse(editor.isSaveEnabled)
                    assertFalse("REG-LABELS masked value",editor.transformationMethod.getTransformation(editor.text,editor).toString().contains("secret"))
                }
                val labelSize=TextView(a).apply {textSize=14f}.textSize
                assertEquals("REG-LABELS no label font shrink",labelSize,label.textSize)
                assertEquals(TextView(a).apply {textSize=16f}.textSize,editor.textSize)
                val pair=Rect(editor.left,label.top,editor.right,editor.bottom)
                login.requestRectangleOnScreen(pair,true);measure(height)
                reveal(label,measure,height,"REG-LABELS $compact/$height/$purpose label")
                val editorRect=Rect();assertTrue(editor.getLocalVisibleRect(editorRect))
                assertEquals("REG-LABELS complete paired editor",editor.height,editorRect.height())
                assertEquals(editor.width,editorRect.width())
                assertEquals("REG-LABELS full-width track",login.width-login.paddingLeft-login.paddingRight,editor.width)
                assertTrue("REG-LABELS label adjacent above editor",label.bottom<=editor.top)
            }
            for(name in listOf("authSubmit","authMode"))reveal(field(a,name),measure,height,"REG-LABELS $name")
        }
        state.changeMode(AuthFormState.Mode.SIGN_IN);a.updateAuth(state,true);measure(1120)
        for(purpose in listOf("Username","Confirm password"))assertTrue("REG-LABELS no orphan sign-in $purpose",visibleText(login,purpose).isEmpty())
        for(purpose in listOf("Email","Password"))assertEquals(1,visibleText(login,purpose).size)
    }
    @Test fun normalPopulatedLabelsRetainSecureNativeEditing() = populatedLabels(false)
    @Test fun enlargedCompactPopulatedLabelsRetainSecureNativeEditing() = populatedLabels(true)
    private fun render(a: MainActivity, authenticated: Boolean, code: String? = null, retainedError: String = "") {
        val snapshot=org.json.JSONObject().put("authenticated",authenticated).put("error",retainedError).put("total",0)
        MainActivity::class.java.getDeclaredMethod("render",org.json.JSONObject::class.java,String::class.java).apply {isAccessible=true}.invoke(a,snapshot,code)
    }
    private fun feedback(compact: Boolean) = presentation(compact) {a,content,measure ->
        val status=field(a,"status") as TextView
        // The first refused-bind frame is unauthenticated too, not a Library count.
        assertEquals("REG-FEEDBACK initial auth has no Library status",View.GONE,status.visibility)
        val state=AuthFormState();state.changeMode(AuthFormState.Mode.REGISTER)
        for(height in if(compact) listOf(1120,311,1057) else listOf(1920,1427)) {
            for(stage in listOf("empty","errors","pending","refused","unconfirmed")) {
                state.changeMode(AuthFormState.Mode.REGISTER)
                if(stage=="errors")state.begin("","","","",1,1)
                if(stage in listOf("pending","refused","unconfirmed")) {
                    val ticket=state.begin("abc","a@b.co","secret-123","secret-123",1,1)!!
                    if(stage!="pending")state.finish(ticket,false,if(stage=="refused") "http_409" else "network_unavailable",1,1)
                }
                render(a,false,if(stage=="refused") "http_409" else if(stage=="unconfirmed") "network_unavailable" else null)
                a.updateAuth(state,true);measure(height)
                val expected=when(stage) {
                    "errors" -> "Please enter a username"
                    "pending" -> "Please wait…"
                    "refused" -> "Account creation was refused. Check your details or sign in."
                    "unconfirmed" -> "Account creation is unconfirmed. Sign in to check before trying again."
                    else -> ""
                }
                assertEquals("REG-FEEDBACK $stage auth-only status",View.GONE,status.visibility)
                assertEquals("REG-FEEDBACK $stage no stale counter/recovery bytes","",status.text.toString())
                assertEquals(expected,(field(a,"authFeedback") as TextView).text.toString())
                if(expected.isNotEmpty()) {
                    assertEquals("REG-FEEDBACK feedback appears once",1,visibleText(content,expected).size)
                    reveal(field(a,"authFeedback"),measure,height,"REG-FEEDBACK $stage $height")
                }
                assertEquals("REG-FEEDBACK no unauthenticated Library",View.GONE,field(a,"library").visibility)
                assertEquals(View.VISIBLE,(field(a,"login").parent as View).visibility)
                for(name in listOf("authSubmit","authMode")) {
                    assertEquals(stage!="pending",field(a,name).isEnabled)
                    reveal(field(a,name),measure,height,"REG-FEEDBACK $stage $name")
                }
                if(stage=="pending") {
                    val ticket=state.pending!!;state.finish(ticket,false,"http_409",1,1)
                }
                state.edited();a.updateAuth(state,true)
                assertEquals("REG-FEEDBACK edit retires actual auth failure","",(field(a,"authFeedback") as TextView).text.toString())
            }
        }
        state.changeMode(AuthFormState.Mode.SIGN_IN);a.updateAuth(state,true);measure(1120)
        assertEquals("Sign in",(field(a,"authSubmit") as TextView).text.toString())
        val connection=MainActivity::class.java.getDeclaredField("connection").apply {isAccessible=true}.get(a) as android.content.ServiceConnection
        connection.onServiceDisconnected(ComponentName(a,PlaybackService::class.java));measure(1120)
        assertEquals("REG-FEEDBACK unauth disconnect no playback recovery",View.GONE,status.visibility)
        assertEquals("",status.text.toString())
        assertEquals("REG-FEEDBACK genuine connection failure has auth recovery","Connection lost. Reopen SoundQ to reconnect.",(field(a,"authFeedback") as TextView).text.toString())
        reveal(field(a,"authFeedback"),measure,1120,"REG-FEEDBACK disconnected recovery")
        assertFalse(field(a,"authSubmit").isEnabled);assertFalse(field(a,"authMode").isEnabled)
        render(a,false,"http_409")
        render(a,true,null,"http_409");measure(1120)
        assertEquals("REG-FEEDBACK authenticated empty count retained",View.VISIBLE,status.visibility)
        assertEquals("REG-FEEDBACK hidden auth errors never resurrect","0 of 0 tracks",status.text.toString())
        assertEquals(View.GONE,(field(a,"login").parent as View).visibility)
        assertEquals(View.VISIBLE,field(a,"library").visibility)
        assertEquals("Your library is empty. Refresh after adding music to your server.",(field(a,"empty") as TextView).text.toString())
        assertEquals("",(field(a,"authFeedback") as TextView).text.toString())
        render(a,true,"network_unavailable");measure(1120)
        assertEquals("REG-FEEDBACK real authenticated failure remains",LibraryBrowseState.feedback("network_unavailable"),status.text.toString())
        assertEquals(View.VISIBLE,status.visibility)
        connection.onServiceDisconnected(ComponentName(a,PlaybackService::class.java));measure(1120)
        assertEquals("Playback disconnected. Reopen SoundQ to reconnect.",status.text.toString())
        assertEquals(View.VISIBLE,status.visibility)
        render(a,false,null,"network_unavailable");render(a,true,null,"network_unavailable");measure(1120)
        assertEquals("REG-FEEDBACK successful account transition clears hidden failure","0 of 0 tracks",status.text.toString())
    }
    @Test fun normalAuthScopedFeedbackAndAuthenticatedEmptyTransition() = feedback(false)
    @Test fun enlargedCompactAuthScopedFeedbackAndAuthenticatedEmptyTransition() = feedback(true)
    @Test fun normalAuthFormErrorsPendingAndKeyboard() = family(false)
    @Test fun enlargedCompactAuthFormErrorsPendingAndKeyboard() = family(true)
}
