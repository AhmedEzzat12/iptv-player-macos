import SwiftUI

/// Remote artwork (posters, backdrops, logos). Uses `AsyncImage`, which shares `URLCache.shared`;
/// `ImageCacheSetup.configure()` enlarges that cache at launch so artwork survives relaunches.
struct RemoteImage<Placeholder: View>: View {
    let url: String?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    init(url: String?, contentMode: ContentMode = .fill, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = placeholder
    }

    var body: some View {
        if let url, let parsed = URL(string: url), parsed.scheme != nil {
            AsyncImage(url: parsed, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: contentMode)
                default:
                    placeholder()
                }
            }
        } else {
            placeholder()
        }
    }
}

enum ImageCacheSetup {
    static func configure() {
        URLCache.shared = URLCache(memoryCapacity: 128 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024)
    }
}
