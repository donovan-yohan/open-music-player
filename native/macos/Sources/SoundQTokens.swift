import AppKit

// Source mapping: frozen client/lib/app/theme.dart:181–211 and
// desktop_theme.dart:65–113. Light is a shared-token adaptation; the mounted
// Flutter desktop Library is forced dark. No independently invented palette.
struct SoundQTokens {
    let dark: Bool
    static let darkHex: [UInt32] = [0x050505,0x0B0A08,0x14110D,0x211A13,0xF4EDDC,0xA89F90,0x32281F,0x6E6254,0xFF5A00,0xD84400,0x39C6B6,0x57D68D,0xFFC857,0xFF6B5F]
    static let lightHex: [UInt32] = [0xFAFAF8,0xFFFFFF,0xFFFFFF,0xECECEA,0x171411,0x5E554C,0xC8C2BC,0x76706A,0xC74400,0x9F3300,0x007F73,0x1B6E3C,0x8A5B00,0xB3261E]
    static func resolve(_ appearance: NSAppearance) -> Self {Self(dark:appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua)}
    func color(_ index: Int) -> NSColor {
        let hex = (dark ? Self.darkHex : Self.lightHex)[index]
        return NSColor(srgbRed:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:1)
    }
    var background: NSColor {color(0)}
    var surface: NSColor {color(2)}
    var raised: NSColor {color(3)}
    var text: NSColor {color(4)}
    var neutral: NSColor {color(5)}
    var outline: NSColor {color(6)}
    var inputOutline: NSColor {color(7)}
    var activeRow: NSColor {dark ? outline : surface.blended(withFraction:0.12,of:outline)!}
    var primary: NSColor {color(8)}
    var accent: NSColor {color(10)}
    var error: NSColor {color(13)}
    var onPrimary: NSColor {dark ? background : .white}
    var disabled: NSColor {neutral.withAlphaComponent(0.55)}
    struct Paint {let surface: NSColor;let foreground: NSColor;let border: NSColor}
    func paint(enabled: Bool, primary: Bool, selected: Bool, hover: Bool, focus: Bool, pressed: Bool) -> Paint {
        if !enabled {return Paint(surface:surface,foreground:disabled,border:disabled)}
        let active = hover || focus
        let fill: NSColor = pressed ? (selected ? self.primary.blended(withFraction:0.55,of:text)! : text) : active ? (selected ? self.primary.blended(withFraction:0.30,of:text)! : accent) : primary || selected ? self.primary : surface
        let foreground = pressed ? surface : active ? background : primary || selected ? onPrimary : accent
        return Paint(surface:fill,foreground:foreground,border:pressed || active ? accent : primary || selected ? self.primary : accent)
    }
    static let identityDuration: CFTimeInterval = 0.180
    static let playDuration: CFTimeInterval = 0.140
    static let identityOffset: CGFloat = 0.035
    static func grid(_ value: CGFloat, unit: CGFloat = 4) -> CGFloat {(value/unit).rounded(.up)*unit}
}
