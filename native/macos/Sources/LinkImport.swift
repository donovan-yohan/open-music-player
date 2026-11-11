import AppKit

// Paint/line allocation only. NSTextFieldCell retains the native field editor,
// selection, composition, scrolling, validation and keyboard dispatch.
final class LinkImportURLCell: NSTextFieldCell {
    override func drawingRect(forBounds rect:NSRect)->NSRect {
        let font=font ?? NSFont.systemFont(ofSize:14)
        let height=min(rect.height,ceil(font.ascender-font.descender+font.leading))
        return NSRect(x:rect.minX+10,y:rect.midY-height/2,width:max(1,rect.width-20),height:height)
    }
    override func titleRect(forBounds rect:NSRect)->NSRect {drawingRect(forBounds:rect)}
    override func drawInterior(withFrame rect:NSRect,in view:NSView) {
        let single=usesSingleLineMode;usesSingleLineMode=false
        defer {usesSingleLineMode=single}
        super.drawInterior(withFrame:rect,in:view)
    }
    override func select(withFrame rect:NSRect,in view:NSView,editor:NSText,delegate:Any?,start:Int,length:Int) {
        super.select(withFrame:drawingRect(forBounds:rect),in:view,editor:editor,delegate:delegate,start:start,length:length)
    }
    override func edit(withFrame rect:NSRect,in view:NSView,editor:NSText,delegate:Any?,event:NSEvent?) {
        super.edit(withFrame:drawingRect(forBounds:rect),in:view,editor:editor,delegate:delegate,event:event)
    }
}
final class LinkImportURLField: NSTextField {
    override class var cellClass:AnyClass? {get {LinkImportURLCell.self} set {}}
    override init(frame:NSRect) {super.init(frame:frame);configure()}
    required init?(coder:NSCoder) {super.init(coder:coder);configure()}
    private func configure() {isBezeled=false;isBordered=false;drawsBackground=false;focusRingType = .none;cell?.focusRingType = .none;cell?.isScrollable=true;usesSingleLineMode=true}
    override func textDidBeginEditing(_ notification:Notification) {super.textDidBeginEditing(notification);needsDisplay=true}
    override func textDidEndEditing(_ notification:Notification) {super.textDidEndEditing(notification);needsDisplay=true}
    override var isEnabled:Bool {didSet {needsDisplay=true}}
    override func draw(_ dirtyRect:NSRect) {
        let t=SoundQTokens.resolve(effectiveAppearance),focus=isEnabled && (currentEditor() != nil || cell?.showsFirstResponder == true)
        t.surface.setFill();bounds.fill();super.draw(dirtyRect)
        drawBoundary(focused:focus)
    }
    func drawBoundary(focused focus:Bool) {
        let t=SoundQTokens.resolve(effectiveAppearance)
        let edge=isEnabled ? (focus ? t.accent:t.inputOutline):t.surface.blended(withFraction:0.55,of:t.neutral)!
        edge.setStroke();let path=NSBezierPath(rect:bounds.insetBy(dx:focus ? 1:0.5,dy:focus ? 1:0.5));path.lineWidth=focus ? 2:1;path.stroke()
    }
}

// NSPopUpButtonCell still owns menu tracking, selection, target/action and AX.
// Its product cell paints the full allocated height, not the stock shallow bezel.
final class LinkImportJobsCell: NSPopUpButtonCell {
    override func draw(withFrame rect:NSRect,in view:NSView) {
        let t=SoundQTokens.resolve(view.effectiveAppearance),enabled=isEnabled
        let active=enabled && (isHighlighted || showsFirstResponder || (view as? LinkImportJobsButton)?.hovered == true)
        let surface=active ? t.accent:t.surface,ink=enabled ? (active ? t.background:t.text):t.surface.blended(withFraction:0.55,of:t.neutral)!
        surface.setFill();rect.fill()
        (enabled ? t.accent:ink).setStroke();NSBezierPath(rect:rect.insetBy(dx:0.5,dy:0.5)).stroke()
        let font=font ?? NativeAssets.font(14),height=ceil(font.ascender-font.descender+font.leading)
        let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
        let text=NSRect(x:rect.minX+10,y:rect.midY-height/2,width:max(1,rect.width-42),height:height)
        (title as NSString).draw(in:text,withAttributes:[.font:font,.foregroundColor:ink,.paragraphStyle:paragraph])
        let x=rect.maxX-18,y=rect.midY
        ink.setStroke();let arrow=NSBezierPath();arrow.move(to:NSPoint(x:x-4,y:y-2));arrow.line(to:NSPoint(x:x,y:y+2));arrow.line(to:NSPoint(x:x+4,y:y-2));arrow.lineWidth=1.5;arrow.stroke()
        if enabled && showsFirstResponder {ink.setStroke();let focus=NSBezierPath(rect:rect.insetBy(dx:3,dy:3));focus.lineWidth=2;focus.stroke()}
    }
}
final class LinkImportJobsButton: NSPopUpButton {
    override class var cellClass:AnyClass? {get {LinkImportJobsCell.self} set {}}
    private(set) var hovered=false
    override init(frame:NSRect,pullsDown:Bool) {super.init(frame:frame,pullsDown:pullsDown);focusRingType = .none;cell?.focusRingType = .none}
    required init?(coder:NSCoder) {super.init(coder:coder)}
    override var isEnabled:Bool {didSet {needsDisplay=true}}
    override func updateTrackingAreas() {
        super.updateTrackingAreas();for area in trackingAreas {removeTrackingArea(area)}
        addTrackingArea(NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil))
    }
    override func mouseEntered(with event:NSEvent) {hovered=true;needsDisplay=true}
    override func mouseExited(with event:NSEvent) {hovered=false;needsDisplay=true}
}

// App owns this across sheet closure; the renderer never submits work itself.
struct LinkImportState {
    var draft = ""
    var serial: UInt64 = 0
    var operation: UInt64 = 0
    // Another link retires presentation of old receipts, never core no-replay evidence.
    var retiredOperation: UInt64 = 0
    var pending: UInt64?
    var reading: UInt64?
    var outcome = "draft"
    var jobID: String?
    var job: Reply.ImportJob?
    var jobs: [Reply.ImportJob] = []
    var feedback = "Import one YouTube video or SoundCloud track."
    var completed = Set<String>()
    var deferredLibrary: String?
    var openLibrary = false
    var focusTrack: Int64?
}

final class LinkImportView: NSView, NSTextFieldDelegate {
    let heading = NSTextField(labelWithString:"Add link")
    let url = LinkImportURLField()
    let feedback = NSTextField(wrappingLabelWithString:"")
    let historyLabel = NSTextField(labelWithString:"Recent imports")
    let submit = SoundQButton(title:"Import",target:nil,action:nil)
    let check = SoundQButton(title:"Check status",target:nil,action:nil)
    let recent = SoundQButton(title:"Recent jobs",target:nil,action:nil)
    let open = SoundQButton(title:"Open in Library",target:nil,action:nil)
    let close = SoundQButton(title:"Close",target:nil,action:nil)
    let another = SoundQButton(title:"Another link",target:nil,action:nil)
    let jobs = LinkImportJobsButton(frame:.zero,pullsDown:false)
    var onEdit: ((String)->Void)?
    var scale: CGFloat = 1
    override var isFlipped: Bool {true}
    init(target:AnyObject,scale:CGFloat) {
        self.scale = scale
        super.init(frame:NSRect(x:0,y:0,width:640,height:480*scale))
        url.placeholderString = "https://…";url.setAccessibilityLabel("YouTube or SoundCloud track URL");url.delegate = self
        url.isEditable = true;url.isSelectable = true;url.lineBreakMode = .byClipping
        for (button,action) in [(submit,#selector(App.submitLink)),(check,#selector(App.checkLinkImport)),(recent,#selector(App.recentLinkImports)),(open,#selector(App.openImportLibrary)),(another,#selector(App.newLinkImport)),(close,#selector(App.closeLinkImport))] {button.target = target;button.action = action;button.font = NativeAssets.font(14,scale:scale);button.textScale = scale}
        jobs.target = target;jobs.action = #selector(App.chooseLinkImport(_:));jobs.setAccessibilityLabel("Recent imports")
        jobs.menu?.minimumWidth=560;jobs.menu?.font=NativeAssets.font(14,scale:scale)
        submit.keyEquivalent = "\r";close.keyEquivalent = "\u{1b}"
        heading.font = NativeAssets.font(22,weight:600,scale:scale)
        url.font = NativeAssets.font(14,scale:scale);feedback.font = NativeAssets.font(14,scale:scale);jobs.font = NativeAssets.font(14,scale:scale);historyLabel.font=NativeAssets.font(14,weight:500,scale:scale)
        feedback.maximumNumberOfLines = 0;feedback.isSelectable = true
        for view in [heading,url,feedback,historyLabel,submit,check,recent,open,another,close,jobs] {addSubview(view)}
        url.nextKeyView = submit;submit.nextKeyView = check;check.nextKeyView = recent;recent.nextKeyView = jobs;jobs.nextKeyView = open;open.nextKeyView = another;another.nextKeyView = close;close.nextKeyView = url
    }
    required init?(coder:NSCoder){fatalError("init(coder:) unsupported")}
    func controlTextDidChange(_ notification:Notification){onEdit?(url.stringValue)}
    func update(_ state:LinkImportState,canOpen:Bool) {
        if !url.stringValue.utf8.elementsEqual(state.draft.utf8) {url.stringValue = state.draft}
        submit.isEnabled = state.pending == nil && state.reading == nil && !["accepted","uncertain"].contains(state.outcome)
        url.isEnabled = state.pending == nil
        check.isEnabled = state.pending == nil && state.reading == nil
        recent.isEnabled = check.isEnabled;open.isEnabled = canOpen
        another.isEnabled = check.isEnabled
        jobs.removeAllItems()
        for job in state.jobs {
            let provider=job.source_type == "youtube" ? "YouTube":job.source_type == "soundcloud" ? "SoundCloud":job.source_type
            // Full truthful metadata lives in native menu titles/tooltips/AX.
            // The closed cell may truncate; UUIDs remain secondary to source/time.
            let title="\(provider) · \(job.url) · \(job.created_at) · \(job.status) · \(job.job_id)"
            jobs.addItem(withTitle:title);jobs.lastItem?.toolTip=title
        }
        jobs.isEnabled = check.isEnabled && !state.jobs.isEmpty
        if let id=state.jobID, let i=state.jobs.firstIndex(where:{$0.job_id==id}) {jobs.selectItem(at:i)}
        jobs.toolTip=jobs.selectedItem?.toolTip;jobs.setAccessibilityHelp(jobs.toolTip ?? "Choose a recent import to check its status.")
        feedback.stringValue = state.feedback;needsLayout = true
    }
    override func layout() {
        super.layout();let s=scale,w=bounds.width-48
        heading.frame = NSRect(x:24,y:24,width:w,height:36*s)
        let cell=SoundQTokens.grid(max(40,40*s))
        url.frame = NSRect(x:24,y:heading.frame.maxY+16,width:w,height:cell)
        var x:CGFloat=24,y=url.frame.maxY+16
        for b in [submit,check,recent,open,another,close] {
            let width=SoundQTokens.grid(max(b.intrinsicContentSize.width,b.cell?.cellSize.width ?? 0))
            if x+width>bounds.width-24 && x>24 {x=24;y+=cell+8}
            b.frame=NSRect(x:x,y:y,width:min(w,width),height:cell);x+=width+8
        }
        let feedbackHeight=ceil(feedback.cell!.cellSize(forBounds:NSRect(x:0,y:0,width:w,height:10000)).height)
        feedback.frame=NSRect(x:24,y:y+cell+16,width:w,height:feedbackHeight)
        let labelHeight=ceil(historyLabel.font!.ascender-historyLabel.font!.descender+historyLabel.font!.leading)
        historyLabel.frame=NSRect(x:24,y:feedback.frame.maxY+16,width:w,height:labelHeight)
        jobs.frame=NSRect(x:24,y:historyLabel.frame.maxY+8,width:w,height:cell)
        let needed=jobs.frame.maxY+24
        if frame.height < needed {frame.size.height=needed}
        let t=SoundQTokens.resolve(effectiveAppearance);heading.textColor=t.text;feedback.textColor=t.neutral;historyLabel.textColor=t.neutral;url.textColor=t.text
    }
}
