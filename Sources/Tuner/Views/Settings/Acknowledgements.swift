import SwiftUI

/// Third-party software shown in Settings → About, with its licence. The iPhone/iPad and Mac App Store apps link
/// libmpv and FFmpeg (MPVKit's LGPL build) and the libraries they use into the app; the GitHub Mac app loads the
/// user's own libmpv and ffmpeg at runtime.
struct Acknowledgement: Identifiable {
    let name: String
    let role: String
    let license: String
    let url: URL
    var id: String { name }

    init(_ name: String, _ role: String, _ license: String, _ url: String) {
        self.name = name
        self.role = role
        self.license = license
        self.url = URL(string: url)!
    }

    static let sourceURL = URL(string: "https://github.com/AhmedEzzat12/iptv-player-macos")!

    #if os(macOS) && !TUNER_APP_STORE
    static let all: [Acknowledgement] = [
        .init("mpv / libmpv", "Video playback (installed separately)", "LGPL 2.1+ / GPL", "https://mpv.io"),
        .init("FFmpeg", "Recording (installed separately)", "LGPL 2.1+ / GPL", "https://ffmpeg.org"),
        .init("GRDB.swift", "SQLite toolkit", "MIT", "https://github.com/groue/GRDB.swift"),
        .init("Sparkle", "Automatic updates", "MIT", "https://sparkle-project.org"),
        .init("ynotv", "The IPTV player that inspired Tuner", "Website", "https://github.com/tbeezy/ynotv"),
    ]
    static let footer = "Tuner's own code is source-available under the PolyForm Noncommercial License 1.0.0."
    #else
    static var all: [Acknowledgement] {
        #if os(macOS)
        bundled + [.init("LuaJIT", "Scripting (unused)", "MIT", "https://luajit.org")]
        #else
        bundled
        #endif
    }

    private static let bundled: [Acknowledgement] = [
        .init("mpv", "Video playback", "LGPL 2.1+", "https://github.com/mpv-player/mpv"),
        .init("FFmpeg", "Decoding and streaming", "LGPL 2.1+", "https://ffmpeg.org/legal.html"),
        .init("MPVKit", "mpv and FFmpeg for Apple platforms", "LGPL 2.1+", "https://github.com/mpvkit/MPVKit"),
        .init("libplacebo", "Video rendering", "LGPL 2.1+", "https://code.videolan.org/videolan/libplacebo"),
        .init("libass", "Subtitles", "ISC", "https://github.com/libass/libass"),
        .init("FreeType", "Fonts", "FreeType License", "https://freetype.org/license.html"),
        .init("HarfBuzz", "Text shaping", "MIT", "https://github.com/harfbuzz/harfbuzz"),
        .init("FriBidi", "Right-to-left text", "LGPL 2.1+", "https://github.com/fribidi/fribidi"),
        .init("libunibreak", "Line breaking", "zlib", "https://github.com/adah1972/libunibreak"),
        .init("dav1d", "AV1 decoding", "BSD 2-Clause", "https://code.videolan.org/videolan/dav1d"),
        .init("uavs3d", "AVS3 decoding", "BSD 3-Clause", "https://github.com/uavs3/uavs3d"),
        .init("libdovi", "Dolby Vision metadata", "MIT", "https://github.com/quietvoid/dovi_tool"),
        .init("Little CMS", "Colour management", "MIT", "https://www.littlecms.com"),
        .init("libbluray", "Disc formats", "LGPL 2.1+", "https://code.videolan.org/videolan/libbluray"),
        .init("uchardet", "Subtitle encoding detection", "MPL 1.1 / LGPL 2.1+", "https://www.freedesktop.org/wiki/Software/uchardet/"),
        .init("shaderc", "Shader compiler", "Apache 2.0", "https://github.com/google/shaderc"),
        .init("OpenSSL", "TLS", "Apache 2.0", "https://www.openssl.org/source/license.html"),
        .init("GnuTLS", "TLS", "LGPL 2.1+", "https://gnutls.org"),
        .init("Nettle", "Cryptography", "LGPL 3+", "https://www.lysator.liu.se/~nisse/nettle/"),
        .init("GMP", "Arithmetic", "LGPL 3+", "https://gmplib.org"),
        .init("GRDB.swift", "SQLite toolkit", "MIT", "https://github.com/groue/GRDB.swift"),
        .init("ynotv", "The IPTV player that inspired Tuner", "Website", "https://github.com/tbeezy/ynotv"),
    ]
    static let footer = "The LGPL libraries are used unmodified and linked into the app. Tuner's own code is source-available under the PolyForm Noncommercial License 1.0.0, so you can rebuild the app with your own versions of them from the source code."
    #endif

    /// The LGPL 2.1 text bundled with the iPhone/iPad app.
    static var lgplText: String? {
        Bundle.main.url(forResource: "LGPL-2.1", withExtension: "txt", subdirectory: "Licenses")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}

struct LicenseTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .padding()
            }
            .navigationTitle("GNU LGPL 2.1")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}
