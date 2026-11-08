import AppKit
import UniformTypeIdentifiers

/// What a pasteboard (the clipboard, or a drag) offers to translate: text, or an image whose text the model reads.
enum PasteboardContent {
    case text(String)
    case image(NSImage)

    /// Text wins, except a lone URL next to an image: browsers add the image's address when copying an image.
    static func read(_ pasteboard: NSPasteboard) -> PasteboardContent? {
        let text = (pasteboard.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let image = image(from: pasteboard)
        if let image, text.isEmpty || isLoneURL(text) { return .image(image) }
        return text.isEmpty ? nil : .text(text)
    }

    /// An image on the pasteboard, or an image file. A copied file of another kind doesn't count, although Finder
    /// puts its icon on the pasteboard too.
    static func image(from pasteboard: NSPasteboard) -> NSImage? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first {
            guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return nil }
            return NSImage(contentsOf: url)
        }
        let types: [NSPasteboard.PasteboardType] = [.png, .tiff, .init(UTType.jpeg.identifier), .init(UTType.heic.identifier)]
        guard pasteboard.availableType(from: types) != nil else { return nil }
        return NSImage(pasteboard: pasteboard)
    }

    private static func isLoneURL(_ text: String) -> Bool {
        !text.contains(where: \.isWhitespace) && URL(string: text)?.scheme.map { ["http", "https", "file", "data"].contains($0) } == true
    }
}

/// The image as sent to OpenAI.
enum ImagePayload {
    /// Enough for small print in a full-screen Retina screenshot. With detail "auto" OpenAI keeps the image's own size
    /// (and rejects images over 30,000 patches of 32 px), so capping it here keeps the upload, the token count and the
    /// latency down.
    static let maxLongEdge = 2576

    static func encode(_ image: NSImage) -> (data: Data, mediaType: String)? {
        // The largest bitmap, so a Retina screenshot keeps its full resolution.
        let bitmap = image.representations.compactMap { $0 as? NSBitmapImageRep }.max { $0.pixelsWide < $1.pixelsWide }
        guard var cg = bitmap?.cgImage ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let longEdge = max(cg.width, cg.height)
        if longEdge > maxLongEdge {
            let scale = CGFloat(maxLongEdge) / CGFloat(longEdge)
            let width = Int(CGFloat(cg.width) * scale), height = Int(CGFloat(cg.height) * scale)
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            cg = scaled
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        // PNG keeps text crisp; photos that come out large go as JPEG instead.
        if let png = rep.representation(using: .png, properties: [:]), png.count <= 3_500_000 { return (png, "image/png") }
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return (jpeg, "image/jpeg")
    }
}
