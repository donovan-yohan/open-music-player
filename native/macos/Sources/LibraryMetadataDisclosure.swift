import AppKit

// An issued, revocable read capability. A removed/reappearing ID or metadata
// restored to its former bytes must not resurrect a retained target/action.
@MainActor final class LibraryMetadataAction: NSObject {
    weak var owner: App?
    let account: UInt64
    let epoch: UInt64
    let session: UInt64
    let track: Track
    var active = true
    var consumed = false
    init(owner: App, account: UInt64, snapshot: Snapshot, track: Track) {
        self.owner = owner;self.account = account;epoch = snapshot.epoch
        session = snapshot.session;self.track = track
    }
    func matches(_ value: Snapshot, account: UInt64, epoch: UInt64) -> Bool {
        guard active, self.account == account, self.epoch == epoch,
              value.authenticated, value.epoch == epoch, value.session == session,
              let current = value.library.first(where:{$0.id == track.id}) else {return false}
        return current.title.utf8.elementsEqual(track.title.utf8) &&
            current.duration_ms == track.duration_ms &&
            (current.artist == nil) == (track.artist == nil) &&
            (current.artist ?? "").utf8.elementsEqual((track.artist ?? "").utf8)
    }
    @objc func open() {owner?.openLibraryDetails(self)}
}

// Native document construction is independently exercisable without a window.
@MainActor enum LibraryMetadataDisclosure {
    static func area(track: Track, available: NSSize, font: NSFont) -> NSScrollView {
        let area = NSTextView.scrollableTextView()
        area.frame = NSRect(x:0,y:0,width:min(560,available.width*0.6),height:min(320,available.height*0.45))
        area.hasVerticalScroller = true;area.hasHorizontalScroller = false;area.autohidesScrollers = true
        let text = area.documentView as! NSTextView
        text.isEditable = false;text.isSelectable = true;text.isRichText = false;text.font = font
        text.isHorizontallyResizable = false;text.isVerticallyResizable = true;text.autoresizingMask = [.width]
        text.minSize = NSSize(width:0,height:area.contentSize.height)
        text.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        text.textContainer?.size = NSSize(width:area.contentSize.width,height:CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true;text.textContainer?.lineBreakMode = .byCharWrapping
        text.string = "Title\n"+track.title+"\n\nArtist\n"+(track.artist ?? "")
        text.setAccessibilityLabel("Full Library title and artist");area.setAccessibilityLabel("Full details scroll area")
        return area
    }
}
