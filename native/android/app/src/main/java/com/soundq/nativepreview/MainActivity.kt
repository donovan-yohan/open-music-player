package com.soundq.nativepreview

import android.Manifest
import android.app.Activity
import android.content.*
import android.os.*
import android.graphics.Color
import android.text.InputType
import android.view.*
import android.widget.*
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import org.json.JSONObject

class MainActivity : Activity() {
    private var service: PlaybackService? = null
    private lateinit var login: LinearLayout
    private lateinit var library: LinearLayout
    private lateinit var status: TextView
    private lateinit var title: TextView
    private lateinit var email: EditText
    private lateinit var password: EditText
    private lateinit var query: EditText
    private lateinit var play: Button
    private lateinit var seek: SeekBar
    private lateinit var logout: Button
    private var dragging = false
    private val rows = Rows { id -> service?.select(id) }
    internal var fixtureList: RecyclerView? = null
        private set
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            service = (binder as PlaybackService.LocalBinder).service
            service?.listener = { snapshot, error -> render(snapshot, error) }
            service?.let { render(it.snapshot, null) }
        }
        override fun onServiceDisconnected(name: ComponentName) { service = null }
    }
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        window.statusBarColor = Color.rgb(13, 20, 28)
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(24, 28, 24, 20); setBackgroundColor(Color.rgb(13, 20, 28)) }
        title = label("SoundQ", 26f); root.addView(title)
        status = label("", 14f)
        login = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        email = EditText(this).apply { hint = "Email"; inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS; setSingleLine() }
        password = EditText(this).apply { hint = "Password"; inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD; setSingleLine() }
        login.addView(email); login.addView(password)
        login.addView(button("Sign in") { service?.login(email.text.toString(), password.text.toString()); password.text.clear() })
        root.addView(login)
        library = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val bar = LinearLayout(this)
        query = EditText(this).apply { hint = "Search library"; setSingleLine(); imeOptions = android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH
            setOnEditorActionListener { _, _, _ -> service?.library(query = text.toString()); true } }
        bar.addView(query, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        bar.addView(button("Search") { service?.library(query = query.text.toString()) })
        library.addView(bar)
        val list = RecyclerView(this).apply { layoutManager = LinearLayoutManager(this@MainActivity); adapter = rows; itemAnimator = null }
        fixtureList = list
        library.addView(list, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        val paging = LinearLayout(this)
        paging.addView(button("Refresh") { service?.library(query = query.text.toString()) })
        paging.addView(button("Load more") { service?.library(rows.currentList.size, query.text.toString()) })
        logout = button("Sign out") { service?.logout() }; paging.addView(logout)
        library.addView(paging)
        root.addView(library, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        root.addView(status)
        val controls = LinearLayout(this)
        play = button("Play") { service?.let { it.command(JSONObject().put("command", if (it.snapshot.optString("transport") == "playing") "pause" else "resume")) } }
        controls.addView(play); controls.addView(button("Retry") { service?.command(JSONObject().put("command", "retry")) })
        root.addView(controls)
        seek = SeekBar(this).apply { max = 10000; contentDescription = "Playback position"
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onStartTrackingTouch(bar: SeekBar) { dragging = true }
                override fun onStopTrackingTouch(bar: SeekBar) {
                    dragging = false
                    val duration = service?.snapshot?.optLong("duration_ms") ?: 0
                    service?.command(JSONObject().put("command", "seek").put("position_ms", duration * bar.progress / 10000))
                }
                override fun onProgressChanged(bar: SeekBar, progress: Int, fromUser: Boolean) {}
            }) }
        root.addView(seek)
        root.addView(label("Native preview · Rust ABI 1 · ${BuildConfig.SOURCE_REF}", 10f))
        setContentView(root)
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        bindService(Intent(this, PlaybackService::class.java), connection, BIND_AUTO_CREATE)
    }
    private fun label(value: String, size: Float) = TextView(this).apply { text = value; textSize = size; setTextColor(Color.rgb(225, 235, 243)); setPadding(4, 8, 4, 8) }
    private fun button(value: String, action: () -> Unit) = Button(this).apply { text = value; setOnClickListener { action() } }
    private fun render(snapshot: JSONObject, error: String?) {
        val authenticated = snapshot.optBoolean("authenticated")
        login.visibility = if (authenticated) View.GONE else View.VISIBLE
        library.visibility = if (authenticated) View.VISIBLE else View.GONE
        val values = snapshot.optJSONArray("library")
        val next = if (snapshot.optBoolean("library_unchanged") && rows.currentList.isNotEmpty()) rows.currentList else (0 until (values?.length() ?: 0)).map { index ->
            val row = values!!.getJSONObject(index)
            Row(row.getLong("id"), row.getString("title"), if (row.isNull("artist")) "Unknown artist" else row.optString("artist"))
        }
        if (next != rows.currentList) rows.submitList(next)
        val current = snapshot.optJSONArray("queue")?.optJSONObject(0)?.optJSONObject("track")?.optString("title")
        title.text = current ?: "SoundQ / Library"
        status.text = (error ?: snapshot.optString("error").takeUnless { it == "null" || it.isBlank() })?.replace('_', ' ')
            ?: "${next.size} of ${snapshot.optLong("total")} tracks · ${snapshot.optString("transport")}" 
        play.text = if (snapshot.optString("transport") == "playing") "Pause" else "Play"
        play.isEnabled = current != null
        seek.isEnabled = current != null
        if (!dragging) { val duration = snapshot.optLong("duration_ms"); seek.progress = if (duration > 0) (snapshot.optLong("position_ms") * 10000 / duration).toInt() else 0 }
    }
    override fun onDestroy() { service?.listener = null; unbindService(connection); super.onDestroy() }
    data class Row(val id: Long, val title: String, val artist: String)
    class Rows(private val select: (Long) -> Unit) : ListAdapter<Row, Rows.Holder>(object : DiffUtil.ItemCallback<Row>() {
        override fun areItemsTheSame(a: Row, b: Row) = a.id == b.id
        override fun areContentsTheSame(a: Row, b: Row) = a == b
    }) {
        init { setHasStableIds(true) }
        override fun getItemId(position: Int) = getItem(position).id
        class Holder(val view: TextView) : RecyclerView.ViewHolder(view)
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = Holder(TextView(parent.context).apply {
            textSize = 16f; setTextColor(Color.WHITE); setPadding(12, 20, 12, 20); minHeight = 72
            isFocusable = true; isClickable = true
            val attrs = parent.context.obtainStyledAttributes(intArrayOf(android.R.attr.selectableItemBackground)); background = attrs.getDrawable(0); attrs.recycle()
        })
        override fun onBindViewHolder(holder: Holder, position: Int) { val row = getItem(position); holder.view.text = "${row.title}\n${row.artist}"; holder.view.setOnClickListener { select(row.id) } }
    }
}
