package com.soundq.nativepreview

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.*
import android.content.res.ColorStateList
import android.os.*
import android.text.InputType
import android.view.*
import android.view.inputmethod.EditorInfo
import android.widget.*
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import org.json.JSONObject

class MainActivity : Activity() {
    private var service: PlaybackService? = null
    private lateinit var style: SoundQViews
    private lateinit var login: LinearLayout
    private lateinit var library: LinearLayout
    private lateinit var status: TextView
    private lateinit var empty: TextView
    private lateinit var title: TextView
    private lateinit var artist: TextView
    private lateinit var time: TextView
    private lateinit var email: EditText
    private lateinit var password: EditText
    private lateinit var query: EditText
    private lateinit var play: ImageButton
    private lateinit var previous: ImageButton
    private lateinit var next: ImageButton
    private lateinit var retry: Button
    private lateinit var seek: SeekBar
    private lateinit var all: Button
    private lateinit var liked: Button
    private lateinit var refresh: Button
    private lateinit var more: Button
    private lateinit var search: Button
    private lateinit var libraryNavigation: Button
    private lateinit var queueNavigation: Button
    private lateinit var dock: BoundedScroll
    private lateinit var rows: Rows
    private var dragging = false
    private var uiError: String? = null
    private var dockIdentity: String? = null
    private var playIdentity: String? = null
    private var queueListDialog: AlertDialog? = null
    private var queueListSelection: Long? = null
    private var queueActionDialog: AlertDialog? = null
    private var queueNameDialog: AlertDialog? = null
    private var queueActions: ArrayAdapter<String>? = null
    private var accountDialog: AlertDialog? = null
    private var trackDialog: AlertDialog? = null
    internal var fixtureList: RecyclerView? = null
        private set
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            dismissQueueActions()
            service = (binder as PlaybackService.LocalBinder).service
            service?.listener = { snapshot, error -> render(snapshot, error) }
            service?.let { render(it.snapshot, null) }
        }
        override fun onServiceDisconnected(name: ComponentName) {
            dismissQueueActions(); service = null
            status.text = "Playback disconnected. Reopen SoundQ to reconnect."
            rows.submitList(rows.currentList.map { it.copy(enabled = false) })
            listOf(play,previous,next,seek,all,liked,search,refresh,more).forEach { style.availability(it,false) }
        }
    }
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        style = SoundQViews(this)
        window.statusBarColor = style.background
        window.navigationBarColor = style.background
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(style.background) }
        // Android 15 edge-to-edge, display cutouts and IME are independent of density.
        root.setOnApplyWindowInsetsListener { view, insets ->
            if(Build.VERSION.SDK_INT >= 30) {
                val safe = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout() or WindowInsets.Type.ime())
                view.setPadding(safe.left,safe.top,safe.right,safe.bottom)
            } else {
                @Suppress("DEPRECATION")
                view.setPadding(insets.systemWindowInsetLeft,insets.systemWindowInsetTop,insets.systemWindowInsetRight,insets.systemWindowInsetBottom)
            }
            insets
        }
        val brand = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL; setPadding(style.dp(16),style.dp(8),style.dp(16),style.dp(8)) }
        brand.addView(ImageView(this).apply { setImageResource(R.drawable.soundq_logo); importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO }, LinearLayout.LayoutParams(style.dp(40),style.dp(40)))
        brand.addView(style.label("SoundQ",22f).apply { typeface = style.bold; setPadding(style.dp(12),0,0,0) },LinearLayout.LayoutParams(0,-2,1f))
        brand.addView(icon(R.drawable.sq_settings,"Account and settings") { showAccount() })
        root.addView(brand)

        login = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(style.dp(16),style.dp(16),style.dp(16),style.dp(16)) }
        login.addView(style.label("Your music, together.",28f).apply { typeface = style.bold })
        login.addView(style.label("Sign in to your music server.",14f,true))
        email = input("Email").apply { inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS }
        password = input("Password").apply { inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD }
        login.addView(email); login.addView(password)
        login.addView(button("Sign in") { service?.login(email.text.toString(),password.text.toString()); password.text.clear() })
        val loginScroll = BoundedScroll(this,0.85f).apply { addView(login) }
        root.addView(loginScroll,LinearLayout.LayoutParams(-1,-2))

        library = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val tools = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(style.dp(16),0,style.dp(16),style.dp(8)) }
        tools.addView(style.label("Library",28f).apply { typeface = style.bold; setPadding(0,style.dp(8),0,style.dp(8)); if(Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true })
        query = input("Search library").apply {
            imeOptions = EditorInfo.IME_ACTION_SEARCH
            setOnEditorActionListener { _, action, event ->
                if (action == EditorInfo.IME_ACTION_SEARCH || event?.keyCode == KeyEvent.KEYCODE_ENTER && event.action == KeyEvent.ACTION_UP) {
                    browse(); true
                } else false
            }
        }
        tools.addView(query)
        all = button("All tracks") { browse(liked = false) }
        liked = button("Liked") { browse(liked = true) }
        tools.addView(actions(all,liked))
        search = button("Search") { browse() }
        refresh = button("Refresh") { browse() }
        more = button("Load more") { browse(offset = rows.currentList.size) }
        tools.addView(actions(search,refresh,more))
        val shortHeight = resources.configuration.screenHeightDp < 480
        // Reserve a real row viewport when the selected dock joins short-height chrome.
        library.addView(BoundedScroll(this,0.32f).apply { addView(tools) },
            if(shortHeight) LinearLayout.LayoutParams(-1,0,1f) else LinearLayout.LayoutParams(-1,-2))
        empty = style.label("Loading your library…",16f,true).apply {
            setPadding(style.dp(16),style.dp(24),style.dp(16),style.dp(24)); accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        library.addView(empty)
        rows = Rows(style, { row -> if(service === row.serviceOwner) service?.selectLibraryTrack(row.id,row.owner) }, { row -> if(service === row.serviceOwner) service?.favoriteLibraryTrack(row.id,row.liked,row.owner) }, { row -> showTrack(row.title,row.artist) })
        val list = RecyclerView(this).apply { layoutManager = LinearLayoutManager(this@MainActivity); adapter = rows; itemAnimator = null; clipToPadding = false }
        fixtureList = list
        library.addView(list,LinearLayout.LayoutParams(-1,0,if(shortHeight) 2f else 1f))
        root.addView(library,LinearLayout.LayoutParams(-1,0,1f))
        status = style.label("Connecting to your music…",13f,true).apply {
            setPadding(style.dp(16),style.dp(4),style.dp(16),style.dp(4)); accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        root.addView(status)

        val player = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; background = style.panel(style.raised); setPadding(style.dp(12),style.dp(4),style.dp(12),style.dp(8)) }
        title = style.label("Choose a track",16f).apply { typeface = style.medium; maxLines = 2; ellipsize = android.text.TextUtils.TruncateAt.END }
        artist = style.label("Your listening queue stays with you",12f,true).apply { maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END }
        val identity = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; isClickable = true; isFocusable = true; background = style.interaction(); setPadding(style.dp(8),style.dp(4),style.dp(8),style.dp(4)); minimumHeight = style.dp(48) }
        identity.addView(title); identity.addView(artist)
        identity.setOnClickListener { service?.selectedTrack()?.let { showTrack(it.optString("title"),it.optString("artist").takeUnless { a -> a == "null" || a.isBlank() } ?: "Unknown artist") } }
        player.addView(identity)
        seek = SeekBar(this).apply {
            max = 10000; contentDescription = "Playback position"; progressTintList = ColorStateList.valueOf(style.orange); thumbTintList = ColorStateList.valueOf(style.orange); minimumHeight = style.dp(48)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onStartTrackingTouch(bar: SeekBar) { dragging = true }
                override fun onStopTrackingTouch(bar: SeekBar) {
                    dragging = false
                    val duration = service?.snapshot?.optLong("duration_ms") ?: 0
                    service?.command(JSONObject().put("command","seek").put("position_ms",duration * bar.progress / 10000))
                }
                override fun onProgressChanged(bar: SeekBar, progress: Int, fromUser: Boolean) {}
            })
        }
        player.addView(seek,LinearLayout.LayoutParams(-1,style.dp(48)))
        time = style.label("0:00 / 0:00",11f,true).apply { typeface = style.mono; gravity = Gravity.END }
        player.addView(time)
        val controls = LinearLayout(this).apply { gravity = Gravity.CENTER }
        previous = icon(R.drawable.sq_previous,"Previous track") { service?.queueAction("previous") }
        play = icon(R.drawable.sq_play,"Play") { service?.let { it.command(JSONObject().put("command",if(it.snapshot.optString("transport") == "playing") "pause" else "resume")) } }
        play.backgroundTintList = ColorStateList.valueOf(style.orange); play.imageTintList = ColorStateList.valueOf(style.background)
        next = icon(R.drawable.sq_next,"Next track") { service?.queueAction("next") }
        controls.addView(previous); controls.addView(play); controls.addView(next)
        controls.addView(icon(R.drawable.sq_queue,"Open listening queue") { showQueue() })
        player.addView(controls)
        retry = button("Try playback again") { service?.command(JSONObject().put("command","retry")) }
        player.addView(retry)
        dock = BoundedScroll(this,if(shortHeight) 0.18f else 0.42f).apply { addView(player) }
        root.addView(dock,LinearLayout.LayoutParams(-1,-2))
        libraryNavigation = button("Library") { fixtureList?.smoothScrollToPosition(0) }
        queueNavigation = button("Queue") { showQueue() }
        style.mark(libraryNavigation,true)
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; background = style.panel(style.background)
            listOf(libraryNavigation,queueNavigation).forEach { addView(it,LinearLayout.LayoutParams(0,-2,1f)) }
        })
        setContentView(root)
        root.requestApplyInsets()
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS),1)
        bindService(Intent(this,PlaybackService::class.java),connection,BIND_AUTO_CREATE)
    }
    private fun input(hintText: String) = EditText(this).apply {
        hint = hintText; contentDescription = hintText; textSize = 16f; typeface = style.regular
        setTextColor(style.primary); setHintTextColor(style.secondary); setSingleLine()
        backgroundTintList = ColorStateList.valueOf(style.cyan); minimumHeight = style.dp(48)
    }
    private fun button(value: String, action: () -> Unit) = style.button(value,action)
    private fun actions(vararg controls: View) = LinearLayout(this).apply {
        orientation = if(resources.configuration.fontScale > 1.3f || resources.configuration.screenWidthDp < 360) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
        controls.forEach { addView(it, if(orientation == LinearLayout.HORIZONTAL) LinearLayout.LayoutParams(0,-2,1f) else LinearLayout.LayoutParams(-1,-2)) }
    }
    private fun icon(resource: Int, name: String, action: () -> Unit) = ImageButton(this).apply {
        setImageResource(resource); contentDescription = name; tooltipText = name
        imageTintList = ColorStateList.valueOf(style.primary); background = style.interaction()
        setPadding(style.dp(12),style.dp(12),style.dp(12),style.dp(12)); minimumWidth = style.dp(48); minimumHeight = style.dp(48)
        layoutParams = LinearLayout.LayoutParams(style.dp(48),style.dp(48)); setOnClickListener { action() }
    }
    private fun browse(offset: Int = 0, liked: Boolean = service?.libraryBrowse?.liked == true) {
        query.clearFocus()
        (getSystemService(INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager).hideSoftInputFromWindow(query.windowToken,0)
        service?.browseLibrary(offset,query.text.toString(),liked)
    }
    private fun showAccount() {
        accountDialog?.dismiss()
        val owner = service
        val accountEpoch = owner?.epoch
        val builder = AlertDialog.Builder(this).setTitle("SoundQ").setMessage("Music server\n${BuildConfig.API_BASE}\n\nNative preview\n${BuildConfig.SOURCE_REF}").setPositiveButton("Done",null)
        if(owner?.snapshot?.optBoolean("authenticated") == true) builder.setNeutralButton("Sign out") { _, _ -> if(service === owner && owner.epoch == accountEpoch) owner.logout() }
        accountDialog = builder.show()
    }
    private fun showTrack(name: String, performer: String) {
        trackDialog?.dismiss()
        trackDialog = AlertDialog.Builder(this).setTitle("Track details").setMessage("$name\n\n$performer").setPositiveButton("Done",null).show()
    }
    private fun animateIdentity(view: View, duration: Long) {
        view.animate().cancel()
        if(!android.animation.ValueAnimator.areAnimatorsEnabled()) { view.alpha = 1f; return }
        view.alpha = 0.65f
        view.animate().alpha(1f).setDuration(duration).setInterpolator(android.view.animation.DecelerateInterpolator()).start()
    }
    private fun render(snapshot: JSONObject, error: String?) {
        val selected = if(snapshot.isNull("selected_occurrence")) null else snapshot.optLong("selected_occurrence")
        if(queueListDialog != null && selected != queueListSelection) dismissQueueActions()
        queueActions?.notifyDataSetChanged()
        val authenticated = snapshot.optBoolean("authenticated")
        (login.parent as View).visibility = if(authenticated) View.GONE else View.VISIBLE
        library.visibility = if(authenticated) View.VISIBLE else View.GONE
        val browse = service?.libraryBrowse
        val enabled = service?.let { browse?.canUseRows(snapshot,it.epoch) } == true
        val values = snapshot.optJSONArray("library")
        val current = service?.selectedTrack()
        val currentID = current?.optLong("id")
        val rowOwner = LibraryBrowseState.RowOwner(snapshot.optLong("epoch"),snapshot.optLong("session"),snapshot.optLong("library_revision"))
        val contentChanged = !snapshot.optBoolean("library_unchanged") || rows.currentList.any { it.enabled != enabled || it.current != (it.id == currentID) || it.owner != rowOwner || it.serviceOwner !== service }
        val nextRows = if(!contentChanged) rows.currentList else (0 until (values?.length() ?: 0)).map { index ->
            val row = values!!.getJSONObject(index)
            Row(row.getLong("id"),row.getString("title"),row.optString("artist").takeUnless { it == "null" || it.isBlank() } ?: "Unknown artist",row.optLong("duration_ms"),LibraryBrowseState.favorite(snapshot,row.getLong("id")),currentID == row.getLong("id"),enabled,rowOwner,service)
        }
        // Service merges omitted content topics. Do not submit/rebind on a scalar tick.
        if(contentChanged) {
            if(nextRows != rows.currentList) rows.submitList(nextRows)
        }
        if(error != null) uiError = LibraryBrowseState.feedback(error)
        else if(browse?.loading == true || browse?.favoritePending == true || snapshot.optString("error").let { it.isBlank() || it == "null" }) uiError = null
        val feedback = browse?.failure ?: if(browse?.invalid == true) "Library changed. Refresh before choosing a track." else uiError
        val message = feedback ?: when {
            browse?.loading == true -> if(browse.pending?.identity?.liked == true) "Loading liked tracks… Showing your previous results." else "Loading Library… Showing your previous results."
            browse?.favoritePending == true -> "Saving liked state…"
            else -> "${nextRows.size} of ${snapshot.optLong("total")} tracks"
        }
        if(status.text.toString() != message) status.text = message
        status.setTextColor(if(feedback != null) style.error else style.secondary)
        empty.visibility = if(authenticated && nextRows.isEmpty()) View.VISIBLE else View.GONE
        empty.text = when {
            browse?.loading == true -> "Loading your library…"
            feedback != null -> "Library couldn't load. Use Refresh to try again."
            browse?.liked == true -> "No liked tracks match. Choose All tracks or change your search."
            browse?.query?.isNotBlank() == true -> "No tracks match. Change your search and try again."
            else -> "Your library is empty. Refresh after adding music to your server."
        }
        style.mark(all,browse?.liked != true); style.mark(liked,browse?.liked == true)
        val canRead = authenticated && browse?.loading != true && browse?.favoritePending != true
        listOf(all,liked,refresh,search,query).forEach { style.availability(it,canRead) }
        all.contentDescription = if(browse?.liked != true) "All tracks, selected" else "All tracks"
        liked.contentDescription = if(browse?.liked == true) "Liked tracks, selected" else "Liked tracks"
        style.availability(more,canRead && browse?.hasRead == true && browse.invalid == false && nextRows.size < snapshot.optLong("total"))
        libraryNavigation.visibility = if(authenticated) View.VISIBLE else View.GONE
        queueNavigation.visibility = if(authenticated) View.VISIBLE else View.GONE
        dock.visibility = if(authenticated && current != null) View.VISIBLE else View.GONE
        val identity = "$selected:${current?.optString("title")}:${current?.optString("artist")}"
        if(dockIdentity != identity) {
            dockIdentity = identity; title.text = current?.optString("title") ?: "Choose a track"
            artist.text = current?.optString("artist").takeUnless { it == "null" || it.isNullOrBlank() } ?: "Unknown artist"
            animateIdentity(title,180)
        }
        val transport = snapshot.optString("transport")
        if(playIdentity != transport) {
            playIdentity = transport; play.setImageResource(if(transport == "playing") R.drawable.sq_pause else R.drawable.sq_play)
            play.contentDescription = if(transport == "playing") "Pause" else if(transport == "ended") "Play again" else "Play"
            animateIdentity(play,140)
        }
        style.availability(play,current != null)
        val queue = snapshot.optJSONArray("queue")
        val index = (0 until (queue?.length() ?: 0)).firstOrNull { queue!!.getJSONObject(it).optLong("id") == selected }
        style.availability(previous,index != null && index > 0)
        style.availability(next,index != null && index + 1 < (queue?.length() ?: 0))
        val duration = snapshot.optLong("duration_ms")
        style.availability(seek,current != null && duration > 0 && transport != "failed")
        retry.visibility = if(transport == "failed") View.VISIBLE else View.GONE
        if(!dragging) seek.progress = if(duration > 0) (snapshot.optLong("position_ms") * 10000 / duration).toInt().coerceIn(0,10000) else 0
        time.text = "${clock(snapshot.optLong("position_ms"))} / ${clock(duration)}"
    }
    private fun dismissQueueActions() {
        val listDialog = queueListDialog
        val dialog = queueActionDialog
        val nameDialog = queueNameDialog
        queueListDialog = null
        queueListSelection = null
        queueActionDialog = null
        queueNameDialog = null
        queueActions = null
        listDialog?.dismiss()
        dialog?.dismiss()
        nameDialog?.dismiss()
    }
    private fun showQueue() {
        val s=service ?: return
        dismissQueueActions()
        val values=s.snapshot.optJSONArray("queue") ?: org.json.JSONArray()
        val ids=(0 until values.length()).map {values.getJSONObject(it).getLong("id")}
        val titles=(0 until values.length()).map { i -> val o=values.getJSONObject(i);(if(o.optLong("id")==s.snapshot.optLong("selected_occurrence")) "Current · " else "")+o.getJSONObject("track").getString("title")}
        val list = AlertDialog.Builder(this).setTitle("Listening queue · ${ids.size}").setItems(titles.toTypedArray()) {issued,index ->
            if (service !== s || queueListDialog !== issued || queueListDialog?.isShowing != true) return@setItems
            val id=ids[index]
            val name=values.getJSONObject(index).getJSONObject("track").getString("title")
            fun currentIndex(): Int {
                if (service !== s) return -1
                val queue = s.snapshot.optJSONArray("queue") ?: return -1
                return (0 until queue.length()).firstOrNull { queue.getJSONObject(it).getLong("id") == id } ?: -1
            }
            if (currentIndex() < 0) return@setItems
            dismissQueueActions()
            var active = true
            val actions = object : ArrayAdapter<String>(this, android.R.layout.select_dialog_item, arrayOf("Play", "Move up", "Move down", "Remove")) {
                override fun areAllItemsEnabled() = false
                override fun isEnabled(position: Int): Boolean {
                    val current = currentIndex()
                    if (!active || current < 0) return false
                    return when (position) {
                        1 -> current > 0
                        2 -> current + 1 < (s.snapshot.optJSONArray("queue")?.length() ?: 0)
                        else -> true
                    }
                }
                override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
                    val enabled = isEnabled(position)
                    return super.getView(position, convertView, parent).apply { isEnabled = enabled }
                }
            }
            val dialog = AlertDialog.Builder(this).setTitle(titles[index]).setAdapter(actions) {issued,action ->
                // A retained callback must not use the disclosure's opening index.
                // Dismiss listeners are posted; authority ends before their delivery.
                if (queueActionDialog === issued && queueActionDialog?.isShowing == true && actions.isEnabled(action)) {
                    val current = currentIndex()
                    when(action) {
                        0->s.queueAction("queue_play",id)
                        1->s.queueAction("queue_move",id,current-1)
                        2->s.queueAction("queue_move",id,current+1)
                        3->s.queueAction("queue_remove",id)
                    }
                }
            }.setNeutralButton("Full name") {issued,_ ->
                if (queueActionDialog === issued && queueActionDialog?.isShowing == true && currentIndex() >= 0) {
                    // Retire actions synchronously; closing read-only details never restores them.
                    dismissQueueActions()
                    // Native message content scrolls within the dialog, without a line cap.
                    val detail = AlertDialog.Builder(this).setTitle("Track name").setMessage(name).setPositiveButton("Done",null).show()
                    queueNameDialog = detail
                    detail.setOnDismissListener { if (queueNameDialog === detail) queueNameDialog = null }
                }
            }.show()
            queueActionDialog = dialog
            queueActions = actions
            dialog.setOnDismissListener {
                active = false
                if (queueActionDialog === dialog) { queueActionDialog = null; queueActions = null }
            }
        }.setPositiveButton("Done",null).setNeutralButton("Clear") {issued,_ ->
            if (service === s && queueListDialog === issued && queueListDialog?.isShowing == true) {
                dismissQueueActions()
                s.queueAction("queue_clear")
            }
        }.show()
        queueListDialog = list
        queueListSelection = if (s.snapshot.isNull("selected_occurrence")) null else s.snapshot.optLong("selected_occurrence")
        list.setOnDismissListener { if (queueListDialog === list) { queueListDialog = null; queueListSelection = null } }
    }
    override fun onDestroy() {
        dismissQueueActions(); accountDialog?.dismiss(); trackDialog?.dismiss()
        service?.listener = null; unbindService(connection); super.onDestroy()
    }
    internal data class Row(val id: Long, val title: String, val artist: String, val duration: Long, val liked: Boolean, val current: Boolean, val enabled: Boolean, val owner: LibraryBrowseState.RowOwner, val serviceOwner: PlaybackService?)
    internal class Rows(private val style: SoundQViews, private val select: (Row) -> Unit, private val favorite: (Row) -> Unit, private val details: (Row) -> Unit) : ListAdapter<Row, Rows.Holder>(object : DiffUtil.ItemCallback<Row>() {
        override fun areItemsTheSame(a: Row,b: Row) = a.id == b.id
        override fun areContentsTheSame(a: Row,b: Row) = a == b
    }) {
        init { setHasStableIds(true) }
        override fun getItemId(position: Int) = getItem(position).id
        class Holder(val row: LinearLayout, val name: TextView, val performer: TextView, val duration: TextView, val heart: ImageButton) : RecyclerView.ViewHolder(row)
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): Holder {
            val context = parent.context
            val row = LinearLayout(context).apply { layoutParams = RecyclerView.LayoutParams(-1,-2); gravity = Gravity.CENTER_VERTICAL; minimumHeight = style.dp(72); setPadding(style.dp(16),style.dp(8),style.dp(8),style.dp(8)); isFocusable = true; isClickable = true }
            row.addView(ImageView(context).apply { setImageResource(R.drawable.sq_note); imageTintList = ColorStateList.valueOf(style.secondary); background = style.panel(style.raised); setPadding(style.dp(12),style.dp(12),style.dp(12),style.dp(12)); importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO },LinearLayout.LayoutParams(style.dp(48),style.dp(48)))
            val name = style.label("",16f).apply { typeface = style.medium }
            val performer = style.label("",12f,true)
            val duration = style.label("",11f,true).apply { typeface = style.mono }
            val metadata = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; setPadding(style.dp(12),0,style.dp(8),0); addView(name); addView(performer); addView(duration) }
            // Natural wrapping at accessibility sizes; Full details is a read-only long press.
            row.addView(metadata,LinearLayout.LayoutParams(0,-2,1f))
            val heart = ImageButton(context).apply { background = style.interaction(); setPadding(style.dp(12),style.dp(12),style.dp(12),style.dp(12)); minimumWidth = style.dp(48); minimumHeight = style.dp(48) }
            row.addView(heart,LinearLayout.LayoutParams(style.dp(48),style.dp(48)))
            return Holder(row,name,performer,duration,heart)
        }
        override fun onBindViewHolder(holder: Holder, position: Int) {
            val row = getItem(position)
            holder.name.text = row.title; holder.performer.text = row.artist; holder.duration.text = if(row.duration > 0) clock(row.duration) else ""
            holder.name.setTextColor(if(row.current) style.orange else style.primary)
            holder.row.background = style.interaction(row.current)
            holder.row.contentDescription = "${row.title}, ${row.artist}${if(row.current) ", current track" else ""}"
            holder.row.setOnClickListener { if(row.enabled) select(row) }
            holder.row.setOnLongClickListener { details(row); true }
            holder.heart.setImageResource(if(row.liked) R.drawable.sq_heart_filled else R.drawable.sq_heart)
            holder.heart.imageTintList = ColorStateList.valueOf(if(row.liked) style.orange else style.secondary)
            holder.heart.contentDescription = "${if(row.liked) "Unlike" else "Like"} ${row.title}"
            holder.heart.isSelected = row.liked
            style.availability(holder.heart,row.enabled)
            holder.heart.setOnClickListener { if(row.enabled) favorite(row) }
        }
    }
    /** Standard ScrollView bounds chrome at short heights; the RecyclerView keeps its own scroll. */
    class BoundedScroll(context: Context, private val fraction: Float) : ScrollView(context) {
        override fun onMeasure(widthSpec: Int,heightSpec: Int) {
            val rootHeight = rootView.height.takeIf { it > 0 } ?: resources.displayMetrics.heightPixels
            val short = resources.configuration.screenHeightDp < 480
            val portion = if(short && fraction < 0.5f) minOf(fraction,0.28f) else fraction
            val limit = (rootHeight * portion).toInt()
            val available = if(MeasureSpec.getMode(heightSpec) == MeasureSpec.UNSPECIFIED) limit else minOf(MeasureSpec.getSize(heightSpec),limit)
            super.onMeasure(widthSpec,MeasureSpec.makeMeasureSpec(available,MeasureSpec.AT_MOST))
        }
    }
    companion object {
        fun clock(milliseconds: Long): String { val seconds = milliseconds.coerceAtLeast(0) / 1000; return "${seconds / 60}:${(seconds % 60).toString().padStart(2,'0')}" }
    }
}
