import Foundation

/// How files are laid out inside a local library location: <root>/YYYY/YYYY-MM-DD/<original file name>.
/// Unknown capture dates go under "undated/". Name collisions with *different* content get a short hash suffix.
public enum FileLayout {
    public static let mediaExtensions: Set<String> = [
        "jpg","jpeg","png","heic","heif","tif","tiff","dng","psd","gif","webp","bmp","avif",
        "raw","cr2","cr3","nef","nrw","arw","srf","sr2","orf","rw2","raf","pef","dcr","kdc","erf","mrw","3fr","fff","iiq","mos","x3f","srw","rwl",
        "mov","mp4","m4v","avi","mts","m2ts","mkv","3gp","mpg","mpeg","wmv"
    ]

    public static func isMedia(_ url: URL) -> Bool {
        mediaExtensions.contains(url.pathExtension.lowercased())
    }

    public static func kind(forExtension ext: String, contentType: String?) -> ContentKind {
        if let ct = contentType?.lowercased() {
            if ct.hasPrefix("video/") { return .video }
            if ct.hasPrefix("image/") { return .image }
        }
        switch ext.lowercased() {
        case "mov","mp4","m4v","avi","mts","m2ts","mkv","3gp","mpg","mpeg","wmv": return .video
        default: return mediaExtensions.contains(ext.lowercased()) ? .image : .other
        }
    }

    public static func relativePath(day: String?, fileName: String) -> String {
        let safeName = fileName.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        if let day, day.count == 10 {
            return "\(day.prefix(4))/\(day)/\(safeName)"
        }
        return "undated/\(safeName)"
    }

    /// Adds "-<first 8 of sha>" before the extension to avoid clobbering a different file with the same name.
    public static func disambiguated(_ relativePath: String, sha256: String) -> String {
        let ns = relativePath as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        let suffix = "-" + String(sha256.prefix(8))
        return ext.isEmpty ? base + suffix : base + suffix + "." + ext
    }

    /// Falls back to the file's own metadata (EXIF date, then mtime) when Lightroom has no record of it.
    public static func captureDay(for url: URL) -> String? {
        if let exif = exifDate(url) { return exif }
        if let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey]),
           let d = vals.creationDate ?? vals.contentModificationDate {
            return dayFormatter.string(from: d)
        }
        return nil
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    static func exifDate(_ url: URL) -> String? {
        #if canImport(ImageIO)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let s = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String) ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String) ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        guard let s, s.count >= 10 else { return nil }
        // EXIF: "yyyy:MM:dd HH:mm:ss"
        let d = String(s.prefix(10)).replacingOccurrences(of: ":", with: "-")
        return d.hasPrefix("0000") ? nil : d
        #else
        return nil
        #endif
    }
}

#if canImport(ImageIO)
import ImageIO
#endif
