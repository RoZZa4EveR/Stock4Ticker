import SwiftUI
import AppKit

// MARK: - LogoLoader
//
// Sdílená in-memory cache + async stahování log. TradingView loga jsou SVG
// (…--big.svg); SwiftUI `AsyncImage`/`Image(url:)` SVG nevykreslí, `NSImage(data:)`
// ho na macOS 13+ zvládne. Sdílený loader používá popover (`LogoView`) i menu bar
// (`AppDelegate`), takže se logo stáhne jen jednou.

@MainActor
final class LogoLoader {

    static let shared = LogoLoader()

    private let cache = NSCache<NSURL, NSImage>()
    private var inFlight: Set<URL> = []

    private init() { cache.countLimit = 200 }

    /// Vrátí logo z cache, nebo `nil`. Při miss spustí jedno async stažení a po
    /// dokončení zavolá `onLoad` (na main actoru), aby si volající mohl překreslit.
    @discardableResult
    func image(for url: URL, onLoad: (() -> Void)? = nil) -> NSImage? {
        if let img = cache.object(forKey: url as NSURL) { return img }
        guard !inFlight.contains(url) else { return nil }
        inFlight.insert(url)
        Task { [weak self] in
            let img = await LogoLoader.download(url)
            guard let self else { return }
            self.inFlight.remove(url)
            if let img {
                self.cache.setObject(img, forKey: url as NSURL)
                onLoad?()
            }
        }
        return nil
    }

    /// Async varianta pro SwiftUI `.task`.
    func image(for url: URL) async -> NSImage? {
        if let img = cache.object(forKey: url as NSURL) { return img }
        let img = await LogoLoader.download(url)
        if let img { cache.setObject(img, forKey: url as NSURL) }
        return img
    }

    private static func download(_ url: URL) async -> NSImage? {
        guard
            let (data, _) = try? await URLSession.shared.data(from: url),
            let img = NSImage(data: data)
        else { return nil }
        return img
    }
}

// MARK: - LogoView
//
// Fallback když `url == nil` nebo načtení selže: kolečko s monogramem (první
// písmeno symbolu) — pro symboly bez loga.

struct LogoView: View {

    let url: URL?
    let fallbackText: String
    var size: CGFloat = 24

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(Circle())
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await LogoLoader.shared.image(for: url)
        }
    }

    private var fallback: some View {
        Circle()
            .fill(Color.secondary.opacity(0.18))
            .overlay(
                Text(monogram)
                    .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            )
    }

    private var monogram: String {
        String(fallbackText.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }
}
