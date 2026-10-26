import AppKit

// Native menu owns only a revocable desired-state command capability. Rust/API
// owns favorite truth. No optimistic projection or independent playback owner.
@MainActor final class LibraryFavoriteMenu: NSMenu, NSMenuDelegate, NSMenuItemValidation {
    private weak var owner: App?
    private var issued: NSMenuItem?
    private var admission: (account:UInt64,epoch:UInt64,session:UInt64,track:Int64,liked:Bool)?
    init(owner: App) {
        self.owner = owner
        super.init(title:"Favorites")
        delegate = self;autoenablesItems = true
    }
    required init(coder: NSCoder) {fatalError("init(coder:) unsupported")}
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self else {return}
        admission = nil;issued = nil;removeAllItems()
        if let owner, let snapshot = owner.snapshot,
           let favorites = snapshot.favorite_track_ids,
           snapshot.authenticated, snapshot.epoch == owner.epoch,
           owner.busy == 0, owner.table.selectedRow >= 0,
           owner.table.selectedRow < snapshot.library.count {
            let track = snapshot.library[owner.table.selectedRow].id
            admission = (owner.accountScope,owner.epoch,snapshot.session,track,
                         favorites.contains(track))
        }
        let item = NSMenuItem(title:admission?.liked == true ? "Unlike selected track" : "Like selected track",
                              action:#selector(performFavorite(_:)),keyEquivalent:"")
        item.target = self;issued = item;addItem(item)
        item.isEnabled = validateMenuItem(item)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item === issued, let admission, let owner, let snapshot = owner.snapshot,
              let favorites = snapshot.favorite_track_ids,
              owner.busy == 0, owner.accountScope == admission.account,
              owner.epoch == admission.epoch, snapshot.epoch == admission.epoch,
              snapshot.session == admission.session, snapshot.authenticated,
              owner.table.selectedRow >= 0, owner.table.selectedRow < snapshot.library.count,
              snapshot.library[owner.table.selectedRow].id == admission.track,
              favorites.contains(admission.track) == admission.liked else {return false}
        return true
    }
    @objc func performFavorite(_ sender: NSMenuItem) {
        guard validateMenuItem(sender), let admission, let owner else {return}
        // Consume before dispatch. Held/replayed menu targets cannot issue twice.
        self.admission = nil;sender.isEnabled = false
        owner.command(["command":"set_favorite","track_id":admission.track,"liked":!admission.liked])
    }
}
