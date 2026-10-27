import AppKit
import QuartzCore

// A projection, never a queue/controller. Only a queue-content/identity publication
// resolves the occurrence. Scalar reports reuse these small values in App.
struct DockChrome {
    let epoch: UInt64
    let session: UInt64
    let occurrence: UInt64?
    let trackID: Int64?
    let title: String
    let artist: String
    let transport: String
    let previous: Bool
    let next: Bool
    let count: Int
    init(_ value: Snapshot) {
        let index = value.queue.firstIndex(where:{$0.id == value.selected_occurrence})
        let track = index.map {value.queue[$0].track}
        epoch = value.epoch;session = value.session;occurrence = value.selected_occurrence
        trackID = track?.id;title = track?.title ?? (value.queue.isEmpty ? "No queued track" : "No current track");artist = track?.artist ?? ""
        transport = value.transport;previous = index.map {$0 > 0} ?? false
        next = index.map {$0+1 < value.queue.count} ?? false;count = value.queue.count
    }
    func sameIdentity(as other: Self?) -> Bool {
        guard let other else {return false}
        return epoch == other.epoch && session == other.session && occurrence == other.occurrence && trackID == other.trackID
    }
}

final class FlippedLibraryDocument: NSView {
    override var isFlipped: Bool {true}
    var rules: [CGFloat] = [] {didSet {needsDisplay = true}}
    override func draw(_ dirtyRect: NSRect) {
        SoundQTokens.resolve(effectiveAppearance).outline.setFill()
        for y in rules {NSRect(x:0,y:y,width:bounds.width,height:1).fill()}
    }
}

struct LibraryDockControls {
    let table: NSTableView;let scroll: NSScrollView;let search: NSSearchField
    let slider: NSSlider;let play: NSButton;let title: NSTextField
    let identity: NSTextField;let status: NSTextField;let login: NSStackView
    let library: NSStackView;let logout: NSButton
    let refresh: NSButton;let more: NSButton;let select: NSButton;let details: NSButton
    let retry: NSButton;let previous: NSButton;let next: NSButton;let queue: NSButton
}

// Presentation borrows the real controls. No Bridge, player, account, credentials,
// request lifecycle or second navigation state is retained here.
final class LibraryDockView: NSView {
    let controls: LibraryDockControls
    let liked: SoundQButton?
    let addLink: SoundQButton?
    let emblem = NSImageView()
    let wordmark = NSTextField(labelWithString:"SoundQ")
    let navigation = SoundQButton(title:"Library",target:nil,action:nil)
    let artist = NSTextField(labelWithString:"")
    let dockNote = NSImageView()
    let elapsed = NSTextField(labelWithString:"0:00")
    let duration = NSTextField(labelWithString:"0:00")
    let empty = NSTextField(labelWithString:"Your library is empty. Refresh to check for tracks.")
    let bodyScroll = NSScrollView()
    let bodyDocument = FlippedLibraryDocument()
    let railScroll = NSScrollView()
    let railDocument = FlippedLibraryDocument()
    private let outgoing = NSTextField(labelWithString:"")
    private(set) var chromeEntries = 0
    private(set) var progressEntries = 0
    private(set) var identityAnimations = 0
    private(set) var rowTreatmentEntries = 0
    private(set) var railWidth: CGFloat = 80
    private(set) var dockHeight: CGFloat = 100
    private(set) var centerWidth: CGFloat = 480
    var libraryReadFailed = false {didSet {if libraryReadFailed != oldValue {needsLayout = true}}}
    var textScale: CGFloat = 1 {didSet {if textScale != oldValue {applyTypography();needsLayout = true}}}
    var reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {didSet {if reduceMotion {cancelMotion()}}}
    private var chrome: DockChrome?
    private var generation: UInt64 = 0
    override var isFlipped: Bool {true}
    override var intrinsicContentSize: NSSize {NSSize(width:NSView.noIntrinsicMetric,height:NSView.noIntrinsicMetric)}
    override var fittingSize: NSSize {NSSize(width:760,height:540)}
    init(controls: LibraryDockControls, assets: NativeAssets, liked: SoundQButton? = nil, addLink: SoundQButton? = nil) {
        self.controls = controls;self.liked = liked;self.addLink = addLink
        super.init(frame:.zero)
        wantsLayer = true
        addSubview(bodyScroll);bodyScroll.documentView = bodyDocument;bodyScroll.hasVerticalScroller = true;bodyScroll.autohidesScrollers = true;bodyScroll.drawsBackground = false
        addSubview(railScroll);railScroll.documentView = railDocument;railScroll.hasVerticalScroller = true;railScroll.autohidesScrollers = true;railScroll.drawsBackground = false
        for view in [emblem,wordmark,navigation,controls.logout] {railDocument.addSubview(view)}
        for view in [controls.title,controls.search,controls.refresh,controls.more,controls.select,controls.details,controls.retry,controls.login,controls.library,controls.status,empty] {bodyDocument.addSubview(view)}
        if let liked {bodyDocument.addSubview(liked)}
        if let addLink {bodyDocument.addSubview(addLink)}
        for view in [controls.identity,artist,dockNote,controls.previous,controls.play,controls.next,controls.queue,controls.slider,elapsed,duration,outgoing] {addSubview(view)}
        dockNote.image = NSImage(systemSymbolName:"music.note",accessibilityDescription:"No artwork available")
        emblem.image = assets.logo;emblem.imageScaling = .scaleProportionallyUpOrDown
        emblem.setAccessibilityLabel("SoundQ emblem")
        navigation.selected = true;navigation.target = self;navigation.action = #selector(focusLibrary)
        navigation.toolTip = "Library";navigation.setAccessibilityLabel("Library, selected")
        for label in [controls.identity,artist,outgoing] {
            label.lineBreakMode = .byWordWrapping;label.maximumNumberOfLines = 1
            label.cell?.truncatesLastVisibleLine = true;label.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
            label.wantsLayer = true
        }
        outgoing.isHidden = true
        controls.status.maximumNumberOfLines = 2;controls.status.lineBreakMode = .byWordWrapping
        empty.maximumNumberOfLines = 0;empty.lineBreakMode = .byWordWrapping;empty.isHidden = true
        applyTypography()
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(displayOptionsChanged),name:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil)
    }
    required init?(coder: NSCoder) {fatalError("init(coder:) unsupported")}
    @objc func displayOptionsChanged() {reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion}
    @objc func focusLibrary() {window?.makeFirstResponder(controls.search)}
    func setPlaybackRetryAvailable(_ available: Bool) {controls.retry.isEnabled = available}
    func setLibraryAvailability(selected: Bool, canLoadMore: Bool) {controls.select.isEnabled = selected;controls.more.isEnabled = canLoadMore}
    override func viewDidMoveToWindow() {super.viewDidMoveToWindow();needsLayout = true}
    func applyTypography() {
        wordmark.font = NativeAssets.font(28,weight:600,scale:textScale)
        controls.title.font = NativeAssets.font(22,weight:600,scale:textScale)
        navigation.font = NativeAssets.font(14,weight:600,scale:textScale)
        controls.identity.font = NativeAssets.font(16,weight:500,scale:textScale)
        outgoing.font = controls.identity.font;artist.font = NativeAssets.font(12,scale:textScale)
        controls.status.font = NativeAssets.font(12,scale:textScale);empty.font = NativeAssets.font(16,scale:textScale)
        controls.search.font = NativeAssets.font(14,scale:textScale)
        for label in [elapsed,duration] {label.font = NativeAssets.font(11,mono:true,scale:textScale)}
        for button in [controls.refresh,controls.more,controls.select,controls.details,controls.retry,controls.previous,controls.play,controls.next,controls.queue,controls.logout,navigation] {
            button.font = NativeAssets.font(14,weight:500,scale:textScale)
            (button as? SoundQButton)?.textScale = textScale
        }
        liked?.font = controls.refresh.font;liked?.textScale = textScale
        addLink?.font = controls.refresh.font;addLink?.textScale = textScale
        controls.table.rowHeight = SoundQTokens.grid(56*textScale)
        controls.table.noteHeightOfRows(withIndexesChanged:IndexSet(integersIn:0..<controls.table.numberOfRows))
        // Native availability includes retained/in-flight rows outside visibleRect.
        // Refresh only instantiated cells on typography changes, never all tracks.
        controls.table.enumerateAvailableRowViews { row, _ in
            for case let cell as LibraryTrackCell in row.subviews {cell.applyTypography(scale:self.textScale)}
        }
    }
    override func viewDidChangeEffectiveAppearance() {super.viewDidChangeEffectiveAppearance();needsDisplay = true;applyColors()}
    func applyColors() {
        let tokens = SoundQTokens.resolve(effectiveAppearance)
        for label in [wordmark,controls.title,controls.identity,outgoing] {label.textColor = tokens.text}
        for label in [artist,elapsed,duration,controls.status,empty] {label.textColor = tokens.neutral}
        dockNote.contentTintColor = tokens.neutral
        layer?.backgroundColor = tokens.background.cgColor
        bodyDocument.layer?.backgroundColor = tokens.background.cgColor
        controls.table.backgroundColor = tokens.surface;controls.scroll.backgroundColor = tokens.surface
        controls.search.backgroundColor = tokens.surface;controls.search.textColor = tokens.text
        controls.search.isBezeled = false;controls.search.drawsBackground = true
        controls.slider.controlSize = .regular
        controls.slider.trackFillColor = tokens.primary
    }
    static func timestamp(_ ms: UInt64) -> String {let seconds = ms/1000;return "\(seconds/60):"+String(format:"%02llu",seconds%60)}
    func updateChrome(_ value: DockChrome) {
        chromeEntries += 1
        let changed = !value.sameIdentity(as:chrome)
        if changed {transitionIdentity(to:value.title)} else if !controls.identity.stringValue.utf8.elementsEqual(value.title.utf8) {controls.identity.stringValue = value.title}
        artist.stringValue = value.artist
        if chrome?.transport != value.transport {
            let button = controls.play as? SoundQButton
            button?.symbol = value.transport == "playing" ? "pause.fill" : "play.fill"
            animate(controls.play,key:"play",duration:SoundQTokens.playDuration)
        }
        controls.identity.setAccessibilityLabel("\(value.title), \(value.transport)")
        controls.previous.isEnabled = value.previous;controls.next.isEnabled = value.next
        controls.queue.setAccessibilityLabel("Queue, \(value.count) tracks")
        chrome = value
    }
    func updateProgress(position: UInt64, duration: UInt64) {
        progressEntries += 1;elapsed.stringValue = Self.timestamp(position);self.duration.stringValue = Self.timestamp(duration)
        controls.slider.setAccessibilityValueDescription("\(elapsed.stringValue) of \(self.duration.stringValue)")
    }
    func updateContent(empty: Bool) {self.empty.isHidden = !empty || libraryReadFailed || controls.library.isHidden}
    func updateAuthentication(_ authenticated: Bool) {
        for view in [controls.search,controls.refresh,controls.more,controls.select,controls.details] {view.isHidden = !authenticated}
        liked?.isHidden = !authenticated
        addLink?.isHidden = !authenticated
        empty.isHidden = !authenticated || controls.table.numberOfRows != 0
    }
    func updateCurrent(old: Int64?, new: Int64?) {
        rowTreatmentEntries += 1
        let range = controls.table.rows(in:controls.table.visibleRect)
        guard range.location != NSNotFound else {return}
        for row in range.location..<NSMaxRange(range) {
            if let cell = controls.table.view(atColumn:0,row:row,makeIfNecessary:false) as? LibraryTrackCell {
                // The App data source sets an identifier carrying the actual ID.
                let id = cell.objectValue as? Int64
                if id == old || id == new {cell.setCurrent(id == new,transport:chrome?.transport ?? "paused")}
            }
        }
    }
    private func transitionIdentity(to title: String) {
        generation &+= 1;let admitted = generation
        outgoing.stringValue = controls.identity.stringValue;outgoing.frame = controls.identity.frame
        outgoing.isHidden = reduceMotion || chrome == nil
        if !outgoing.isHidden {
            let exit = CAAnimationGroup();let fade = CABasicAnimation(keyPath:"opacity");fade.fromValue = controls.identity.layer?.presentation()?.opacity ?? 1;fade.toValue = 0
            let slide = CABasicAnimation(keyPath:"transform.translation.y");slide.fromValue = controls.identity.layer?.presentation()?.value(forKeyPath:"transform.translation.y") ?? 0;slide.toValue = -controls.identity.bounds.height*SoundQTokens.identityOffset
            exit.animations = [fade,slide];exit.duration = SoundQTokens.identityDuration;exit.timingFunction = CAMediaTimingFunction(controlPoints:0.55,0.055,0.675,0.19)
            CATransaction.begin();CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated {guard let self,self.generation == admitted else {return};self.outgoing.isHidden = true} }
            outgoing.layer?.opacity = 0;outgoing.layer?.add(exit,forKey:"identity-exit");CATransaction.commit()
        }
        controls.identity.stringValue = title
        if chrome != nil {identityAnimations += 1;animate(controls.identity,key:"identity",duration:SoundQTokens.identityDuration)}
    }
    private func animate(_ view: NSView, key: String, duration: CFTimeInterval) {
        guard !reduceMotion, let layer = key == "play" ? (view as? SoundQButton)?.glyphLayer : view.layer else {return}
        let interrupted = layer.animation(forKey:key) != nil
        let fade = CABasicAnimation(keyPath:"opacity");fade.fromValue = interrupted ? layer.presentation()?.opacity ?? 0 : 0;fade.toValue = 1
        let slide = CABasicAnimation(keyPath:"transform.translation.y");slide.fromValue = interrupted ? layer.presentation()?.value(forKeyPath:"transform.translation.y") ?? 0 : view.bounds.height*SoundQTokens.identityOffset;slide.toValue = 0
        let group = CAAnimationGroup();group.animations = key == "identity" ? [fade,slide] : [fade];group.duration = duration;group.timingFunction = CAMediaTimingFunction(controlPoints:0.215,0.61,0.355,1)
        layer.removeAnimation(forKey:key);layer.opacity = 1;layer.transform = CATransform3DIdentity;layer.add(group,forKey:key)
    }
    private func cancelMotion() {generation &+= 1;for view in [controls.identity,outgoing] {view.layer?.removeAllAnimations();view.layer?.opacity = 1;view.layer?.transform = CATransform3DIdentity};(controls.play as? SoundQButton)?.glyphLayer.removeAllAnimations();outgoing.isHidden = true}
    override func layout() {
        super.layout();let w = bounds.width,h = bounds.height,s = textScale
        let masthead = SoundQTokens.grid(max(64,40*s+24),unit:8)
        railWidth = w >= 1200 ? SoundQTokens.grid(max(224,wordmark.intrinsicContentSize.width+88),unit:8) : 80
        let cell = SoundQTokens.grid(max(48,48*s)), secondary = SoundQTokens.grid(max(40,40*s))
        let reflow = w < 960 || s > 1
        dockHeight = reflow ? SoundQTokens.grid(48*s+cell+52*s+16) : 100
        centerWidth = min(w-32,max(480,min(560,w*0.5)))
        let dockY = max(masthead,h-dockHeight)
        emblem.frame = NSRect(x:20,y:(masthead-40)/2,width:40,height:40)
        wordmark.isHidden = w < 1200;wordmark.frame = NSRect(x:72,y:(masthead-40*s)/2,width:max(0,railWidth-80),height:40*s)
        navigation.symbol = w < 1200 ? "music.note.list" : nil
        navigation.frame = NSRect(x:0,y:masthead,width:railWidth,height:cell)
        bodyScroll.frame = NSRect(x:railWidth+1,y:0,width:max(1,w-railWidth-1),height:dockY)
        railScroll.frame = NSRect(x:0,y:0,width:railWidth,height:dockY)
        let left: CGFloat = 24, available = max(1,bodyScroll.contentSize.width-48)
        controls.title.frame = NSRect(x:left,y:(masthead-32*s)/2,width:available,height:32*s)
        let secondaryButtons: [NSButton] = [controls.refresh,controls.more,controls.select,controls.details,controls.retry] + (liked.map {[$0]} ?? []) + (addLink.map {[$0]} ?? [])
        // The inherited native cell can require more width than our painted
        // title + padding intrinsic size (linked AppKit treatments differ).
        // Allocate both contracts before wrapping; keep the shared height/grid.
        let buttonWidths = secondaryButtons.map {liked == nil ? max(40,$0.intrinsicContentSize.width) : SoundQTokens.grid(max(40,$0.intrinsicContentSize.width,$0.cell?.cellSize.width ?? 0))}
        let actionsWidth = buttonWidths.reduce(0,+)+CGFloat(secondaryButtons.count-1)*8
        let wrap = available < actionsWidth+200
        let headingHeight = masthead
        controls.search.frame = NSRect(x:left,y:headingHeight+16,width:wrap ? available : available-actionsWidth-8,height:secondary)
        if liked != nil && !wrap {controls.search.frame.size.width = floor(controls.search.frame.width/4)*4}
        var x = wrap ? left : controls.search.frame.maxX+8
        var y = wrap ? controls.search.frame.maxY+8 : controls.search.frame.minY
        for (button,width) in zip(secondaryButtons,buttonWidths) {
            if x+width>left+available && x>left {x = left;y += secondary+8}
            button.frame = NSRect(x:x,y:y,width:min(available,width),height:secondary);x += width+8
        }
        // Keep corrective feedback on the next 8pt track after wrapped actions.
        let bodyTop = max(164*s,y+secondary+(libraryReadFailed ? 8 : 16))
        bodyDocument.rules = [headingHeight,bodyTop-1];railDocument.rules = [masthead]
        let statusHeight = SoundQTokens.grid(max(32,32*s))
        let auth = controls.login as? AuthFormView
        let authWidth = min(available,420)
        let authHeight = controls.login.isHidden ? CGFloat(0) : (auth?.requiredHeight(width:authWidth,scale:s) ?? 0)
        let documentHeight = max(dockY,bodyTop+112*s+statusHeight+16,authHeight > 0 ? masthead+authHeight+statusHeight+40 : 0)
        bodyDocument.frame = NSRect(x:0,y:0,width:bodyScroll.contentSize.width,height:documentHeight)
        controls.status.frame = NSRect(x:left,y:libraryReadFailed ? bodyTop : documentHeight-statusHeight-8,width:available,height:statusHeight)
        let libraryTop = libraryReadFailed ? controls.status.frame.maxY+8 : bodyTop
        controls.library.frame = NSRect(x:0,y:libraryTop,width:bodyDocument.bounds.width,height:max(56,(libraryReadFailed ? documentHeight-8 : controls.status.frame.minY-8)-libraryTop))
        controls.scroll.frame = controls.library.bounds
        let railHeight = max(dockY,masthead+cell+secondary+40)
        railDocument.frame = NSRect(x:0,y:0,width:railWidth,height:railHeight)
        controls.logout.frame = NSRect(x:8,y:railHeight-secondary-16,width:railWidth-16,height:secondary)
        controls.logout.title = w < 1200 ? "" : "Sign out"
        (controls.logout as? SoundQButton)?.symbol = w < 1200 ? "rectangle.portrait.and.arrow.right" : nil
        navigation.focusDisclosure = w < 1200
        controls.login.frame = NSRect(x:left,y:masthead+16,width:authWidth,height:authHeight > 0 ? authHeight : max(1,documentHeight-masthead-24))
        empty.frame = NSRect(x:left,y:bodyTop+24,width:available,height:80*s)
        let centerX = w/2
        let commandY = dockY+(reflow ? 48*s : 0)
        for (index,button) in [controls.previous,controls.play,controls.next].enumerated() {button.frame = NSRect(x:centerX-cell*1.5+CGFloat(index)*cell,y:commandY,width:cell,height:cell)}
        let outer = (w-centerWidth)/2
        let identityY = dockY+8
        dockNote.frame = NSRect(x:16,y:identityY,width:40*s,height:40*s)
        controls.identity.frame = NSRect(x:24+40*s,y:identityY,width:max(1,(reflow ? w-180 : outer)-48-40*s),height:24*s)
        artist.frame = NSRect(x:24+40*s,y:identityY+24*s,width:controls.identity.frame.width,height:20*s)
        controls.queue.frame = NSRect(x:w-max(104,controls.queue.intrinsicContentSize.width),y:dockY,width:max(104,controls.queue.intrinsicContentSize.width),height:secondary)
        let progressY = commandY+cell+4
        let numeric = max(40,64*s)
        elapsed.frame = NSRect(x:centerX-centerWidth/2,y:progressY+8*s,width:numeric,height:20*s)
        duration.frame = NSRect(x:centerX+centerWidth/2-numeric,y:progressY+8*s,width:numeric,height:20*s)
        controls.slider.frame = NSRect(x:elapsed.frame.maxX+8,y:progressY,width:max(1,centerWidth-2*numeric-16),height:40*s)
        applyColors()
    }
    override func draw(_ dirtyRect: NSRect) {
        let tokens = SoundQTokens.resolve(effectiveAppearance);tokens.background.setFill();bounds.fill()
        tokens.surface.setFill();NSRect(x:0,y:bounds.height-dockHeight,width:bounds.width,height:dockHeight).fill()
        tokens.outline.setFill()
        NSRect(x:railWidth,y:0,width:1,height:max(0,bounds.height-dockHeight)).fill()
        NSRect(x:0,y:bounds.height-dockHeight,width:bounds.width,height:1).fill()
        let outer = (bounds.width-centerWidth)/2
        NSRect(x:outer,y:controls.play.frame.maxY,width:centerWidth,height:1).fill()
        if bounds.width >= 960 && textScale == 1 {
            for x in [outer,outer+centerWidth] {NSRect(x:x,y:bounds.height-dockHeight,width:1,height:dockHeight).fill()}
        }
    }
}
