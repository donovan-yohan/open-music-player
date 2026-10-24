import AppKit
import AVFoundation
import MediaPlayer
import Security
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
    let queue: [Occurrence]
    let transport: String
    let position_ms: UInt64
    let duration_ms: UInt64
    let error: String?
}
struct AudioEffect: Decodable {
    let action: String
    let epoch: UInt64
    let session: UInt64
    let path: String?
    let position_ms: UInt64
    let cached: Bool
}
struct Credentials: Codable { let access_token: String; let refresh_token: String; let account_id: String }
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
final class App: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
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
    var search = NSSearchField()
    var slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    var loginArea = NSStackView()
    var libraryArea = NSStackView()
    var play = NSButton(title: "Play", target: nil, action: nil)
    var logout = NSButton(title: "Sign out", target: nil, action: nil)
    var scroll = NSScrollView()
    var keychainService = "com.soundq.native.preview.credentials.v1"
    var busy = 0
    var journeyStarted = false
    var lastEffectCached = false
    var wantsPlayback = false

    func fixtureCacheRoot() -> URL? {
        guard endpoint.stringValue == "http://127.0.0.1:54761/api/v1",
              let path = ProcessInfo.processInfo.environment["SOUNDQ_NATIVE_CACHE_ROOT"],
              path.hasPrefix("/") else {return nil}
        return URL(fileURLWithPath:path)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        endpoint.stringValue = environment["OMP_API_BASE_URL"] ?? "https://soundq.fish-rattlesnake.ts.net/api/v1"
        let root = fixtureCacheRoot() ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.soundq.native.preview")
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
            command(["command":"restore", "access_token":saved.access_token, "refresh_token":saved.refresh_token, "account_id":saved.account_id]) { [weak self] in self?.loadLibrary() }
        } else { command(["command":"snapshot"]) }
    }
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 100,y: 100,width: 1100,height: 760),styleMask: [.titled,.closable,.miniaturizable,.resizable],backing: .buffered,defer: false)
        window.title = "SoundQ Native Preview"
        window.minSize = NSSize(width: 760,height: 540)
        let content = NSStackView();content.orientation = .vertical;content.spacing = 16;content.edgeInsets = NSEdgeInsets(top: 20,left: 24,bottom: 20,right: 24)
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor),content.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor),content.topAnchor.constraint(equalTo:window.contentView!.topAnchor),content.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor)])
        titleLabel.font = .monospacedSystemFont(ofSize: 25,weight: .bold)
        let heading = NSStackView(views:[titleLabel,NSView(),logout]);heading.orientation = .horizontal;heading.distribution = .fill
        logout.target = self;logout.action = #selector(signOut)
        content.addArrangedSubview(heading);heading.widthAnchor.constraint(equalTo:content.widthAnchor,constant:-48).isActive = true
        email.placeholderString = "Email";password.placeholderString = "Password"
        endpoint.placeholderString = "API base URL"
        endpoint.isEditable = false
        loginArea.orientation = .vertical;loginArea.alignment = .leading;loginArea.spacing = 10
        for field in [endpoint,email,password] {field.widthAnchor.constraint(equalToConstant:420).isActive = true; loginArea.addArrangedSubview(field)}
        let signIn = NSButton(title:"Sign in",target:self,action:#selector(signIn));signIn.keyEquivalent = "\r";loginArea.addArrangedSubview(signIn)
        content.addArrangedSubview(loginArea)
        search.placeholderString = "Search your library";search.delegate = self
        let refresh = NSButton(title:"Refresh",target:self,action:#selector(refresh))
        let more = NSButton(title:"Load more",target:self,action:#selector(loadMore))
        let searchRow = NSStackView(views:[search,refresh,more]);searchRow.orientation = .horizontal
        libraryArea.orientation = .vertical;libraryArea.spacing = 8
        libraryArea.addArrangedSubview(searchRow)
        table.addTableColumn(NSTableColumn(identifier:NSUserInterfaceItemIdentifier("title")))
        table.tableColumns[0].title = "TITLE";table.tableColumns[0].width = 510
        let artist = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("artist"));artist.title = "ARTIST";artist.width = 300;table.addTableColumn(artist)
        table.headerView = NSTableHeaderView();table.rowHeight = 44;table.usesAlternatingRowBackgroundColors = true
        table.delegate = self;table.dataSource = self;table.target = self;table.doubleAction = #selector(selectTrack)
        table.setAccessibilityLabel("Library tracks")
        table.autosaveName = "SoundQNativeLibrary";table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        scroll.documentView = table;scroll.hasVerticalScroller = true;scroll.autohidesScrollers = true
        scroll.setAccessibilityLabel("Library scroll area")
        libraryArea.addArrangedSubview(scroll);scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:200).isActive = true
        content.addArrangedSubview(libraryArea);libraryArea.widthAnchor.constraint(equalTo:content.widthAnchor,constant:-48).isActive = true
        searchRow.widthAnchor.constraint(equalTo:libraryArea.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo:libraryArea.widthAnchor).isActive = true
        libraryArea.setContentHuggingPriority(.defaultLow,for:.vertical)
        status.textColor = .secondaryLabelColor;status.maximumNumberOfLines = 2;content.addArrangedSubview(status)
        let select = NSButton(title:"Play selected",target:self,action:#selector(selectTrack))
        select.setAccessibilityIdentifier("play-selected")
        play.target = self;play.action = #selector(toggle)
        play.setAccessibilityIdentifier("toggle-playback")
        let retry = NSButton(title:"Retry",target:self,action:#selector(retry))
        let transport = NSStackView(views:[select,play,retry,transportLabel]);transport.orientation = .horizontal
        content.addArrangedSubview(transport)
        slider.target = self;slider.action = #selector(seek);slider.isContinuous = false
        slider.setAccessibilityLabel("Playback position")
        content.addArrangedSubview(slider);slider.widthAnchor.constraint(equalTo:content.widthAnchor,constant:-48).isActive = true
        let provenance = NSTextField(labelWithString:"Native preview · Rust core ABI 1 · " + (ProcessInfo.processInfo.environment["OMP_SOURCE_REF"] ?? "local source"))
        provenance.font = .monospacedSystemFont(ofSize:10,weight:.regular);provenance.textColor = .tertiaryLabelColor;content.addArrangedSubview(provenance)
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        let menu = NSMenu();let item = NSMenuItem();menu.addItem(item);let appMenu = NSMenu();appMenu.addItem(withTitle:"Quit SoundQ Native Preview",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");item.submenu = appMenu;NSApp.mainMenu = menu
    }
    func command(_ value: [String:Any], completion: (@MainActor () -> Void)? = nil) {
        guard busy < 32 else {status.stringValue = "Playback is busy. Try again.";return}
        let kind = value["command"] as? String ?? ""
        if ["select","resume","retry"].contains(kind) {wantsPlayback = true}
        if ["pause","logout","login"].contains(kind) {wantsPlayback = false;player?.pause()}
        guard let data = try? JSONSerialization.data(withJSONObject:value) else {return}
        let admittedEpoch = epoch
        busy += 1
        bridge.send(data, epoch: admittedEpoch) { [weak self] data in
            Task { @MainActor in
                guard let self else{return};self.busy -= 1
                guard admittedEpoch == self.epoch else{self.reportPending = false;return}
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
        let rowsChanged = !value.library_unchanged && (snapshot?.library.map(\.id) != value.library.map(\.id) || snapshot?.library.map(\.title) != value.library.map(\.title))
        snapshot = value
        loginArea.isHidden = value.authenticated;libraryArea.isHidden = !value.authenticated;logout.isHidden = !value.authenticated
        if rowsChanged {table.reloadData()}
        titleLabel.stringValue = value.authenticated ? "SoundQ / Library" : "SoundQ"
        transportLabel.stringValue = (value.queue.first?.track.title ?? "No selection") + " · " + value.transport
        play.title = value.transport == "playing" ? "Pause" : "Play"
        play.isEnabled = !value.queue.isEmpty
        slider.maxValue = Double(max(value.duration_ms,1));slider.doubleValue = Double(value.position_ms)
        slider.isEnabled = !value.queue.isEmpty
        status.stringValue = value.error?.replacingOccurrences(of:"_",with:" ") ?? "\(value.library.count) of \(value.total) tracks"
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
            if wantsPlayback {player?.play()}
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle:snapshot?.queue.first?.track.title ?? "SoundQ",MPMediaItemPropertyArtist:snapshot?.queue.first?.track.artist ?? ""]
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
        guard time.isFinite else{return}
        let nativeState = state ?? (player.error != nil ? "failed" : player.rate > 0 ? "playing" : (duration.isFinite && time >= duration-0.05 ? "ended" : "paused"))
        reportPending = true
        command(["command":"audio_report","epoch":epoch,"session":snapshot.session,"state":nativeState,"position_ms":UInt64(max(time,0)*1000),"duration_ms":duration.isFinite ? UInt64(max(duration,0)*1000) : snapshot.duration_ms]) { [weak self] in self?.reportPending = false }
        MPNowPlayingInfoCenter.default().playbackState = player.rate > 0 ? .playing : .paused
    }
    func loadLibrary(offset: Int = 0) {command(["command":"library","offset":offset,"query":search.stringValue,"sort":"added_at","order":"desc"])}
    @objc func signIn() {
        player?.pause();player?.replaceCurrentItem(with:nil);player = nil;epoch = bridge.revoke()

        command(["command":"login","email":email.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),"password":password.stringValue]) { [weak self] in
            guard let self,self.snapshot?.authenticated == true else{return}
            self.password.stringValue = "";self.loadLibrary()
        }
    }
    @objc func signOut() {player?.pause();observation = nil;player?.replaceCurrentItem(with:nil);player = nil;epoch = bridge.revoke();deleteCredentials();command(["command":"logout"])}
    @objc func refresh() {loadLibrary()}
    @objc func loadMore() {loadLibrary(offset:snapshot?.library.count ?? 0)}
    @objc func selectTrack() {let row = table.selectedRow;guard let s = snapshot,row >= 0,row < s.library.count else{return};player?.pause();player?.replaceCurrentItem(with:nil);player = nil;epoch = bridge.revoke();command(["command":"select","track_id":s.library[row].id])}
    @objc func toggle() {command(["command":snapshot?.transport == "playing" ? "pause" : "resume"])}
    @objc func retry() {command(["command":"retry"])}
    @objc func seek() {command(["command":"seek","position_ms":UInt64(slider.doubleValue)])}
    func controlTextDidEndEditing(_ obj: Notification) {if (obj.object as? NSSearchField) === search {loadLibrary()}}
    func numberOfRows(in tableView: NSTableView)->Int {snapshot?.library.count ?? 0}
    func tableView(_ tableView: NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        guard let track = snapshot?.library[row] else{return nil}
        let id = tableColumn!.identifier
        let field = (tableView.makeView(withIdentifier:id,owner:self) as? NSTextField) ?? NSTextField(labelWithString:"")
        field.identifier = id;field.lineBreakMode = .byTruncatingTail
        field.stringValue = id.rawValue == "title" ? track.title : (track.artist ?? "Unknown artist")
        return field
    }
    func configureMediaControls() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.command(["command":"resume"]) };return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.command(["command":"pause"]) };return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() };return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else{return .commandFailed}
            let ms = UInt64(max(event.positionTime,0)*1000)
            Task { @MainActor in self?.command(["command":"seek","position_ms":ms]) };return .success
        }
    }
    func keychainQuery()->[String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:keychainService,kSecAttrAccount as String:endpoint.stringValue,kSecUseDataProtectionKeychain as String:false] }
    func loadCredentials()->Credentials? {var q = keychainQuery();q[kSecReturnData as String] = true;q[kSecMatchLimit as String] = kSecMatchLimitOne;var result:CFTypeRef?;guard SecItemCopyMatching(q as CFDictionary,&result) == errSecSuccess,let data = result as? Data else{return nil};return try? JSONDecoder().decode(Credentials.self,from:data)}
    func storeCredentials(_ credentials: Credentials,epoch admitted: UInt64) {
        guard epoch == admitted,let bytes = try? JSONEncoder().encode(credentials) else{return}
        var q = keychainQuery();q[kSecValueData as String] = bytes;q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(q as CFDictionary,nil)
        if result == errSecDuplicateItem {
            if SecItemUpdate(keychainQuery() as CFDictionary,[kSecValueData as String:bytes] as CFDictionary) != errSecSuccess {status.stringValue = "Could not save session"}
        } else if result != errSecSuccess {status.stringValue = "Could not save session"}
    }
    func deleteCredentials() {SecItemDelete(keychainQuery() as CFDictionary)}
    func applicationWillTerminate(_ notification:Notification) {timer?.invalidate();player?.pause();observation = nil;player?.replaceCurrentItem(with:nil);player = nil;_ = bridge.revoke()}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = App()
application.delegate = delegate
application.run()
