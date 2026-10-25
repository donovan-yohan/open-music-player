import AppKit
import AVFoundation
import MediaPlayer
import Security
import CoreText
import SoundQCore

struct Track: Decodable {
    let id: Int64
    let title: String
    let artist: String?
    let duration_ms: UInt64?
}
struct Occurrence: Decodable { let id: UInt64; let track: Track }
struct Snapshot: Decodable {
    let epoch: UInt64
    let session: UInt64
    let revision: UInt64
    let authenticated: Bool
    var library: [Track]
    let library_unchanged: Bool
    let total: UInt64
    var queue: [Occurrence]
    let queue_unchanged: Bool
    let selected_occurrence: UInt64?
    let transport: String
    let position_ms: UInt64
    let duration_ms: UInt64
    let error: String?
    // Core load_occurrence sets selected_occurrence before preparing and marks
    // transport failed on preparation refusal; AudioReport.failed does likewise.
    // Ordinary Library/auth/save errors alone are not playback failures.
    var canRetryPlayback: Bool {authenticated && transport == "failed" && selected_occurrence != nil}
}
struct AudioEffect: Decodable {
    let action: String
    let epoch: UInt64
    let session: UInt64
    let path: String?
    let position_ms: UInt64
    let cached: Bool
}
struct Credentials: Codable { let access_token: String; let refresh_token: String; let account_id: String; let version: UInt64? }
struct Reply: Decodable { let ok: Bool; let code: String; let snapshot: Snapshot?; let audio: AudioEffect?; let credentials: Credentials? }

// Only this serial non-UI executor crosses the blocking core boundary. Immutable
// Data is transferred back to the main actor, never untyped Sendable dictionaries.
final class Bridge: @unchecked Sendable {
    let handle: UInt64
    private let worker = DispatchQueue(label: "soundq.native.core", qos: .userInitiated)
    init(endpoint: String, root: URL) {
        precondition(sq_core_abi_version() == 1)
        handle = endpoint.withCString { endpoint in root.path.withCString { sq_core_open(endpoint, $0) } }
    }
    func revoke() -> UInt64 { sq_core_revoke(handle) }
    func send(_ data: Data, epoch: UInt64, completion: @escaping @Sendable (Data) -> Void) {
        worker.async { [self] in
            guard let text = String(data: data, encoding: .utf8), let pointer = text.withCString({ sq_core_execute(handle, epoch, $0) }) else {
                completion(Data(#"{"ok":false,"code":"binding_failure"}"#.utf8)); return
            }
            let result = Data(bytes: pointer, count: strlen(pointer))
            sq_core_string_free(pointer)
            completion(result)
        }
    }
    deinit { sq_core_close(handle) }
}

@MainActor
final class App: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    var window: NSWindow!
    var bridge: Bridge!
    var snapshot: Snapshot?
    var epoch: UInt64 = 1
    var player: AVPlayer?
    var observation: NSKeyValueObservation?
    var timer: Timer?
    var reportPending = false
    var table = NSTableView()
    var titleLabel = NSTextField(labelWithString: "SoundQ")
    var status = NSTextField(labelWithString: "")
    var transportLabel = NSTextField(labelWithString: "No selection")
    var email = NSTextField()
    var password = NSSecureTextField()
    var endpoint = NSTextField()
    var search = SoundQSearchField()
    var libraryDock: LibraryDockView?
    var dockTrackID: Int64?
    var nativeAssets: NativeAssets?
    var slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    var loginArea = NSStackView()
    var libraryArea = NSStackView()
    var play = SoundQButton(title: "Play", target: nil, action: nil)
    var logout = SoundQButton(title: "Sign out", target: nil, action: nil)
    var scroll = NSScrollView()
    var keychainService = "com.soundq.native.preview.credentials.v1"
    var busy = 0
    var journeyStarted = false
    var phaseConfiguration: FixturePhaseConfiguration?
    var fixtureJourneyTask: Task<Void,Never>?
    var phaseFinalized = false
    var lastEffectCached = false
    var wantsPlayback = false
    var accountScope: UInt64 = 1
    var storedCredentialVersion: UInt64 = 0
    var queueNameAlert: (alert: NSAlert, id: UInt64)?
    var libraryDetails = SoundQButton(title:"Full details",target:nil,action:nil)
    var libraryDetailsMenuItem: NSMenuItem?
    var libraryDetailsAction: LibraryMetadataAction?
    var libraryDetailsAlert: (alert: NSAlert, action: LibraryMetadataAction)?

    func fixtureCacheRoot() -> URL? {
        guard endpoint.stringValue == "http://127.0.0.1:54761/api/v1",
              let path = ProcessInfo.processInfo.environment["SOUNDQ_NATIVE_CACHE_ROOT"],
              path.hasPrefix("/") else {return nil}
        return URL(fileURLWithPath:path)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        endpoint.stringValue = environment["OMP_API_BASE_URL"] ?? "http://127.0.0.1:8080/api/v1"
        let root = fixtureCacheRoot() ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.soundq.native.preview")
        bridge = Bridge(endpoint: endpoint.stringValue, root: root)
        buildWindow()
        configureMediaControls()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.report() }
        }
        if CommandLine.arguments.contains("--abi-smoke") {
            command(["command":"snapshot"]) {
                print("SWIFT_ABI_SMOKE_PASS version=1 native=AppKit")
                NSApp.terminate(nil)
            }
            return
        }
        if let configuration = phaseConfiguration {
            command(["command":"login","email":configuration.email,"password":configuration.password]) { [weak self] in
                self?.loadLibrary();self?.startFixtureJourney()
            }
            return
        }
        if let fixture = environment["SOUNDQ_NATIVE_FIXTURE_HOME"], endpoint.stringValue == "http://127.0.0.1:54761/api/v1" {
            let path = URL(fileURLWithPath: fixture).appendingPathComponent("credentials.json")
            if let data = try? Data(contentsOf:path), let object = try? JSONSerialization.jsonObject(with:data) as? [String:String], let e = object["email"], let p = object["password"] {
                command(["command":"login","email":e,"password":p]) { [weak self] in
                    self?.loadLibrary()
                    if CommandLine.arguments.contains("--fixture-journey"), let self {self.startFixtureJourney()}
                }
                return
            }
        }
        if let saved = loadCredentials() {
            command(["command":"restore", "access_token":saved.access_token, "refresh_token":saved.refresh_token, "account_id":saved.account_id]) { [weak self] in self?.command(["command":"queue_restore"]) {self?.loadLibrary()} }
        } else { command(["command":"snapshot"]) }
    }
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 100,y: 100,width: 1100,height: 760),styleMask: [.titled,.closable,.miniaturizable,.resizable],backing: .buffered,defer: false)
        window.title = "SoundQ Native Preview"
        window.delegate = self
        window.minSize = NSSize(width: 760,height: 540)
        do {nativeAssets = try NativeAssets.load()} catch {
            let alert = NSAlert();alert.messageText = "SoundQ resources could not be loaded";alert.informativeText = String(describing:error);alert.runModal();NSApp.terminate(nil);return
        }
        mountLibraryDock(in:window.contentView!,assets:nativeAssets!)
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        let menu = NSMenu();let item = NSMenuItem();menu.addItem(item);let appMenu = NSMenu();appMenu.addItem(withTitle:"Quit SoundQ Native Preview",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");item.submenu = appMenu;NSApp.mainMenu = menu
        titleLabel.stringValue = "Library"
        let editItem = NSMenuItem();menu.addItem(editItem);let edit = NSMenu(title:"Edit");editItem.submenu = edit
        let libraryItem = NSMenuItem();libraryItem.title = "Library";libraryItem.submenu = makeLibraryMenu();menu.addItem(libraryItem)
        for (title,action,key) in [("Copy",#selector(NSText.copy(_:)),"c"),("Paste",#selector(NSText.paste(_:)),"v"),("Select All",#selector(NSText.selectAll(_:)),"a")] {edit.addItem(withTitle:title,action:action,keyEquivalent:key)}
    }
    func makeLibraryMenu() -> NSMenu {
        let menu = NSMenu(title:"Library");menu.autoenablesItems = true
        let details = NSMenuItem(title:"Full details",action:#selector(openLibraryDetailsFromMenu(_:)),keyEquivalent:"i")
        details.keyEquivalentModifierMask = [.command];details.target = self
        menu.addItem(details);libraryDetailsMenuItem = details
        return menu
    }
    func libraryDetailsMenuAvailable(_ item: NSMenuItem) -> Bool {
        guard item === libraryDetailsMenuItem, let action = libraryDetailsAction,
              !action.consumed, let s = snapshot else {return false}
        return action.matches(s,account:accountScope,epoch:epoch)
    }
    @objc func openLibraryDetailsFromMenu(_ sender: NSMenuItem) {
        guard libraryDetailsMenuAvailable(sender), let action = libraryDetailsAction else {return}
        action.open()
    }
    func mountLibraryDock(in host: NSView, assets: NativeAssets) {
        logout.target = self;logout.action = #selector(signOut);logout.setAccessibilityLabel("Sign out")
        email.placeholderString = "Email";password.placeholderString = "Password";endpoint.placeholderString = "API base URL";endpoint.isEditable = false
        loginArea.orientation = .vertical;loginArea.alignment = .leading;loginArea.spacing = 8
        for field in [endpoint,email,password] {field.widthAnchor.constraint(equalToConstant:420).isActive = true;loginArea.addArrangedSubview(field)}
        let signIn = SoundQButton(title:"Sign in",target:self,action:#selector(signIn));signIn.keyEquivalent = "\r";loginArea.addArrangedSubview(signIn)
        search.placeholderString = "Search your library";search.delegate = self
        let refresh = SoundQButton(title:"Refresh",target:self,action:#selector(refresh))
        let more = SoundQButton(title:"Load more",target:self,action:#selector(loadMore))
        let select = SoundQButton(title:"Play selected",target:self,action:#selector(selectTrack));select.setAccessibilityIdentifier("play-selected")
        let retry = SoundQButton(title:"Retry playback",target:self,action:#selector(retry));retry.isEnabled = false
        let previous = SoundQButton(title:"Previous",target:self,action:#selector(previousTrack));previous.symbol = "backward.end.fill";previous.glyphSize = 24
        let next = SoundQButton(title:"Next",target:self,action:#selector(nextTrack));next.symbol = "forward.end.fill";next.glyphSize = 24
        let queue = SoundQButton(title:"Queue",target:self,action:#selector(showQueue))
        for button in [refresh,more,select,retry,previous,next,queue,play] {button.setAccessibilityLabel(button.title);button.wantsLayer = true}
        play.target = self;play.action = #selector(toggle);play.setAccessibilityIdentifier("toggle-playback");play.primary = true;play.symbol = "play.fill";play.glyphSize = 24
        slider.target = self;slider.action = #selector(seek);slider.isContinuous = false;slider.setAccessibilityLabel("Playback position")
        table.addTableColumn(NSTableColumn(identifier:NSUserInterfaceItemIdentifier("track")))
        table.tableColumns[0].width = 600;table.headerView = nil;table.rowHeight = 56;table.intercellSpacing = .zero
        table.style = .plain;table.usesAlternatingRowBackgroundColors = false;table.delegate = self;table.dataSource = self;table.target = self;table.doubleAction = #selector(selectTrack)
        table.setAccessibilityLabel("Library tracks");table.autosaveName = "SoundQNativeLibrary";table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        scroll.documentView = table;scroll.hasVerticalScroller = true;scroll.autohidesScrollers = true;scroll.setAccessibilityLabel("Library scroll area")
        libraryArea.addSubview(scroll)
        libraryDetails.setAccessibilityLabel("Full details for selected Library track")
        libraryDetails.setAccessibilityIdentifier("library-full-details")
        libraryDetails.isEnabled = false
        table.nextKeyView = libraryDetails;libraryDetails.nextKeyView = select
        let controls = LibraryDockControls(table:table,scroll:scroll,search:search,slider:slider,play:play,title:titleLabel,identity:transportLabel,status:status,login:loginArea,library:libraryArea,logout:logout,refresh:refresh,more:more,select:select,details:libraryDetails,retry:retry,previous:previous,next:next,queue:queue)
        let shell = LibraryDockView(controls:controls,assets:assets);shell.frame = host.bounds;shell.autoresizingMask = [.width,.height];host.addSubview(shell);libraryDock = shell
        // App-local accessibility sizing, no global preference writes. Retain a
        // single scale input so runtime QA can qualify the actual mounted fonts.
        shell.textScale = max(1,NSFont.preferredFont(forTextStyle:.body).pointSize/13)
        for field in [endpoint,email,password] {field.font = NativeAssets.font(14,scale:shell.textScale)}
        signIn.font = NativeAssets.font(14,weight:500,scale:shell.textScale)
    }
    func command(_ value: [String:Any], completion: (@MainActor () -> Void)? = nil) {
        let kind = value["command"] as? String ?? ""
        if ["login","register","restore","logout","select","queue_play","next","previous","queue_clear","queue_restore"].contains(kind) {closeQueueName();retireLibraryDetails()}
        if ["login","register","restore","logout"].contains(kind) {
            accountScope += 1;storedCredentialVersion = 0
            if kind != "restore", ProcessInfo.processInfo.environment["SOUNDQ_NATIVE_FIXTURE_HOME"] == nil {deleteCredentials()}
        }
        guard busy < 32 else {status.stringValue = "Playback is busy. Try again.";return}
        if ["select","queue_play","next","previous","resume","retry"].contains(kind) || kind == "queue_remove" && (value["occurrence_id"] as? UInt64) == snapshot?.selected_occurrence {wantsPlayback = true}
        if ["pause","queue_clear","queue_restore","logout","login"].contains(kind) {wantsPlayback = false;player?.pause()}
        var scopedValue = value;scopedValue["account_scope_v1"] = accountScope
        guard let data = try? JSONSerialization.data(withJSONObject:scopedValue) else {return}
        let admittedEpoch = epoch
        let admittedAccount = accountScope
        busy += 1
        bridge.send(data, epoch: admittedEpoch) { [weak self] data in
            Task { @MainActor in
                guard let self else{return};self.busy -= 1
                guard admittedEpoch == self.epoch, admittedAccount == self.accountScope else{self.reportPending = false;return}
                guard let reply = try? JSONDecoder().decode(Reply.self,from:data) else {self.status.stringValue = "Invalid native response";self.reportPending = false;return}
                if let snapshot = reply.snapshot, snapshot.epoch == self.epoch {self.apply(snapshot)}
                if !reply.ok {self.status.stringValue = reply.code.replacingOccurrences(of:"_",with:" ")}
                if let effect = reply.audio, effect.epoch == self.epoch {self.applyAudio(effect)}
                if let credentials = reply.credentials, ProcessInfo.processInfo.environment["SOUNDQ_NATIVE_FIXTURE_HOME"] == nil {self.storeCredentials(credentials,epoch:admittedEpoch)}
                completion?()
            }
        }
    }
    func apply(_ incoming: Snapshot) {
        var value = incoming
        if value.library_unchanged {value.library = snapshot?.library ?? []}
        if value.queue_unchanged {value.queue = snapshot?.queue ?? []}
        // Content topics alone pay this comparison; String equality is canonical,
        // not byte equality, so compare UTF8 for exact metadata publications.
        let rowsChanged = !value.library_unchanged && (snapshot?.library.count != value.library.count || !zip(snapshot?.library ?? [],value.library).allSatisfy {
            $0.id == $1.id && $0.title.utf8.elementsEqual($1.title.utf8) &&
            ($0.artist == nil) == ($1.artist == nil) && ($0.artist ?? "").utf8.elementsEqual(($1.artist ?? "").utf8) && $0.duration_ms == $1.duration_ms
        })
        let prior = snapshot
        let browseID = rowsChanged && table.selectedRow >= 0 && table.selectedRow < (prior?.library.count ?? 0) ? prior?.library[table.selectedRow].id : nil
        let chromeChanged = !value.queue_unchanged || prior?.authenticated != value.authenticated || prior?.epoch != value.epoch || prior?.session != value.session || prior?.selected_occurrence != value.selected_occurrence || prior?.transport != value.transport
        if chromeChanged {reconcileQueueName(value)}
        if rowsChanged || prior?.authenticated != value.authenticated || prior?.epoch != value.epoch || prior?.session != value.session {reconcileLibraryDetails(value)}
        snapshot = value
        if prior?.authenticated != value.authenticated {loginArea.isHidden = value.authenticated;libraryArea.isHidden = !value.authenticated;logout.isHidden = !value.authenticated}
        if rowsChanged {
            table.reloadData()
            if let browseID, let row = value.library.firstIndex(where:{$0.id == browseID}) {table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)}
            else {table.selectRowIndexes([],byExtendingSelection:false)}
            libraryDock?.updateContent(empty:value.library.isEmpty)
        }
        if rowsChanged || prior?.total != value.total || prior?.authenticated != value.authenticated || prior?.epoch != value.epoch || prior?.session != value.session {updateLibraryAvailability()}
        if prior?.authenticated != value.authenticated {titleLabel.stringValue = "Library";libraryDock?.updateAuthentication(value.authenticated)}
        if chromeChanged {
            let chrome = DockChrome(value)
            let oldTrackID = dockTrackID;dockTrackID = chrome.trackID
            if libraryDock == nil {transportLabel.stringValue = chrome.title}
            play.title = value.transport == "playing" ? "Pause" : "Play"
            play.setAccessibilityLabel(play.title)
            play.isEnabled = !value.queue.isEmpty
            libraryDock?.setPlaybackRetryAvailable(value.canRetryPlayback && value.epoch == epoch)
            libraryDock?.updateChrome(chrome)
            libraryDock?.updateCurrent(old:oldTrackID,new:chrome.trackID)
        }
        slider.maxValue = Double(max(value.duration_ms,1));slider.doubleValue = Double(value.position_ms)
        if chromeChanged {slider.isEnabled = !value.queue.isEmpty}
        libraryDock?.updateProgress(position:value.position_ms,duration:value.duration_ms)
        // Local command failures can change the displayed feedback independently
        // of snapshot topics. A successful scalar recovery must publish truth too.
        let feedback = value.error?.replacingOccurrences(of:"_",with:" ") ?? "\(value.library.count) of \(value.total) tracks"
        if status.stringValue != feedback {status.stringValue = feedback}
    }
    func applyAudio(_ effect: AudioEffect) {
        guard effect.epoch == epoch else{return}
        if effect.action == "load" {lastEffectCached = effect.cached}
        switch effect.action {
        case "load":
            player?.pause();observation = nil;player?.replaceCurrentItem(with:nil)
            guard let path = effect.path else{return}
            let item = AVPlayerItem(url:URL(fileURLWithPath:path));player = AVPlayer(playerItem:item)
            observation = item.observe(\.status,options:[.new]) { [weak self] item,_ in
                let failed = item.status == .failed
                Task { @MainActor in
                    guard let self, self.snapshot?.session == effect.session, self.epoch == effect.epoch else{return}
                    if failed {self.report(state:"failed")} else if item.status == .readyToPlay && self.wantsPlayback {self.player?.play()}
                }
            }
            if effect.position_ms>0 {player?.seek(to:CMTime(value:Int64(effect.position_ms),timescale:1000),toleranceBefore:.zero,toleranceAfter:.zero)}
            if wantsPlayback {player?.play()}
            let track=snapshot?.queue.first(where:{$0.id==snapshot?.selected_occurrence})?.track
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle:track?.title ?? "SoundQ",MPMediaItemPropertyArtist:track?.artist ?? ""]
        case "pause": player?.pause()
        case "play": if wantsPlayback {player?.play()}
        case "seek": player?.seek(to:CMTime(value:Int64(effect.position_ms),timescale:1000),toleranceBefore:.zero,toleranceAfter:.zero)
        case "stop": player?.pause();observation = nil;player?.replaceCurrentItem(with:nil);player = nil;MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        default: break
        }
    }
    func report(state: String? = nil) {
        guard !reportPending,busy == 0,let player,let snapshot,!snapshot.queue.isEmpty else{return}
        let time = player.currentTime().seconds;let duration = player.currentItem?.duration.seconds ?? 0
        let failed = player.error != nil || player.currentItem?.status == .failed
        guard time.isFinite || failed || state == "failed" else{return}
        let nativeState = state ?? (failed ? "failed" : player.rate > 0 ? "playing" : (duration.isFinite && time >= duration-0.05 ? "ended" : "paused"))
        // Only a playing/preparing canonical owner can consume EOF. After its
        // accepted final observation (even with a save fault), the timer must
        // not submit it again. Failure and seek/resume observations still flow.
        if nativeState == "ended", !["playing","preparing"].contains(snapshot.transport) {return}
        let positionMs = max(time,0)*1000;let durationMs = max(duration,0)*1000
        let position = positionMs.isFinite && positionMs < Double(UInt64.max) ? UInt64(positionMs) : snapshot.position_ms
        let length = durationMs.isFinite && durationMs < Double(UInt64.max) ? UInt64(durationMs) : snapshot.duration_ms
        reportPending = true
        command(["command":"audio_report","epoch":epoch,"session":snapshot.session,"state":nativeState,"position_ms":position,"duration_ms":length]) { [weak self] in self?.reportPending = false }
        MPNowPlayingInfoCenter.default().playbackState = player.rate > 0 ? .playing : .paused
    }
    func loadLibrary(offset: Int = 0) {command(["command":"library","offset":offset,"query":search.stringValue,"sort":"added_at","order":"desc"])}
    @objc func signIn() {
        retireLibraryDetails()
        closeQueueName()
        player?.pause();player?.replaceCurrentItem(with:nil);player = nil;epoch = bridge.revoke()

        command(["command":"login","email":email.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),"password":password.stringValue]) { [weak self] in
            guard let self,self.snapshot?.authenticated == true else{return}
            self.password.stringValue = "";self.loadLibrary()
        }
    }
    @objc func signOut() {retireLibraryDetails();closeQueueName();player?.pause();observation = nil;player?.replaceCurrentItem(with:nil);player = nil;epoch = bridge.revoke();deleteCredentials();command(["command":"logout"])}
    @objc func refresh() {loadLibrary()}
    @objc func loadMore() {loadLibrary(offset:snapshot?.library.count ?? 0)}
    @objc func selectTrack() {let row = table.selectedRow;guard let s = snapshot,row >= 0,row < s.library.count else{return};retireLibraryDetails();closeQueueName();player?.pause();player?.replaceCurrentItem(with:nil);player = nil;epoch = bridge.revoke();command(["command":"select","track_id":s.library[row].id])}
    @objc func toggle() {command(["command":snapshot?.transport == "playing" ? "pause" : "resume"])}
    func queueCommand(_ kind:String,id:UInt64?=nil,index:Int?=nil) {
        guard let s=snapshot else{return}
        let selected=s.queue.firstIndex(where:{$0.id==s.selected_occurrence})
        if kind=="next" && (selected==nil || selected!+1>=s.queue.count) {return}
        if kind=="previous" && (selected==nil || selected == 0) {return}
        if ["queue_play","next","previous","queue_clear"].contains(kind) || kind=="queue_remove" && id==s.selected_occurrence {
            retireLibraryDetails()
            closeQueueName()
            player?.pause();observation=nil;player?.replaceCurrentItem(with:nil);player=nil;epoch=bridge.revoke()
        }
        var value:[String:Any]=["command":kind]
        if let id {value[kind=="queue_append" ? "track_id":"occurrence_id"]=id}
        if let index {value["to_index"]=index}
        command(value)
    }
    @objc func nextTrack() {queueCommand("next")}
    @objc func previousTrack() {queueCommand("previous")}
    @objc func showQueue() {
        closeLibraryDetails()
        closeQueueName()
        let menu=NSMenu(title:"Listening queue")
        for o in snapshot?.queue ?? [] {
            let item=NSMenuItem(title:(o.id==snapshot?.selected_occurrence ? "Current · ":"")+o.track.title,action:#selector(playOccurrence(_:)),keyEquivalent:"")
            item.target=self;item.representedObject=NSNumber(value:o.id)
            let actions=NSMenu()
            for (title,selector) in [("Play",#selector(playOccurrence(_:))),("Move up",#selector(moveOccurrenceUp(_:))),("Move down",#selector(moveOccurrenceDown(_:))),("Remove",#selector(removeOccurrence(_:))),("Full name",#selector(showOccurrenceName(_:)))] {
                let action=NSMenuItem(title:title,action:selector,keyEquivalent:"");action.target=self;action.representedObject=NSNumber(value:o.id);actions.addItem(action)
            }
            item.submenu=actions;menu.addItem(item)
        }
        menu.addItem(.separator());let clear=NSMenuItem(title:"Clear queue",action:#selector(clearQueue),keyEquivalent:"");clear.target=self;menu.addItem(clear)
        menu.popUp(positioning:nil,at:NSPoint(x:20,y:100),in:window.contentView)
    }
    // AppKit autoenables menu items by asking their target on every validation.
    // Resolve occurrence identity against the latest snapshot, never opening order.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(openLibraryDetailsFromMenu(_:)) {
            return libraryDetailsMenuAvailable(menuItem)
        }
        if menuItem.action == #selector(clearQueue) {return snapshot?.queue.isEmpty == false}
        if menuItem.action == #selector(showOccurrenceName(_:)) {return queueNameOccurrence(menuItem) != nil}
        let action = menuItem.action
        guard [#selector(playOccurrence(_:)),#selector(removeOccurrence(_:)),#selector(moveOccurrenceUp(_:)),#selector(moveOccurrenceDown(_:))].contains(where:{$0 == action}) else {return true}
        guard let id = menuItem.representedObject as? NSNumber, let s = snapshot,
              let index = s.queue.firstIndex(where:{$0.id == id.uint64Value}) else {return false}
        if action == #selector(moveOccurrenceUp(_:)) {return index > 0}
        if action == #selector(moveOccurrenceDown(_:)) {return index + 1 < s.queue.count}
        return true
    }
    @objc func playOccurrence(_ sender:NSMenuItem) {if let id=sender.representedObject as? NSNumber,snapshot?.queue.contains(where:{$0.id==id.uint64Value}) == true {queueCommand("queue_play",id:id.uint64Value)}}
    @objc func removeOccurrence(_ sender:NSMenuItem) {if let id=sender.representedObject as? NSNumber,snapshot?.queue.contains(where:{$0.id==id.uint64Value}) == true {queueCommand("queue_remove",id:id.uint64Value)}}
    @objc func moveOccurrenceUp(_ sender:NSMenuItem) {moveOccurrence(sender,delta:-1)}
    @objc func moveOccurrenceDown(_ sender:NSMenuItem) {moveOccurrence(sender,delta:1)}
    func moveOccurrence(_ sender:NSMenuItem,delta:Int) {guard let id=sender.representedObject as? NSNumber,let s=snapshot,let index=s.queue.firstIndex(where:{$0.id==id.uint64Value}),s.queue.indices.contains(index+delta) else{return};queueCommand("queue_move",id:id.uint64Value,index:index+delta)}
    @objc func clearQueue() {guard snapshot?.queue.isEmpty == false else{return};queueCommand("queue_clear")}
    func queueNameOccurrence(_ sender: NSMenuItem) -> Occurrence? {
        guard let id = sender.representedObject as? NSNumber,
              CFGetTypeID(id) != CFBooleanGetTypeID(), id.uint64Value > 0,
              id.stringValue == String(id.uint64Value), let s = snapshot,
              s.authenticated, s.epoch == epoch else {return nil}
        return s.queue.first(where:{$0.id == id.uint64Value})
    }
    @objc func showOccurrenceName(_ sender: NSMenuItem) {
        guard let occurrence = queueNameOccurrence(sender) else {return}
        closeLibraryDetails()
        closeQueueName()
        let alert = NSAlert();alert.messageText = "Full name"
        let done = alert.addButton(withTitle:"Done");done.keyEquivalent = "\u{1b}"
        let area = NSTextView.scrollableTextView()
        let screen = window.screen?.visibleFrame ?? window.frame
        let available = NSSize(width:min(window.contentLayoutRect.width,screen.width),height:min(window.contentLayoutRect.height,screen.height))
        area.frame = NSRect(x:0,y:0,width:min(560,available.width * 0.6),height:min(320,available.height * 0.45))
        area.hasVerticalScroller = true;area.hasHorizontalScroller = false;area.autohidesScrollers = true
        guard let text = area.documentView as? NSTextView else {return}
        text.isEditable = false;text.isSelectable = true;text.isRichText = false
        text.font = sender.menu?.font ?? NSFont.menuFont(ofSize:0)
        text.isHorizontallyResizable = false;text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.minSize = NSSize(width:0,height:area.contentSize.height)
        text.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        text.textContainer?.size = NSSize(width:area.contentSize.width,height:CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true;text.textContainer?.lineBreakMode = .byCharWrapping
        text.string = occurrence.track.title
        text.setAccessibilityLabel("Full track name");area.setAccessibilityLabel("Full name scroll area")
        alert.accessoryView = area;alert.window.initialFirstResponder = text
        queueNameAlert = (alert,occurrence.id)
        alert.beginSheetModal(for:window) { [weak self, weak alert] _ in
            if self?.queueNameAlert?.alert === alert {self?.queueNameAlert = nil}
        }
    }
    func closeQueueName() {
        guard let detail = queueNameAlert else {return}
        queueNameAlert = nil
        window.endSheet(detail.alert.window)
    }
    func reconcileQueueName(_ incoming: Snapshot) {
        guard let detail = queueNameAlert else {return}
        if !incoming.authenticated || incoming.epoch != snapshot?.epoch || incoming.session != snapshot?.session ||
            incoming.selected_occurrence != snapshot?.selected_occurrence ||
            incoming.queue.first(where:{$0.id == detail.id}).map({Array($0.track.title.utf8)}) != snapshot?.queue.first(where:{$0.id == detail.id}).map({Array($0.track.title.utf8)}) {
            closeQueueName()
        }
    }
    func updateLibraryDetailsAction() {
        let row = table.selectedRow
        guard let s = snapshot, s.authenticated, s.epoch == epoch,
              row >= 0, row < s.library.count else {retireLibraryDetails();return}
        let track = s.library[row]
        if let action = libraryDetailsAction, !action.consumed, action.track.id == track.id,
           action.matches(s,account:accountScope,epoch:epoch) {return}
        if libraryDetailsAlert?.action !== libraryDetailsAction {libraryDetailsAction?.active = false}
        let action = LibraryMetadataAction(owner:self,account:accountScope,snapshot:s,track:track)
        libraryDetailsAction = action;libraryDetails.target = action;libraryDetails.action = #selector(LibraryMetadataAction.open)
        libraryDetails.isEnabled = true
    }
    func openLibraryDetails(_ action: LibraryMetadataAction) {
        guard libraryDetailsAction === action, !action.consumed, let s = snapshot,
              action.matches(s,account:accountScope,epoch:epoch) else {return}
        action.consumed = true
        closeLibraryDetails();closeQueueName()
        let alert = NSAlert();alert.messageText = "Full details"
        let done = alert.addButton(withTitle:"Done");done.keyEquivalent = "\u{1b}"
        let screen = window.screen?.visibleFrame ?? window.frame
        let available = NSSize(width:min(window.contentLayoutRect.width,screen.width),height:min(window.contentLayoutRect.height,screen.height))
        let area = LibraryMetadataDisclosure.area(track:action.track,available:available,font:libraryDetails.font ?? NSFont.systemFont(ofSize:14))
        alert.accessoryView = area;alert.window.initialFirstResponder = area.documentView
        libraryDetailsAlert = (alert,action)
        alert.beginSheetModal(for:window) { [weak self, weak alert] _ in
            guard let self, self.libraryDetailsAlert?.alert === alert else {return}
            self.libraryDetailsAlert?.action.active = false
            self.libraryDetailsAlert = nil;self.updateLibraryDetailsAction()
        }
        // The toolbar's next native dispatch is a fresh capability; a retained
        // old target cannot dismiss or replace this or a later disclosure.
        updateLibraryDetailsAction()
    }
    func closeLibraryDetails() {
        guard let detail = libraryDetailsAlert else {return}
        detail.action.active = false;libraryDetailsAlert = nil
        window.endSheet(detail.alert.window)
    }
    func retireLibraryDetails() {
        libraryDetailsAction?.active = false;libraryDetailsAction = nil
        libraryDetails.target = nil;libraryDetails.action = nil;libraryDetails.isEnabled = false
        closeLibraryDetails()
    }
    func reconcileLibraryDetails(_ incoming: Snapshot) {
        if let action = libraryDetailsAction, !action.matches(incoming,account:accountScope,epoch:epoch) {
            action.active = false;libraryDetailsAction = nil
            libraryDetails.target = nil;libraryDetails.action = nil;libraryDetails.isEnabled = false
        }
        if let detail = libraryDetailsAlert, !detail.action.matches(incoming,account:accountScope,epoch:epoch) {closeLibraryDetails()}
    }
    @objc func retry() {guard let s = snapshot, s.epoch == epoch, s.canRetryPlayback else {return};command(["command":"retry"])}
    @objc func seek() {command(["command":"seek","position_ms":UInt64(slider.doubleValue)])}
    func controlTextDidEndEditing(_ obj: Notification) {if (obj.object as? NSSearchField) === search {loadLibrary()}}
    func updateLibraryAvailability() {
        let authenticated = snapshot?.authenticated == true
        libraryDock?.setLibraryAvailability(selected:authenticated && table.selectedRow >= 0 && table.selectedRow < (snapshot?.library.count ?? 0),canLoadMore:authenticated && UInt64(snapshot?.library.count ?? 0) < (snapshot?.total ?? 0))
        updateLibraryDetailsAction()
    }
    func tableViewSelectionDidChange(_ notification: Notification) {updateLibraryAvailability()}
    func numberOfRows(in tableView: NSTableView)->Int {snapshot?.library.count ?? 0}
    func tableView(_ tableView: NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        guard let track = snapshot?.library[row] else{return nil}
        let id = tableColumn!.identifier
        let cell = (tableView.makeView(withIdentifier:id,owner:self) as? LibraryTrackCell) ?? LibraryTrackCell(frame:.zero)
        cell.identifier = id;cell.objectValue = track.id
        cell.configure(track:track,current:track.id == dockTrackID,scale:libraryDock?.textScale ?? 1,transport:snapshot?.transport ?? "paused")
        return cell
    }
    func tableView(_ tableView: NSTableView,rowViewForRow row: Int) -> NSTableRowView? {LibraryTrackRow()}
    func configureMediaControls() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.command(["command":"resume"]) };return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.command(["command":"pause"]) };return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() };return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.nextTrack() };return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previousTrack() };return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else{return .commandFailed}
            let ms = UInt64(max(event.positionTime,0)*1000)
            Task { @MainActor in self?.command(["command":"seek","position_ms":ms]) };return .success
        }
    }
    func keychainQuery()->[String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:keychainService,kSecAttrAccount as String:endpoint.stringValue,kSecUseDataProtectionKeychain as String:false] }
    func loadCredentials()->Credentials? {var q = keychainQuery();q[kSecReturnData as String] = true;q[kSecMatchLimit as String] = kSecMatchLimitOne;var result:CFTypeRef?;guard SecItemCopyMatching(q as CFDictionary,&result) == errSecSuccess,let data = result as? Data else{return nil};return try? JSONDecoder().decode(Credentials.self,from:data)}
    func storeCredentials(_ credentials: Credentials,epoch admitted: UInt64) {
        guard epoch == admitted,let version = credentials.version,version > 0 else{return}
        if storedCredentialVersion == version {
            command(["command":"acknowledge_credentials","version":version]);return
        }
        guard let bytes = try? JSONEncoder().encode(credentials) else{return}
        var q = keychainQuery();q[kSecValueData as String] = bytes;q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(q as CFDictionary,nil)
        if result == errSecDuplicateItem {
            guard SecItemUpdate(keychainQuery() as CFDictionary,[kSecValueData as String:bytes] as CFDictionary) == errSecSuccess else {status.stringValue = "Could not save session";return}
        } else if result != errSecSuccess {status.stringValue = "Could not save session";return}
        storedCredentialVersion = version
        command(["command":"acknowledge_credentials","version":version])
    }
    func deleteCredentials() {SecItemDelete(keychainQuery() as CFDictionary)}
    func applicationWillTerminate(_ notification:Notification) {
        if phaseConfiguration != nil {
            fixtureJourneyTask?.cancel()
            _ = finishPhaseMeasurement(passed:false,code:"termination")
        }
        retireLibraryDetails();closeQueueName();timer?.invalidate();player?.pause();observation = nil;player?.replaceCurrentItem(with:nil);player = nil;_ = bridge.revoke()
    }
    func windowWillClose(_ notification:Notification) {retireLibraryDetails()}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}
}

// This runs before NSApplication.shared and before any bridge/window/login.
let phaseConfiguration: FixturePhaseConfiguration?
do {phaseConfiguration = try FixturePhaseConfiguration.prepare(arguments:CommandLine.arguments,environment:ProcessInfo.processInfo.environment)}
catch {fputs("SOUNDQ_PHASE_SETUP_FAILED\n",stderr);exit(EXIT_FAILURE)}
let resourceProbe = CommandLine.arguments.contains("--resources-only")
if resourceProbe {
    do {
        let assets = try NativeAssets.load()
        print("SOUNDQ_RESOURCES_PASS fonts=6 licenses=2 logo=1 root=\(assets.root.path)")
    } catch {fputs("SoundQ resource verification failed: \(error)\n",stderr);exit(1)}
} else {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = App()
    delegate.phaseConfiguration = phaseConfiguration
    application.delegate = delegate
    application.run()
}
