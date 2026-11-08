import SwiftUI
import ImageIO

/// Repository artwork uses the same HTTPS redirect rules and bounded transfer
/// as packages, then downsamples before decoding to keep large images cheap.
struct RepositoryIcon: View {
    let url: URL?
    var symbolSize: CGFloat = 14
    @State private var image: UIImage?
    @Environment(\.forgeTheme) private var T

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: symbolSize, weight: .medium))
                    .foregroundStyle(T.accent2)
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            let loaded = await RepositoryIconLoader.shared.image(for: url)
            guard !Task.isCancelled else { return }
            image = loaded
        }
        .accessibilityHidden(true)
    }
}

@MainActor
private final class RepositoryIconLoader {
    static let shared = RepositoryIconLoader()
    private let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 8 * 1_024 * 1_024
        cache.countLimit = 128
        return cache
    }()

    func image(for url: URL) async -> UIImage? {
        guard NetworkPolicy.validateHTTPS(url) else { return nil }
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-icon-\(UUID().uuidString).partial")
        let transfer = BoundedTransfer(destination: temporary, maximumBytes: 2 * 1_024 * 1_024)
        do {
            let file = try await transfer.download(from: url)
            defer { try? FileManager.default.removeItem(at: file) }
            let thumbnail = await Task.detached(priority: .utility) { () -> UIImage? in
                let sourceOptions = [kCGImageSourceShouldCache as String: false] as CFDictionary
                guard let source = CGImageSourceCreateWithURL(file as CFURL, sourceOptions),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 256,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { return nil }
                return UIImage(cgImage: image)
            }.value
            guard !Task.isCancelled, let thumbnail else { return nil }
            cache.setObject(thumbnail, forKey: url as NSURL,
                            cost: Int(thumbnail.size.width * thumbnail.size.height * 4))
            return thumbnail
        } catch {
            return nil
        }
    }
}
