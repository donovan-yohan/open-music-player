import AppKit

// Paint only: NSButton/NSButtonCell retain target/action, tracking, keyboard,
// responder and accessibility press ownership.
final class SoundQButtonCell: NSButtonCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {(controlView as? SoundQButton)?.drawSoundQ()}
}

final class SoundQButton: NSButton {
    override class var cellClass: AnyClass? {get {SoundQButtonCell.self} set {}}
    let glyphLayer = CALayer()
    override init(frame: NSRect) {super.init(frame:frame);wantsLayer = true;layer?.addSublayer(glyphLayer)}
    required init?(coder: NSCoder) {super.init(coder:coder);wantsLayer = true;layer?.addSublayer(glyphLayer)}
    var primary = false {didSet {needsDisplay = true}}
    var selected = false {didSet {needsDisplay = true}}
    var symbol: String? {didSet {needsDisplay = true}}
    var glyphSize: CGFloat = 20
    var textScale: CGFloat = 1
    private(set) var hovered = false
    override var isEnabled: Bool {didSet {needsDisplay = true}}
    override var acceptsFirstResponder: Bool {isEnabled}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {true}
    var focusDisclosure = false {didSet {guard focusDisclosure != oldValue else {return};if !focusDisclosure {disclosure?.close();disclosure = nil} else if keyboardFocused {showDisclosure()}}}
    private var disclosure: NSPopover?
    private func showDisclosure() {
        guard focusDisclosure, disclosure == nil, window != nil else {return}
        let label = NSTextField(labelWithString:accessibilityLabel() ?? title)
        label.font = font;label.sizeToFit()
        let controller = NSViewController();controller.view = NSView(frame:NSRect(x:0,y:0,width:label.frame.width+24,height:label.frame.height+16));label.frame.origin = NSPoint(x:12,y:8);controller.view.addSubview(label)
        let popover = NSPopover();popover.contentViewController = controller;popover.behavior = .applicationDefined;popover.animates = false;disclosure = popover
        popover.show(relativeTo:bounds,of:self,preferredEdge:.maxX)
    }
    override func becomeFirstResponder() -> Bool {let accepted = super.becomeFirstResponder();needsDisplay = true;if accepted {showDisclosure()};return accepted}
    override func resignFirstResponder() -> Bool {let accepted = super.resignFirstResponder();needsDisplay = true;disclosure?.close();disclosure = nil;return accepted}
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {removeTrackingArea(area)}
        addTrackingArea(NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil))
    }
    override func mouseEntered(with event: NSEvent) {hovered = true;needsDisplay = true}
    override func mouseExited(with event: NSEvent) {hovered = false;needsDisplay = true}
    var keyboardFocused: Bool {window?.firstResponder === self}
    override func draw(_ dirtyRect: NSRect) {drawSoundQ()}
    func drawSoundQ() {
        let tokens = SoundQTokens.resolve(effectiveAppearance)
        let paint = tokens.paint(enabled:isEnabled,primary:primary,selected:selected,hover:hovered,focus:keyboardFocused,pressed:cell?.isHighlighted == true)
        paint.surface.setFill();bounds.fill()
        paint.border.setStroke();let edge = NSBezierPath(rect:bounds.insetBy(dx:0.5,dy:0.5));edge.lineWidth = 1;edge.stroke()
        if selected {tokens.primary.setFill();NSRect(x:0,y:0,width:4,height:bounds.height).fill()}
        if let symbol, let image = NSImage(systemSymbolName:symbol,accessibilityDescription:title)?.withSymbolConfiguration(.init(pointSize:glyphSize*textScale,weight:.regular))?.withSymbolConfiguration(.init(paletteColors:[paint.foreground])) {
            let side = glyphSize*textScale
            CATransaction.begin();CATransaction.setDisableActions(true)
            glyphLayer.frame = NSRect(x:(bounds.width-side)/2,y:(bounds.height-side)/2,width:side,height:side)
            var proposed = NSRect(x:0,y:0,width:side,height:side)
            glyphLayer.contents = image.cgImage(forProposedRect:&proposed,context:nil,hints:nil)
            glyphLayer.contentsScale = window?.backingScaleFactor ?? 2;glyphLayer.isHidden = false
            CATransaction.commit()
        } else {
            glyphLayer.isHidden = true
            let attributes: [NSAttributedString.Key:Any] = [.font:font ?? NativeAssets.font(14,scale:textScale),.foregroundColor:paint.foreground]
            let size = (title as NSString).size(withAttributes:attributes)
            (title as NSString).draw(at:NSPoint(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2),withAttributes:attributes)
        }
        // Independent inset perimeter remains distinguishable on cyan hover and
        // held press; do not layer translucent ink over resolved text colors.
        if keyboardFocused && isEnabled {
            paint.foreground.setStroke();let focus = NSBezierPath(rect:bounds.insetBy(dx:3,dy:3));focus.lineWidth = 2;focus.stroke()
        }
    }
    override var intrinsicContentSize: NSSize {
        let size = (title as NSString).size(withAttributes:[.font:font ?? NSFont.systemFont(ofSize:14)])
        return NSSize(width:symbol == nil ? SoundQTokens.grid(max(40,size.width+24)) : 40,height:SoundQTokens.grid(max(40,size.height+16)))
    }
}

// The unbordered native cell gives text the entire tall control while its
// search/cancel cells are centered. Constrain only the native text/editor track;
// NSSearchFieldCell still owns glyphs, editing, selection and search dispatch.
final class SoundQSearchFieldCell: NSSearchFieldCell {
    // The shared editor paints its native placeholder outside drawInterior.
    // Only that editor's paint uses font metrics; native input/setup still sees
    // the single-line policy (including separator filtering and Return).
    override var usesSingleLineMode: Bool {
        get {
            if let editor = (controlView as? NSTextField)?.currentEditor(),
               let drawing = NSView.focusView,
               drawing === editor || drawing.isDescendant(of:editor) {return false}
            return super.usesSingleLineMode
        }
        set {super.usesSingleLineMode = newValue}
    }
    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        var text = super.searchTextRect(forBounds:rect)
        let font = font ?? NSFont.systemFont(ofSize:NSFont.systemFontSize)
        text.size.height = min(rect.height,ceil(font.ascender-font.descender+font.leading))
        text.origin.y = rect.midY-text.height/2
        return text
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect {searchTextRect(forBounds:rect)}
    override func titleRect(forBounds rect: NSRect) -> NSRect {searchTextRect(forBounds:rect)}
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // NSCell single-line paint fixes its baseline by controlSize, ignoring
        // enlarged font metrics. Use native font-based paint within our measured
        // line track, then restore the native single-line editing/input policy.
        let singleLine = usesSingleLineMode
        usesSingleLineMode = false
        defer {usesSingleLineMode = singleLine}
        super.drawInterior(withFrame:cellFrame,in:controlView)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame:searchTextRect(forBounds:controlView.bounds),in:controlView,editor:editor,delegate:delegate,start:start,length:length)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame:searchTextRect(forBounds:controlView.bounds),in:controlView,editor:editor,delegate:delegate,event:event)
    }
}

final class SoundQSearchField: NSSearchField {
    override class var cellClass: AnyClass? {get {SoundQSearchFieldCell.self} set {}}
    // Single-line paint/input policy does not enable horizontal editor scrolling.
    // Let AppKit expand and scroll its field editor instead of clipping long text.
    override init(frame: NSRect) {super.init(frame:frame);cell?.isScrollable = true;focusRingType = .none;cell?.focusRingType = .none}
    required init?(coder: NSCoder) {super.init(coder:coder);cell?.isScrollable = true;focusRingType = .none;cell?.focusRingType = .none}
    private var editorLayoutSize = NSSize.zero
    private var editorLayoutFont: NSFont?
    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        layoutNativeEditor(retypeset:true)
    }
    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        layoutNativeEditor(retypeset:true)
    }
    override func layout() {
        super.layout()
        layoutNativeEditor()
    }
    private func layoutNativeEditor(retypeset: Bool = false) {
        guard let editor = currentEditor() as? NSTextView,
              let cell = cell as? SoundQSearchFieldCell,
              let clip = editor.superview as? NSClipView,
              retypeset || editorLayoutSize != bounds.size || editorLayoutFont != font else {return}
        editorLayoutSize = bounds.size;editorLayoutFont = font
        // Input has already passed through the native single-line policy. Its
        // field-editor typesetter otherwise fixes baseline/line height by the
        // control size, even when every attributed font run is enlarged.
        // Reflow only native glyph layout with font metrics, then restore input
        // policy without replacing text, attributes, selection or composition.
        if let manager = editor.layoutManager, let container = editor.textContainer {
            let singleLine = cell.usesSingleLineMode
            cell.usesSingleLineMode = false
            manager.invalidateLayout(forCharacterRange:NSRange(location:0,length:(editor.string as NSString).length),actualCharacterRange:nil)
            manager.ensureLayout(for:container)
            cell.usesSingleLineMode = singleLine
        }
        let track = cell.searchTextRect(forBounds:bounds)
        // Retain AppKit's native document/clip and horizontal recovery. Its
        // autoresizing keeps the previous vertical origin when typography grows.
        // Recenter the actual line (including fallback/marked glyph metrics),
        // preserving selection, composition, delegate and native clip padding.
        let usedHeight = editor.textContainer.flatMap {editor.layoutManager?.usedRect(for:$0).height} ?? 0
        let height = max(track.height,usedHeight)
        let padding = max(0,clip.frame.height-editor.frame.height)
        editor.minSize.height = height
        editor.setFrameSize(NSSize(width:editor.frame.width,height:height))
        editor.setFrameOrigin(NSPoint(x:editor.frame.minX,y:bounds.midY-height/2))
        clip.setFrameSize(NSSize(width:clip.frame.width,height:height+padding))
        let projected = editor.convert(editor.bounds,to:self)
        clip.setFrameOrigin(NSPoint(x:clip.frame.minX,y:clip.frame.minY+bounds.midY-projected.midY))
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let tokens = SoundQTokens.resolve(effectiveAppearance)
        let focus = currentEditor() != nil
        (focus ? tokens.accent : tokens.inputOutline).setStroke()
        let rule = NSBezierPath(rect:bounds.insetBy(dx:focus ? 1 : 0.5,dy:focus ? 1 : 0.5));rule.lineWidth = focus ? 2 : 1;rule.stroke()
    }
}

final class LibraryTrackCell: NSTableCellView {
    let name = NSTextField(labelWithString:"")
    let artist = NSTextField(labelWithString:"")
    let duration = NSTextField(labelWithString:"")
    let note = NSImageView()
    private(set) var configurations = 0
    var scale: CGFloat = 1
    var current = false {didSet {name.textColor = current ? SoundQTokens.resolve(effectiveAppearance).primary : SoundQTokens.resolve(effectiveAppearance).text;needsDisplay = true}}
    override init(frame: NSRect) {
        super.init(frame:frame)
        for field in [name,artist,duration] {field.lineBreakMode = .byWordWrapping;field.maximumNumberOfLines = 1;field.cell?.truncatesLastVisibleLine = true;addSubview(field)}
        note.image = NSImage(systemSymbolName:"music.note",accessibilityDescription:"No artwork available");addSubview(note)
    }
    required init?(coder: NSCoder) {fatalError("init(coder:) unsupported")}
    func configure(track: Track, current: Bool, scale: CGFloat, transport: String = "paused") {
        configurations += 1;setCurrent(current,transport:transport)
        name.stringValue = track.title;artist.stringValue = track.artist ?? "Unknown artist"
        duration.stringValue = track.duration_ms.map {LibraryDockView.timestamp($0)} ?? "—"
        applyTypography(scale:scale)
        name.setAccessibilityLabel("Track title");artist.setAccessibilityLabel("Artist");duration.setAccessibilityLabel("Duration")
        toolTip = track.title;needsLayout = true
    }
    func setCurrent(_ value: Bool, transport: String) {current = value;setAccessibilityHelp(value ? "Current track, \(transport). Browse selection is independent." : "Library track. Select to browse, Play selected to start playback.")}
    func applyTypography(scale: CGFloat) {
        self.scale = scale
        let tokens = SoundQTokens.resolve(effectiveAppearance)
        name.font = NativeAssets.font(16,weight:500,scale:scale);artist.font = NativeAssets.font(12,scale:scale);duration.font = NativeAssets.font(11,mono:true,scale:scale)
        name.textColor = current ? tokens.primary : tokens.text;artist.textColor = tokens.neutral;duration.textColor = tokens.neutral;note.contentTintColor = tokens.neutral
        needsLayout = true
    }
    override func viewDidChangeEffectiveAppearance() {super.viewDidChangeEffectiveAppearance();applyTypography(scale:scale)}
    override func layout() {
        super.layout()
        let side = 40*scale, inset: CGFloat = 8
        note.frame = NSRect(x:inset,y:(bounds.height-side)/2,width:side,height:side)
        let durationWidth = SoundQTokens.grid(max(48,duration.intrinsicContentSize.width,duration.cell?.cellSize.width ?? 0))
        duration.frame = NSRect(x:max(inset,bounds.width-durationWidth-inset),y:(bounds.height-16*scale)/2,width:durationWidth,height:16*scale)
        let x = inset+side+8, width = max(1,duration.frame.minX-x-8)
        name.frame = NSRect(x:x,y:bounds.height/2,width:width,height:24*scale)
        artist.frame = NSRect(x:x,y:bounds.height/2-20*scale,width:width,height:20*scale)
    }
    override func draw(_ dirtyRect: NSRect) {
        let tokens = SoundQTokens.resolve(effectiveAppearance)
        if current {tokens.primary.setFill();NSRect(x:0,y:0,width:3,height:bounds.height).fill()}
        tokens.outline.setFill();NSRect(x:0,y:0,width:bounds.width,height:1).fill()
    }
}

final class LibraryTrackRow: NSTableRowView {
    private var hover = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas();for area in trackingAreas {removeTrackingArea(area)}
        addTrackingArea(NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil))
    }
    override func mouseEntered(with event: NSEvent) {hover = true;needsDisplay = true}
    override func mouseExited(with event: NSEvent) {hover = false;needsDisplay = true}
    override var isEmphasized: Bool {get {true} set {}}
    override func drawBackground(in dirtyRect: NSRect) {
        let tokens = SoundQTokens.resolve(effectiveAppearance)
        (hover || isSelected ? tokens.activeRow : tokens.surface).setFill();bounds.fill()
        if hover || isSelected {tokens.accent.setStroke();NSBezierPath(rect:bounds.insetBy(dx:0.5,dy:0.5)).stroke()}
    }
    override func drawSelection(in dirtyRect: NSRect) {
        drawBackground(in:dirtyRect)
        if window?.firstResponder is NSTableView {
            SoundQTokens.resolve(effectiveAppearance).text.setStroke();let focus = NSBezierPath(rect:bounds.insetBy(dx:3,dy:3));focus.lineWidth = 2;focus.stroke()
        }
    }
}
