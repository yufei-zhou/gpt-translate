import AppKit

/// Keeps the source and both translations scrolled to the same place in the text. Translations keep the source's
/// paragraphs, so positions are matched paragraph by paragraph (proportionally within a paragraph); when the
/// paragraph counts differ, the whole text is treated as one. The source pane is twice as tall, so it moves less:
/// a source that fits stays put, and scrolling it moves the translations further.
@MainActor
final class ScrollSync {
    private var views: [NSTextView] = []
    private var syncing = false
    private var cache: [ObjectIdentifier: (key: [CGFloat], bounds: [CGFloat])] = [:]

    func add(_ textView: NSTextView) {
        guard let clip = textView.enclosingScrollView?.contentView else { return }
        views.append(textView)
        clip.postsBoundsChangedNotifications = true
        // Delivered synchronously: a queued delivery would arrive after `syncing` is reset, and the following pane
        // would then pull the leading one back.
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) {
            [weak self, weak textView] _ in
            MainActor.assumeIsolated {
                guard let self, let textView else { return }
                self.scrolled(textView)
            }
        }
    }

    /// Debug: scrolls `source` to `fraction` of its range through the normal notification path, as if the user
    /// were scrolling it; returns both offsets.
    func debugScroll(_ source: NSTextView, to fraction: CGFloat) -> String {
        guard let from = Self.geometry(source), let scrollView = source.enclosingScrollView else { return "no geometry" }
        debugLeader = source
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: (from.maxOffset * fraction).rounded()))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        debugLeader = nil
        return debugOffsets()
    }

    func debugOffsets() -> String {
        views.map { view in
            let g = Self.geometry(view)!
            let paragraph = boundaries(view, docHeight: g.docHeight).lastIndex { $0 <= g.offset + 1 } ?? 0
            return String(format: "pane %d offset %.1f / %.0f  paragraph at top %d",
                          (view as? PaneTextView)?.pane ?? -1, g.offset, g.maxOffset, paragraph)
        }.joined(separator: " | ")
    }

    private var debugLeader: NSTextView?

    private func scrolled(_ source: NSTextView) {
        guard !syncing, isLeading(source) else { return }
        syncing = true
        defer { syncing = false }
        for target in views where target !== source { follow(source, with: target) }
    }

    /// The pane the user is scrolling: the one under the pointer (wheel, trackpad and its momentum, scroller drags),
    /// or the focused one for keyboard scrolling. Only it leads, so the panes never take turns pulling each other.
    private func isLeading(_ textView: NSTextView) -> Bool {
        if let debugLeader { return debugLeader === textView }
        guard let scrollView = textView.enclosingScrollView, let window = scrollView.window else { return false }
        if NSApp.currentEvent?.type == .keyDown { return window.firstResponder === textView }
        let point = scrollView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return scrollView.bounds.contains(point)
    }

    /// The anchor is a line that slides from the top of the view (scrolled to the start) to its bottom
    /// (scrolled to the end), so both panes reach their start and end together.
    private func follow(_ source: NSTextView, with target: NSTextView) {
        guard let from = Self.geometry(source), let to = Self.geometry(target),
              from.maxOffset > 0, to.maxOffset > 0 else { return }
        // Past either end the leading pane is rubber-banding: the other one stretches by the same amount.
        let inRange = min(max(from.offset, 0), from.maxOffset)
        let overscroll = from.offset - inRange
        let anchor = inRange * from.docHeight / from.maxOffset
        let fromBounds = boundaries(source, docHeight: from.docHeight)
        var toBounds = boundaries(target, docHeight: to.docHeight)
        var sourceBounds = fromBounds
        if fromBounds.count != toBounds.count {
            sourceBounds = [0, from.docHeight]
            toBounds = [0, to.docHeight]
        }
        let i = max(0, min((sourceBounds.lastIndex { $0 <= anchor } ?? 0), sourceBounds.count - 2))
        let span = sourceBounds[i + 1] - sourceBounds[i]
        let fraction = span > 0 ? min(max((anchor - sourceBounds[i]) / span, 0), 1) : 0
        let mapped = toBounds[i] + fraction * (toBounds[i + 1] - toBounds[i])
        let scale = target.window?.backingScaleFactor ?? 2
        let offset = ((mapped * to.maxOffset / to.docHeight + overscroll) * scale).rounded() / scale
        guard let scrollView = target.enclosingScrollView, offset != to.offset else { return }
        // scroll(to:) isn't clamped to the content, so the bounce carries over.
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private static func geometry(_ textView: NSTextView) -> (offset: CGFloat, maxOffset: CGFloat, docHeight: CGFloat)? {
        guard let clip = textView.enclosingScrollView?.contentView else { return nil }
        let docHeight = textView.frame.height
        return (clip.bounds.minY, docHeight - clip.bounds.height, docHeight)
    }

    /// Paragraph positions only change with the text or the pane's size, so they are computed once per layout
    /// rather than on every scrolled frame.
    private func boundaries(_ textView: NSTextView, docHeight: CGFloat) -> [CGFloat] {
        let key = [CGFloat((textView.string as NSString).length), textView.frame.width, docHeight]
        if let cached = cache[ObjectIdentifier(textView)], cached.key == key { return cached.bounds }
        let bounds = Self.boundaries(textView, docHeight: docHeight)
        cache[ObjectIdentifier(textView)] = (key, bounds)
        return bounds
    }

    /// Where each paragraph after the first starts, between 0 and the document's end.
    private static func boundaries(_ textView: NSTextView, docHeight: CGFloat) -> [CGFloat] {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return [0, docHeight] }
        layout.ensureLayout(for: container)
        let text = textView.string as NSString
        var starts: [CGFloat] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) { paragraph, range, _, _ in
            guard let paragraph, !paragraph.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            starts.append(layout.boundingRect(forGlyphRange: glyphs, in: container).minY + textView.textContainerOrigin.y)
        }
        return [0] + starts.dropFirst() + [docHeight]
    }
}
