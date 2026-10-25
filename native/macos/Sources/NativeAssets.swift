import AppKit
import CoreText
import CryptoKit

// All URLs are local. Registration lasts for this process, never the user's font
// collection. Missing required faces are errors; script fallback is CoreText's
// normal cascade, not a substitute for omitted SoundQ resources.
struct NativeAssets {
    static let bundleName = "SoundQNative_SoundQNative.bundle"
    static let faces = ["SpaceGrotesk-Regular","SpaceGrotesk-Medium","SpaceGrotesk-SemiBold","SpaceGrotesk-Bold","IBMPlexMono-Regular","IBMPlexMono-Medium"]
    let root: URL
    let logo: NSImage
    struct Manifest: Decodable {let schema: Int;let files: [Entry]}
    static let requiredPaths: Set<String> = [
        "brand/soundq-brand-assets.json", "brand/soundq-logo.png",
        "fonts/sources.json", "fonts/ibmplexmono/OFL.txt", "fonts/spacegrotesk/OFL.txt",
        "fonts/ibmplexmono/IBMPlexMono-Regular.ttf", "fonts/ibmplexmono/IBMPlexMono-Medium.ttf",
        "fonts/spacegrotesk/SpaceGrotesk-Regular.ttf", "fonts/spacegrotesk/SpaceGrotesk-Medium.ttf",
        "fonts/spacegrotesk/SpaceGrotesk-SemiBold.ttf", "fonts/spacegrotesk/SpaceGrotesk-Bold.ttf"
    ]
    struct Entry: Decodable {let path: String;let sha256: String;let bytes: Int}
    enum Failure: Error {case missingResources, invalidResource(String), font(String)}
    static func resourceRoot(in bundle: Bundle) throws -> URL {
        // An explicit app boundary must never consult Bundle.module's absolute
        // development fallback, including when the packaged tree was removed.
        if bundle.bundleURL.pathExtension == "app" {
            let root = bundle.bundleURL.appendingPathComponent("Contents/Resources/\(bundleName)/Resources")
            guard FileManager.default.fileExists(atPath:root.appendingPathComponent("asset-manifest.json").path) else {throw Failure.missingResources}
            return root
        }
        #if SWIFT_PACKAGE
        return Bundle.module.bundleURL.appendingPathComponent("Resources")
        #else
        throw Failure.missingResources
        #endif
    }
    static func load(in bundle: Bundle = .main) throws -> Self {try load(root:resourceRoot(in:bundle))}
    static func load(root: URL) throws -> Self {
        let manifest = try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:root.appendingPathComponent("asset-manifest.json")))
        // Validate the complete distinct canonical inventory before reading any
        // entry or registering fonts. Exact membership also rejects path aliases.
        guard manifest.schema == 1, manifest.files.count == requiredPaths.count,
              Set(manifest.files.map(\.path)) == requiredPaths else {throw Failure.missingResources}
        for entry in manifest.files {
            guard !entry.path.hasPrefix("/"), !entry.path.split(separator:"/").contains("..") else {throw Failure.invalidResource(entry.path)}
            let data = try Data(contentsOf:root.appendingPathComponent(entry.path))
            guard data.count == entry.bytes, SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined() == entry.sha256 else {throw Failure.invalidResource(entry.path)}
        }
        for face in faces {
            let family = face.hasPrefix("Space") ? "spacegrotesk" : "ibmplexmono"
            let url = root.appendingPathComponent("fonts/\(family)/\(face).ttf")
            var error: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(url as CFURL,.process,&error)
            if !registered, (error?.takeRetainedValue()).map({CFErrorGetCode($0)}) != CTFontManagerError.alreadyRegistered.rawValue {throw Failure.font(face)}
            guard NSFont(name:face,size:16) != nil else {throw Failure.font(face)}
        }
        guard let logo = NSImage(contentsOf:root.appendingPathComponent("brand/soundq-logo.png")) else {throw Failure.invalidResource("logo")}
        return Self(root:root,logo:logo)
    }
    static func font(_ size: CGFloat, weight: Int = 400, mono: Bool = false, scale: CGFloat = 1) -> NSFont {
        let name = mono ? (weight >= 500 ? faces[5] : faces[4]) : faces[weight >= 700 ? 3 : weight >= 600 ? 2 : weight >= 500 ? 1 : 0]
        guard let font = NSFont(name:name,size:size*scale) else {preconditionFailure("Required SoundQ font unavailable: \(name)")}
        return font
    }
}
