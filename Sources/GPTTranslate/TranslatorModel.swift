import AppKit
import SwiftUI

/// Text view used for all three panes: reports hover position, draws a placeholder.
final class PaneTextView: NSTextView {
    var pane = 0
    var placeholder: String?
    var onHover: ((Int, Int?) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHover?(pane, characterIndex(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(pane, nil)
    }

    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, !string.isEmpty else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: p, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.contains(p) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let placeholder else { return }
        let padding = textContainer?.lineFragmentPadding ?? 0
        (placeholder as NSString).draw(
            at: NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y),
            withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 15), .foregroundColor: Theme.tertiaryText])
    }
}

@MainActor
final class TranslatorModel: NSObject, ObservableObject, NSTextViewDelegate {
    @Published var sourceLang: String?
    @Published var targetLangs = ["", ""]
    @Published var hasTarget = [false, false]
    @Published var streaming = [false, false]
    /// Panes whose translation stopped at the output ceiling.
    @Published var truncated = [false, false]
    /// Shown instead of translating when the text is long enough to cost noticeably more than usual.
    @Published var confirmation: String?
    /// Heights the two translation panes need; the right column is split in this ratio so neither is cut off.
    @Published var paneHeights: [CGFloat] = [1, 1]
    @Published var isTranslating = false
    @Published var errorMessage: String?
    @Published var errorNeedsSettings = false
    @Published var pinned = false
    @Published var stale = false

    private(set) var sourceText = ""
    private var targetTexts = ["", ""]
    private var views: [Int: PaneTextView] = [:]
    private let scrollSync = ScrollSync()
    private var alignRanges: [[NSRange?]] = []
    private var selection: (pane: Int, range: NSRange)?
    private var hover: (pane: Int, index: Int)?
    private var generation = 0
    private var task: Task<Void, Never>?
    private var alignTask: Task<Void, Never>?
    private var entry: HistoryEntry?
    private var applyingProgrammatically = false
    /// Debug timing trace, on only while debug/trace-on exists; kept in memory and written once per translation,
    /// so tests can follow streaming without poking the app.
    private var trace: [String]?
    private var traceStart = Date()
    /// Called whenever pane text changes, with whether the panel may shrink (not while a translation streams in).
    var onContentChange: ((Bool) -> Void)?
    /// Text the user has been asked to confirm; translating it again goes ahead.
    private var pendingConfirmation: String?
    /// Translations estimated at or above this many dollars ask first (a typical one costs well under a cent).
    private static let confirmAbove = 0.05

    // MARK: Panes

    func register(_ textView: PaneTextView, pane: Int) {
        views[pane] = textView
        textView.pane = pane
        textView.onHover = { [weak self] pane, index in self?.hoverChanged(pane: pane, index: index) }
        scrollSync.add(textView)
        applyText(pane)
    }

    func focusSource() {
        guard let tv = views[0] else { return }
        tv.window?.makeFirstResponder(tv)
    }

    func debugSourceSelection() -> String {
        guard let tv = views[0] else { return "no pane" }
        let range = tv.selectedRange()
        return "length \((tv.string as NSString).length) selected \(range.location)+\(range.length) firstResponder \(tv.window?.firstResponder === tv) translating \(isTranslating) targets \(hasTarget)"
    }

    func restyle() {
        for pane in views.keys { applyText(pane, force: true) }
        updateHighlights()
    }

    private func applyText(_ pane: Int, force: Bool = false) {
        guard let tv = views[pane], let storage = tv.textStorage else { return }
        let text = pane == 0 ? sourceText : targetTexts[pane - 1]
        let color = (pane > 0 && stale) ? Theme.tertiaryText : Theme.text
        let attributes = Theme.textAttributes(color: color)
        applyingProgrammatically = true
        defer { applyingProgrammatically = false }
        tv.typingAttributes = Theme.textAttributes()
        tv.font = attributes[.font] as? NSFont
        if force || tv.string != text {
            if !force, pane > 0, !tv.string.isEmpty, text.hasPrefix(tv.string) {
                // Streaming: append only the new tail so the view doesn't flicker or jump.
                let tail = String(text.dropFirst(tv.string.count))
                storage.append(NSAttributedString(string: tail, attributes: attributes))
            } else {
                let selected = tv.selectedRange()
                storage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
                let length = (text as NSString).length
                if pane == 0 && !force {
                    tv.setSelectedRange(NSRange(location: length, length: 0))
                } else if NSMaxRange(selected) <= length {
                    tv.setSelectedRange(selected)
                }
            }
            if pane > 0 { updatePaneHeights() }
            onContentChange?(!isTranslating)
        }
    }

    private func updatePaneHeights() {
        let heights = [paneHeight(1), paneHeight(2)]
        if zip(heights, paneHeights).contains(where: { abs($0 - $1) >= 1 }) { paneHeights = heights }
    }

    /// Height one translation pane needs: 40 pt header, its text, 8 pt below.
    private func paneHeight(_ pane: Int) -> CGFloat { 40 + textHeight(pane) + 8 }

    private func textHeight(_ pane: Int) -> CGFloat {
        guard let tv = views[pane], let layout = tv.layoutManager, let container = tv.textContainer else { return 0 }
        layout.ensureLayout(for: container)
        let oneLine = layout.defaultLineHeight(for: tv.font ?? Theme.contentFont()) * 1.22
        return max(layout.usedRect(for: container).height, oneLine) + tv.textContainerInset.height * 2
    }

    /// Height the panel needs to show every pane's text without scrolling (layout from Panel.swift: 40 pt pane
    /// headers, the source pane's 46 pt send-button row, 8 pt under each translation, a 1 pt divider).
    func contentHeight() -> CGFloat {
        updatePaneHeights()
        let source = 40 + textHeight(0) + 46
        // The two panes split the column evenly (see PanelView), so each needs half of it.
        let translations = 2 * max(paneHeight(1), paneHeight(2)) + 1
        return ceil(max(source, translations)) + 8
    }

    // MARK: Loading

    func load(text: String) {
        cancelWork()
        pendingConfirmation = nil
        confirmation = nil
        sourceText = text
        targetTexts = ["", ""]
        sourceLang = nil
        targetLangs = ["", ""]
        hasTarget = [false, false]
        errorMessage = nil
        stale = false
        entry = nil
        clearAlignment()
        for pane in 0...2 { applyText(pane) }
    }

    func load(entry: HistoryEntry) {
        cancelWork()
        pendingConfirmation = nil
        confirmation = nil
        self.entry = entry
        sourceText = entry.source
        sourceLang = entry.sourceLang
        let targets = entry.targets + Array(repeating: TargetText(lang: "", text: ""), count: max(0, 2 - entry.targets.count))
        targetLangs = targets.prefix(2).map(\.lang)
        targetTexts = targets.prefix(2).map(\.text)
        hasTarget = targetTexts.map { !$0.isEmpty }
        errorMessage = nil
        stale = false
        clearAlignment()
        if let pairs = entry.pairs {
            alignRanges = Aligner.resolve(pairs, in: [sourceText] + targetTexts)
        }
        for pane in 0...2 { applyText(pane) }
    }

    private func cancelWork() {
        truncated = [false, false]
        generation += 1
        task?.cancel()
        alignTask?.cancel()
        isTranslating = false
        streaming = [false, false]
    }

    // MARK: Translation

    func translate() {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        errorMessage = nil
        errorNeedsSettings = false
        guard !SecretGuard.containsSecret(text) else {
            show(error: "原文里有密钥，未发送。", needsSettings: false)
            return
        }
        // Translated before with this model (on screen now, or in history): show that instead of paying again.
        let model = AppSettings.shared.model
        let key = Translator.historyKey(text)
        HistoryStore.shared.loadIfNeeded()
        if var cached = HistoryStore.shared.entries.first(where: {
            $0.targets.count == 2 && $0.model.hasPrefix(model) && Translator.historyKey($0.source) == key
        }) {
            cached.date = Date()
            HistoryStore.shared.upsert(cached)
            load(entry: cached)
            return
        }
        if let blocked = UsageTracker.shared.blockedMessage {
            show(error: blocked, needsSettings: true)
            return
        }
        let cost = Translator.estimatedCost(text, model: model)
        if cost >= Self.confirmAbove, pendingConfirmation != text {
            pendingConfirmation = text
            confirmation = String(format: "原文约 %@ 字，预计花费约 $%.2f。", text.count.formatted(.number.locale(Locale(identifier: "en_US"))), cost)
            return
        }
        pendingConfirmation = nil
        confirmation = nil
        guard let key = Keychain.apiKey, !key.isEmpty else {
            show(error: "还没有设置 OpenAI API Key。", needsSettings: true)
            return
        }

        cancelWork()
        let gen = generation
        stale = false
        clearAlignment()
        sourceLang = nil
        targetLangs = ["", ""]
        targetTexts = ["", ""]
        hasTarget = [false, false]
        for pane in 1...2 { applyText(pane) }
        isTranslating = true
        streaming = [true, true]
        truncated = [false, false]
        let tracing = FileManager.default.fileExists(atPath: AppPaths.support.appendingPathComponent("debug/trace-on").path)
        trace = tracing ? ["mode=\(Translator.prefersParallel(text) ? "parallel" : "single") chars=\(text.count)"] : nil
        traceStart = Date()

        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard Translator.prefersParallel(text) else {
                    let result = try await self.translateBoth(text: text, key: key, model: model, gen: gen)
                    guard gen == self.generation else { return }
                    return self.finish(results: [result], source: text, gen: gen, key: key)
                }
                // Long text: each pane gets its own request, so both translations stream at the same time.
                async let first = self.translatePart(0, text: text, forced: nil, key: key, model: model, gen: gen)
                async let second = self.translatePart(1, text: text, forced: nil, key: key, model: model, gen: gen)
                var results = try await [first, second]
                guard gen == self.generation else { return }

                // The two requests route independently; if either picked a language the rules don't give for
                // this source (rare, e.g. ambiguous mixed text), redo that pane with the routing pinned.
                if let source = self.sourceLang {
                    let expected = Translator.targets(forSource: source)
                    for part in 0..<2 where Translator.baseLanguage(self.targetLangs[part]) != expected[part] {
                        self.targetTexts[part] = ""
                        self.applyText(part + 1)
                        self.streaming[part] = true
                        results[part] = try await self.translatePart(part, text: text, forced: (source, expected[part]),
                                                                     key: key, model: model, gen: gen)
                        guard gen == self.generation else { return }
                    }
                }
                self.finish(results: results, source: text, gen: gen, key: key)
            } catch {
                guard gen == self.generation, !Task.isCancelled else { return }
                if (error as? URLError)?.code == .cancelled { return }
                self.isTranslating = false
                self.streaming = [false, false]
                let described = APIClient.describe(error)
                self.show(error: described.message, needsSettings: described.needsSettings)
                self.writeTrace("error")
            }
        }
    }

    func cancel() {
        guard isTranslating else { return }
        cancelWork()
    }

    /// Streams both target languages, one after the other, from a single request.
    private func translateBoth(text: String, key: String, model: String, gen: Int) async throws -> StreamResult {
        let (body, betas) = Models.requestBody(model: model, system: Translator.systemPrompt,
                                               user: Translator.userMessage(text),
                                               maxTokens: Translator.maxTokens(for: text, targets: 2))
        let result = try await stream(body: body, betas: betas, key: key, model: model, gen: gen, parts: [0, 1])
        if gen == generation {
            applyStream(result.text, parts: [0, 1])
            if result.stopReason == "max_tokens" { truncated[hasTarget[1] ? 1 : 0] = true }
        }
        return result
    }

    /// Streams one target language into its pane.
    private func translatePart(_ part: Int, text: String, forced: (source: String, target: String)?,
                               key: String, model: String, gen: Int) async throws -> StreamResult {
        let (body, betas) = Models.requestBody(model: model, system: Translator.instructions(part: part, forced: forced),
                                               user: Translator.userMessage(text, part: part, forced: forced),
                                               maxTokens: Translator.maxTokens(for: text, targets: 1))
        let result = try await stream(body: body, betas: betas, key: key, model: model, gen: gen, parts: [part])
        if gen == generation {
            applyStream(result.text, parts: [part])
            streaming[part] = false
            if result.stopReason == "max_tokens" { truncated[part] = true }
        }
        return result
    }

    /// Runs one request, showing its text in `parts` at most every 40 ms (long replies arrive as hundreds of tiny
    /// deltas), and records its usage — also what a cancelled or failed request had already consumed.
    private func stream(body: [String: Any], betas: [String], key: String, model: String, gen: Int,
                        parts: [Int]) async throws -> StreamResult {
        let progress = StreamProgress()
        let throttle = Throttle()
        do {
            let result = try await APIClient.stream(key: key, body: body, betas: betas, progress: progress) { [weak self] raw in
                throttle.submit(raw) { latest in
                    guard let self, gen == self.generation else { return }
                    self.applyStream(latest, parts: parts)
                }
            }
            throttle.stop()
            UsageTracker.shared.record(model: result.model.isEmpty ? model : result.model, usage: result.usage)
            return result
        } catch {
            throttle.stop()
            if progress.usage.input + progress.usage.cacheRead + progress.usage.cacheWrite > 0 {
                var usage = progress.usage
                usage.output = max(usage.output, Translator.estimatedTokens(progress.text))
                UsageTracker.shared.record(model: progress.model.isEmpty ? model : progress.model, usage: usage)
            }
            throw error
        }
    }

    /// Shows the reply's targets, in order, in the given panes (both panes, or the one a parallel request owns).
    private func applyStream(_ raw: String, parts: [Int]) {
        let output = Translator.parse(raw)
        if sourceLang == nil, let source = output.source { sourceLang = source }
        var targets = output.targets
        // A parallel request owns one pane. If the model wrote both targets anyway, show the one this pane is for,
        // not whichever came first.
        if parts.count == 1, targets.count > 1, let source = output.source ?? sourceLang {
            let wanted = Translator.targets(forSource: source)[parts[0]]
            targets = [targets.first { Translator.baseLanguage($0.lang) == wanted } ?? targets[min(parts[0], targets.count - 1)]]
        }
        for (target, part) in zip(targets, parts) {
            if targetLangs[part] != target.lang { targetLangs[part] = target.lang }
            targetTexts[part] = target.text
            if hasTarget[part] != !target.text.isEmpty { hasTarget[part] = !target.text.isEmpty }
            applyText(part + 1)
            if target.closed, streaming[part] { streaming[part] = false }
            trace?.append(String(format: "%.2fs pane%d %d split %.0f", Date().timeIntervalSince(traceStart), part + 1, target.text.count,
                                 views[1]?.enclosingScrollView?.frame.height ?? 0))
        }
    }

    private func writeTrace(_ outcome: String) {
        guard var lines = trace else { return }
        trace = nil
        lines.append(String(format: "%@ %.2fs split %.0f", outcome, Date().timeIntervalSince(traceStart),
                            views[1]?.enclosingScrollView?.frame.height ?? 0))
        lines.append(debugState())
        try? lines.joined(separator: "\n").write(to: AppPaths.support.appendingPathComponent("debug/trace.txt"),
                                                atomically: true, encoding: .utf8)
    }

    private func finish(results: [StreamResult], source: String, gen: Int, key: String) {
        isTranslating = false
        streaming = [false, false]
        onContentChange?(true)
        defer { writeTrace("done") }
        if results.contains(where: { $0.stopReason == "refusal" }) {
            show(error: "模型拒绝翻译这段内容。", needsSettings: false)
            return
        }
        if !hasTarget.contains(true) {
            // The model ignored the format: show whatever it said rather than nothing.
            targetTexts[0] = results[0].text.trimmingCharacters(in: .whitespacesAndNewlines)
            hasTarget[0] = !targetTexts[0].isEmpty
            applyText(1)
            return
        }
        let record = HistoryEntry(id: UUID(), date: Date(), source: source, sourceLang: sourceLang ?? "",
                                  targets: zip(targetLangs, targetTexts).map { TargetText(lang: $0, text: $1) },
                                  model: results[0].model, pairs: nil)
        entry = record
        HistoryStore.shared.upsert(record)
        if AppSettings.shared.alignment, source.count < 6000 {
            startAlignment(gen: gen, key: key)
        }
    }

    private func startAlignment(gen: Int, key: String) {
        let texts = [sourceText, targetTexts[0], targetTexts[1]]
        alignTask = Task { [weak self] in
            do {
                let (pairs, result) = try await Aligner.align(key: key, source: texts[0], a: texts[1], b: texts[2])
                UsageTracker.shared.record(model: result.model.isEmpty ? Models.aligner : result.model, usage: result.usage)
                guard let self, gen == self.generation, !self.stale, !pairs.isEmpty else { return }
                self.alignRanges = Aligner.resolve(pairs, in: texts)
                self.updateHighlights()
                if var entry = self.entry {
                    entry.pairs = pairs
                    self.entry = entry
                    HistoryStore.shared.upsert(entry)
                }
            } catch {
                NSLog("GPT Translate alignment failed: \(error)")
            }
        }
    }

    private func show(error: String, needsSettings: Bool) {
        errorMessage = error
        errorNeedsSettings = needsSettings
    }

    func copy(_ index: Int) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(targetTexts[index], forType: .string)
    }

    // MARK: Alignment highlight

    private func clearAlignment() {
        alignRanges = []
        selection = nil
        hover = nil
        updateHighlights()
    }

    private func hoverChanged(pane: Int, index: Int?) {
        let new = index.map { (pane, $0) }
        if new?.0 == hover?.pane && new?.1 == hover?.index { return }
        hover = new
        if selection == nil { updateHighlights() }
    }

    private func updateHighlights(scroll: Bool = false) {
        var groups: [Int] = []
        if let selection {
            groups = alignRanges.indices.filter { g in
                alignRanges[g][selection.pane].map { NSIntersectionRange($0, selection.range).length > 0 } ?? false
            }
        } else if let hover {
            groups = alignRanges.indices.filter { g in
                alignRanges[g][hover.pane].map { NSLocationInRange(hover.index, $0) } ?? false
            }
        }
        for (pane, tv) in views {
            guard let layoutManager = tv.layoutManager else { continue }
            let length = (tv.string as NSString).length
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
            var first: NSRange?
            for g in groups {
                guard let range = alignRanges[g][pane], NSMaxRange(range) <= length else { continue }
                layoutManager.addTemporaryAttribute(.backgroundColor, value: Theme.highlight, forCharacterRange: range)
                if first == nil { first = range }
            }
            if scroll, let first, pane != selection?.pane { tv.scrollRangeToVisible(first) }
        }
    }

    // MARK: Debug hooks (gpttranslate://debug-…)

    func debugSelect(pane: Int, text: String) {
        guard let tv = views[pane] else { return }
        let range = (tv.string as NSString).range(of: text)
        guard range.location != NSNotFound else { return }
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(range)
    }

    /// Replaces the source text through the text view's typing path, as if the user had typed it.
    func debugType(_ text: String) {
        guard let tv = views[0] else { return }
        tv.window?.makeFirstResponder(tv)
        tv.insertText(text, replacementRange: NSRange(location: 0, length: (tv.string as NSString).length))
    }

    /// Select-all + delete in the source pane, the same edit path as a user clearing it.
    func debugClearSource() {
        guard let tv = views[0] else { return }
        tv.window?.makeFirstResponder(tv)
        tv.selectAll(nil)
        tv.deleteBackward(nil)
    }

    func debugScroll(pane: Int, fraction: CGFloat) -> String {
        guard let tv = views[pane] else { return "no pane" }
        return scrollSync.debugScroll(tv, to: fraction)
    }

    func debugScrollOffsets() -> String { scrollSync.debugOffsets() }

    func debugState() -> String {
        var lines = [
            "source[\(sourceLang ?? "?")]: \(sourceText)",
            "target1[\(targetLangs[0])]: \(targetTexts[0])",
            "target2[\(targetLangs[1])]: \(targetTexts[1])",
            "translating: \(isTranslating) stale: \(stale) error: \(errorMessage ?? "-")",
            "confirmation: \(confirmation ?? "-") truncated: \(truncated)",
            "usage: \(String(format: "$%.5f", UsageTracker.shared.appSpend)) requests: \(UsageTracker.shared.requests)",
            "alignment groups: \(alignRanges.count)",
        ]
        let texts = [sourceText] + targetTexts
        for group in alignRanges {
            lines.append(group.enumerated().map { pane, range in
                range.map { (texts[pane] as NSString).substring(with: $0) } ?? "∅"
            }.joined(separator: " | "))
        }
        if let selection {
            lines.append("selection pane \(selection.pane): \((texts[selection.pane] as NSString).substring(with: selection.range))")
        }
        for (pane, tv) in views.sorted(by: { $0.key < $1.key }) {
            var highlighted: [String] = []
            let length = (tv.string as NSString).length
            var index = 0
            while index < length {
                var effective = NSRange()
                let value = tv.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: &effective)
                if value != nil { highlighted.append((tv.string as NSString).substring(with: effective)) }
                index = max(NSMaxRange(effective), index + 1)
            }
            lines.append("highlight pane \(pane): \(highlighted)")
            if let rep = tv.bitmapImageRepForCachingDisplay(in: tv.visibleRect) {
                tv.cacheDisplay(in: tv.visibleRect, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: AppPaths.support.appendingPathComponent("debug/pane\(pane).png"))
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? PaneTextView, tv.pane == 0 else { return }
        sourceText = tv.string
        pendingConfirmation = nil
        confirmation = nil
        defer { onContentChange?(false) }
        if sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Cleared source: nothing left to show a translation for.
            cancelWork()
            entry = nil
            sourceLang = nil
            targetLangs = ["", ""]
            targetTexts = ["", ""]
            hasTarget = [false, false]
            errorMessage = nil
            stale = false
            clearAlignment()
            for pane in 1...2 { applyText(pane, force: true) }
            return
        } else if hasTarget.contains(true) && !stale {
            // Edited source: dim the old translation until the user asks for a new one.
            stale = true
            clearAlignment()
            for pane in 1...2 { applyText(pane, force: true) }
        }
        // A translation of the previous text is now outdated; stop paying for it. Enter translates the new text.
        if isTranslating { cancelWork() }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !applyingProgrammatically, let tv = notification.object as? PaneTextView else { return }
        let range = tv.selectedRange()
        selection = range.length > 0 ? (tv.pane, range) : nil
        updateHighlights(scroll: true)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard (textView as? PaneTextView)?.pane == 0 else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                translate()
            }
            return true
        }
        return false
    }
}

/// Coalesces rapid updates into one per interval and drops whatever is still pending once stopped.
@MainActor
private final class Throttle {
    private var latest: String?
    private var scheduled = false
    private var stopped = false

    func submit(_ value: String, apply: @escaping @MainActor (String) -> Void) {
        latest = value
        guard !scheduled, !stopped else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            MainActor.assumeIsolated {
                self.scheduled = false
                guard !self.stopped, let value = self.latest else { return }
                self.latest = nil
                apply(value)
            }
        }
    }

    func stop() {
        stopped = true
        latest = nil
    }
}
