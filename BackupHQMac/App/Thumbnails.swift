import AppKit
import QuickLookThumbnailing

/// Small in-memory thumbnail cache backed by QuickLook (handles RAW/DNG/HEIC/video).
actor Thumbnails {
    static let shared = Thumbnails()
    private var cache: [String: NSImage] = [:]
    private var order: [String] = []

    func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        let key = "\(url.path)@\(Int(size))"
        if let img = cache[key] { return img }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: 2, representationTypes: .thumbnail)
        let image: NSImage? = await withCheckedContinuation { cont in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                cont.resume(returning: rep?.nsImage)
            }
        }
        if let image {
            cache[key] = image; order.append(key)
            if order.count > 600 { let old = order.removeFirst(); cache[old] = nil }
        }
        return image
    }
}
