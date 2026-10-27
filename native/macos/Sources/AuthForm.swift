import AppKit

// Ephemeral presentation/admission only, never credentials or password drafts.
struct AuthFormState {
    enum Mode {case signIn, register}
    struct Ticket: Equatable {let serial: UInt64;let presentation: UInt64;let epoch: UInt64;let account: UInt64}
    private(set) var mode: Mode = .signIn
    private(set) var presentation: UInt64 = 1
    private var serial: UInt64 = 0
    private(set) var pending: Ticket?
    private(set) var errors = [String:String]()
    private(set) var failure: String?
    private(set) var succeeded = false
    private(set) var publicationRetired = false
    mutating func changeMode(_ value: Mode) -> Bool {
        guard pending == nil else {return false}
        retire();mode = value;return true
    }
    // A detached presentation cannot cancel remote account creation or reopen admission.
    mutating func retire() {if pending != nil {publicationRetired = true};presentation &+= 1;errors = [:];failure = nil;succeeded = false}
    func owns(_ ticket: Ticket) -> Bool {pending == ticket && presentation == ticket.presentation}
    mutating func begin(username: String, email: String, password: String, confirmation: String, epoch: UInt64, account: UInt64) -> Ticket? {
        guard pending == nil else {return nil}
        errors = mode == .register ? Self.validate(username:username,email:email,password:password,confirmation:confirmation) : [:]
        if mode == .signIn {
            if email.isEmpty {errors["email"] = "Please enter your email"}
            if password.isEmpty {errors["password"] = "Please enter a password"}
        }
        failure = nil;succeeded = false
        guard errors.isEmpty else {return nil}
        serial &+= 1
        let ticket = Ticket(serial:serial,presentation:presentation,epoch:epoch,account:account)
        pending = ticket;publicationRetired = false;return ticket
    }
    @discardableResult mutating func finish(_ ticket: Ticket, ok: Bool, code: String, epoch: UInt64, account: UInt64) -> Bool {
        guard pending == ticket else {return false}
        let current = owns(ticket) && ticket.epoch == epoch && ticket.account == account
        pending = nil
        guard current else {return false}
        succeeded = ok;failure = ok ? nil : Self.feedback(code,mode:mode)
        return true
    }
    static func trimmed(_ value: String) -> String {value.trimmingCharacters(in:CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn:"\u{feff}")))}
    static func validate(username: String, email: String, password: String, confirmation: String) -> [String:String] {
        // Match Flutter's raw UTF-16/ASCII regex checks, then Go/Rust UTF-8 bounds.
        // Password confirmation uses exact bytes, not Swift canonical equivalence.
        var errors = [String:String]()
        let trimmed = Self.trimmed(username)
        if username.isEmpty {errors["username"] = "Please enter a username"}
        else if !(3...50).contains(username.utf16.count) || !(3...50).contains(trimmed.utf8.count) {errors["username"] = "Username must be 3–50 characters and bytes"}
        let pattern = #"^[A-Za-z0-9_\-.]+@([A-Za-z0-9_\-]+\.)+[A-Za-z0-9_\-]{2,4}$"#
        let regex = try! NSRegularExpression(pattern:pattern)
        let wireRegex = try! NSRegularExpression(pattern:#"^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$"#)
        let range = NSRange(location:0,length:email.utf16.count)
        if email.isEmpty {errors["email"] = "Please enter your email"}
        else if regex.firstMatch(in:email,range:range)?.range != range || wireRegex.firstMatch(in:email,range:range)?.range != range || Self.trimmed(email).utf8.count > 254 {errors["email"] = "Please enter a valid email"}
        if password.isEmpty {errors["password"] = "Please enter a password"}
        else if password.utf16.count < 8 || !(8...1024).contains(password.utf8.count) {errors["password"] = "Password must be at least 8 characters (up to 1024 bytes)"}
        if confirmation.isEmpty {errors["confirmation"] = "Please confirm your password"}
        else if !password.utf8.elementsEqual(confirmation.utf8) {errors["confirmation"] = "Passwords do not match"}
        return errors
    }
    static func feedback(_ code: String, mode: Mode) -> String {
        if code == "command_backpressure" {return "SoundQ is busy. Try again."}
        if ["authentication_failed","authentication_refused","invalid_credentials","rate_limited"].contains(code) {
            return mode == .register ? "Account creation was refused. Check your details or sign in." : "Sign in was refused. Check your email and password."
        }
        return mode == .register ? "Account creation is unconfirmed. Sign in to check before trying again." : "Sign in could not be confirmed. Try again."
    }
}

// Real native secure editors, labels and actions; outer bodyScroll owns overflow.
@MainActor final class AuthFormView: NSStackView, NSTextFieldDelegate {
    let username = NSTextField()
    let confirmation = NSSecureTextField()
    let submit = SoundQButton(title:"Sign in",target:nil,action:nil)
    let modeButton = SoundQButton(title:"Create account",target:nil,action:nil)
    let feedback = NSTextField(wrappingLabelWithString:"")
    private var fields = [(String,NSTextField)]()
    private var errorLabels = [String:NSTextField]()
    private var registration = false
    private var scale: CGFloat = 1
    var onEdit: (() -> Void)?
    override var isFlipped: Bool {true}
    func configure(endpoint: NSTextField, email: NSTextField, password: NSSecureTextField, target: AnyObject, submitAction: Selector, modeAction: Selector) {
        fields = [("endpoint",endpoint),("username",username),("email",email),("password",password),("confirmation",confirmation)]
        for (key,field) in fields {
            field.placeholderString = key == "confirmation" ? "Confirm password" : key.capitalized
            field.setAccessibilityLabel(field.placeholderString!)
            field.delegate = self;field.target = target;field.action = submitAction
            field.isBezeled = true;field.isEditable = key != "endpoint"
            addSubview(field)
            let error = NSTextField(wrappingLabelWithString:"");error.setAccessibilityLabel("\(key) error")
            errorLabels[key] = error;addSubview(error)
        }
        submit.target = target;submit.action = submitAction;submit.keyEquivalent = "\r";submit.primary = true
        modeButton.target = target;modeButton.action = modeAction
        addSubview(feedback);addSubview(submit);addSubview(modeButton)
        update(AuthFormState())
    }
    func clearSecrets() {fields.first {$0.0 == "password"}?.1.stringValue = "";confirmation.stringValue = ""}
    func controlTextDidChange(_ notification: Notification) {onEdit?()}
    func update(_ state: AuthFormState) {
        registration = state.mode == .register
        for (key,field) in fields {
            field.isHidden = !registration && ["username","confirmation"].contains(key)
            field.isEnabled = state.pending == nil
            errorLabels[key]?.stringValue = state.errors[key] ?? ""
        }
        submit.title = state.pending != nil ? (registration ? "Creating account…":"Signing in…") : (registration ? "Create account":"Sign in")
        modeButton.title = registration ? "Back to sign in":"Create account"
        submit.isEnabled = state.pending == nil;modeButton.isEnabled = state.pending == nil
        feedback.stringValue = state.failure ?? (state.pending == nil ? "" : "Please wait…")
        needsLayout = true;superview?.needsLayout = true
    }
    func applyAuthTypography(_ value: CGFloat) {
        scale = value
        let tokens = SoundQTokens.resolve(effectiveAppearance)
        for (_,field) in fields {field.font = NativeAssets.font(14,scale:scale);field.textColor = tokens.text;field.backgroundColor = tokens.surface}
        for label in Array(errorLabels.values)+[feedback] {label.font = NativeAssets.font(13,scale:scale);label.textColor = tokens.text}
        for button in [submit,modeButton] {button.font = NativeAssets.font(14,weight:500,scale:scale);button.textScale = scale}
    }
    private func labelHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        guard !label.stringValue.isEmpty else {return 0}
        return ceil((label.stringValue as NSString).boundingRect(with:NSSize(width:max(1,width),height:10000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:label.font!]).height)+8
    }
    func requiredHeight(width: CGFloat, scale: CGFloat) -> CGFloat {
        applyAuthTypography(scale)
        return fields.filter {!$0.1.isHidden}.reduce(CGFloat(0)) {$0 + max(40*scale,$1.1.cell!.cellSize.height+12) + labelHeight(errorLabels[$1.0]!,width:width)+8} + labelHeight(feedback,width:width) + 2*max(40*scale,submit.cell!.cellSize.height+12)+24
    }
    override func layout() {
        // NSStackView does not own this auth-only measured layout.
        let w = bounds.width
        var y: CGFloat = 0
        for (key,field) in fields where !field.isHidden {
            let h = max(40*scale,field.cell!.cellSize.height+12)
            field.frame = NSRect(x:0,y:y,width:w,height:h);y += h
            let error = errorLabels[key]!,eh = labelHeight(error,width:w)
            error.frame = NSRect(x:0,y:y,width:w,height:eh);y += eh+8
        }
        let fh = labelHeight(feedback,width:w);feedback.frame = NSRect(x:0,y:y,width:w,height:fh);y += fh+8
        for button in [submit,modeButton] {let h = max(40*scale,button.cell!.cellSize.height+12);button.frame = NSRect(x:0,y:y,width:w,height:h);y += h+8}
    }
}
