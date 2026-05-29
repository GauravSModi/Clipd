import AppKit
import ClipdKit
import ImageIO

/// Downsample image bytes to a thumbnail bounded by `maxPixel` on the longer
/// edge. Uses ImageIO so the full image is never decoded into RAM — important
/// when several MB-scale image rows are visible in the search panel.
func clipdThumbnail(from data: Data, maxPixel: Int) -> NSImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
        return nil
    }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                            options as CFDictionary) else {
        return nil
    }
    return NSImage(cgImage: cgImage, size: .zero)
}

/// Detect an image format from the leading magic bytes, so paste-back can write
/// the original encoding back to the pasteboard without storing the format in
/// the search result.
func clipdImageFormat(of data: Data) -> ClipImageFormat {
    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if data.count >= 8,
       data[0] == 0x89, data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47 {
        return .png
    }
    return .tiff
}
