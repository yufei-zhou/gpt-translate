import AppKit
import SwiftUI

final class TranslatorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    var onNew: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "w": orderOut(nil)
        case "n": onNew?()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let model = TranslatorModel()
    private lazy var panel: TranslatorPanel = makePanel()
    /// True while we move the panel ourselves, so only user drags are remembered.
    private var placing = false

    /// The panel's height follows its text between these bounds; beyond them the panes scroll.
    static let minHeight: CGFloat = 220
    static let maxHeight: CGFloat = 640

    private static func maxHeight(on visible: NSRect) -> CGFloat { min(maxHeight, visible.height * 0.8) }

    private func makePanel() -> TranslatorPanel {
        let panel = TranslatorPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 360),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = Theme.background
        panel.minSize = NSSize(width: 560, height: Self.minHeight)
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        let host = NSHostingView(rootView: PanelView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        model.onContentChange = { [weak self] allowShrink in self?.fitHeight(allowShrink: allowShrink) }
        // ⌘N: an empty panel.
        panel.onNew = { [weak self] in
            guard let self else { return }
            model.load(text: "")
            model.focusSource()
            fitHeight(allowShrink: true)
        }
        return panel
    }

    var isVisible: Bool { panel.isVisible }

    func show(text: String, translate: Bool) {
        model.load(text: text)
        present(for: text)
        if translate { model.translate() }
    }

    /// An image to read and translate, like text that was just selected.
    func show(image: NSImage) {
        model.load(image: image)
        present(for: "")
        model.translate()
    }

    func show(entry: HistoryEntry) {
        model.load(entry: entry)
        present(for: entry.source)
    }

    /// The panel as it was left, edits and all.
    func reopen() {
        present(for: model.sourceText)
    }

    private func present(for text: String) {
        model.restyle()
        if !panel.isVisible {
            placing = true
            panel.setFrame(frame(for: text), display: false)
            placing = false
        }
        panel.makeKeyAndOrderFront(nil)
        watchOutsideClicks()
        ClipboardWatcher.shared.markUsed()
        model.focusSource()
        APIClient.warmUp()
        // The first estimate came from the raw source; refine it once the panes are laid out at their real widths.
        DispatchQueue.main.async { [weak self] in self?.fitHeight(allowShrink: true) }
    }

    /// Resizes the panel to fit its text, keeping the top edge where it is. While a translation streams in it only
    /// grows, so the window doesn't bounce; afterwards it may shrink to fit.
    func fitHeight(allowShrink: Bool) {
        guard panel.isVisible, !panel.inLiveResize else { return }
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let height = min(max(model.contentHeight(), Self.minHeight), Self.maxHeight(on: visible)).rounded()
        var frame = panel.frame
        guard abs(height - frame.height) >= 2, allowShrink || height > frame.height else { return }
        frame.origin.y += frame.height - height
        frame.size.height = height
        frame.origin.y = max(frame.origin.y, visible.minY + 8)
        placing = true
        panel.setFrame(frame, display: true)
        placing = false
    }

    func hide() {
        ClipboardWatcher.shared.markUsed()
        panel.orderOut(nil)
    }

    /// Closing normally relies on the panel being the key window. If it loses key status without being told (a
    /// system prompt taking focus can do that), clicks in other apps and Esc still close it.
    private var outsideClickMonitor: Any?

    private func watchOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in
            MainActor.assumeIsolated {
                // A press on the panel itself (dragging it) can be reported to other apps on some setups.
                guard let self, self.panel.isVisible, !self.model.pinned,
                      !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.hide()
            }
        }
    }

    /// Esc while the panel isn't key went to another app; the key window handles its own Esc (and an input method
    /// may be using it to cancel a composition).
    func escapePressedElsewhere() {
        guard panel.isVisible, !panel.isKeyWindow, !model.pinned else { return }
        hide()
    }

    /// Debug: a ⌘-key press through the panel's own key-equivalent handling.
    func debugCommandKey(_ key: String) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                           context: nil, characters: key, charactersIgnoringModifiers: key,
                                           isARepeat: false, keyCode: 45) else { return }
        _ = panel.performKeyEquivalent(with: event)
    }

    /// Height follows the text length; width is whatever the user last resized it to.
    private func frame(for text: String) -> NSRect {
        let savedWidth = UserDefaults.standard.double(forKey: "panelWidth")
        let width = savedWidth > 0 ? CGFloat(savedWidth) : 760
        func textHeight(inPaneOf paneWidth: CGFloat) -> CGFloat {
            NSAttributedString(string: text.isEmpty ? " " : text, attributes: Theme.textAttributes())
                .boundingRect(with: NSSize(width: paneWidth - 40, height: .greatestFiniteMagnitude),
                              options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        }
        let sourceHeight = textHeight(inPaneOf: width * PanelView.sourceShare)
        let targetHeight = textHeight(inPaneOf: width * (1 - PanelView.sourceShare))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        var visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // A translation is roughly as long as the source; the right column stacks two of them.
        let needed = max(sourceHeight + 100, 2 * (targetHeight + 52))
        let height = min(max(needed, Self.minHeight), Self.maxHeight(on: visible))

        var origin = NSPoint(x: mouse.x - width / 2, y: mouse.y - height - 18)
        if origin.y < visible.minY { origin.y = mouse.y + 18 }
        // After the user has dragged the panel somewhere, keep its top-left corner there.
        if let saved = UserDefaults.standard.array(forKey: "panelTopLeft") as? [Double], saved.count == 2 {
            let topLeft = NSPoint(x: saved[0], y: saved[1])
            if let home = NSScreen.screens.first(where: { NSMouseInRect(topLeft, $0.frame.insetBy(dx: -1, dy: -1), false) }) {
                visible = home.visibleFrame
                origin = NSPoint(x: topLeft.x, y: topLeft.y - height)
            }
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - height - 8)
        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }

    func windowDidResignKey(_ notification: Notification) {
        // Whatever was copied or pasted while the panel was open is used up, so it won't replace the panel's text later.
        ClipboardWatcher.shared.markUsed()
        guard !model.pinned else { return }
        // Some setups take key status away while the panel is being dragged. That isn't the user leaving it: keep
        // it open and give it the keyboard back once the drag ends.
        if NSEvent.pressedMouseButtons != 0, panel.frame.contains(NSEvent.mouseLocation) {
            regainKeyAfterDrag()
        } else {
            hide()
        }
    }

    private func regainKeyAfterDrag() {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons == 0 else { return }
                timer.invalidate()
                if self.panel.isVisible, !self.panel.isKeyWindow { self.panel.makeKey() }
            }
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard !placing, panel.isVisible else { return }
        UserDefaults.standard.set([Double(panel.frame.minX), Double(panel.frame.maxY)], forKey: "panelTopLeft")
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        UserDefaults.standard.set(Double(panel.frame.width), forKey: "panelWidth")
        UserDefaults.standard.set([Double(panel.frame.minX), Double(panel.frame.maxY)], forKey: "panelTopLeft")
    }
}

// MARK: - SwiftUI

struct PanelView: View {
    @ObservedObject var model: TranslatorModel

    /// The single source pane is darker and undivided, so it gets a little less width than the
    /// two stacked translations to balance visually.
    /// Overridable with `defaults write io.github.yufei-zhou.GPTTranslate panelSourceShare -float 0.42`.
    static var sourceShare: CGFloat {
        let saved = UserDefaults.standard.double(forKey: "panelSourceShare")
        return (0.3...0.6).contains(saved) ? CGFloat(saved) : 0.47
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                SourcePane(model: model)
                    .frame(width: (geometry.size.width * Self.sourceShare).rounded())
                Rectangle().fill(Color.claudeBorder).frame(width: 1)
                GeometryReader { column in
                    // The divider stays in the middle. It moves only when that lets both translations show in full
                    // (one is too long for its half and the other leaves enough room), and never while they stream in.
                    let available = column.size.height - 1
                    let middle = (available / 2).rounded()
                    let (need0, need1) = (model.paneHeights[0], model.paneHeights[1])
                    let fitsMiddle = need0 <= middle && need1 <= available - middle
                    let top = model.isTranslating || fitsMiddle || need0 + need1 > available ? middle
                        : min(max(middle, ceil(need0)), floor(available - need1))
                    VStack(spacing: 0) {
                        TargetPane(model: model, index: 0)
                            .frame(height: top)
                        Rectangle().fill(Color.claudeBorder).frame(height: 1)
                        TargetPane(model: model, index: 1)
                            .frame(maxHeight: .infinity)
                    }
                    .animation(.easeInOut(duration: 0.25), value: model.isTranslating)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.claudeBackground)
        .ignoresSafeArea()
    }
}

/// Language name above a pane. Until it is known, a short placeholder set smaller and lighter than the empty-pane
/// prompt below it, so the prompt stays the focus of an empty panel.
private struct PaneLabel: View {
    let text: String
    let placeholder: String
    var body: some View {
        if text.isEmpty {
            Text(placeholder)
                .font(.system(size: 11.5, weight: .medium))
                .tracking(0.2)
                .foregroundStyle(Color.claudeTertiary.opacity(0.75))
        } else {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(Color.claudeText)
        }
    }
}

private struct SourcePane: View {
    @ObservedObject var model: TranslatorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                PaneLabel(text: model.sourceLang.map(Translator.displayName) ?? "", placeholder: "Source")
                Spacer()
                IconButton(symbol: model.pinned ? "pin.fill" : "pin", active: model.pinned, help: "固定窗口") {
                    model.pinned.toggle()
                }
                IconButton(symbol: "clock.arrow.circlepath", help: "历史记录") { AppDelegate.shared.showHistory() }
                IconButton(symbol: "gearshape", help: "设置") { AppDelegate.shared.showSettings() }
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .frame(height: 40)
            PaneTextRepresentable(model: model, pane: 0)
            HStack {
                Spacer()
                SendButton(busy: model.isTranslating) {
                    model.isTranslating ? model.cancel() : model.translate()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .background(Color.claudeSourceBackground)
    }
}

private struct TargetPane: View {
    @ObservedObject var model: TranslatorModel
    let index: Int
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                PaneLabel(text: Translator.displayName(model.targetLangs[index]), placeholder: "Target \(index + 1)")
                if model.streaming[index] { PulseDot() }
                if model.truncated[index] {
                    Text("已截断").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.claudeAccent)
                }
                Spacer()
                if model.hasTarget[index] && !model.isTranslating {
                    IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "复制") {
                        model.copy(index)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    }
                    .opacity(hovering || copied ? 1 : 0)
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .frame(height: 40)
            PaneTextRepresentable(model: model, pane: index + 1)
                .overlay(alignment: .topLeading) {
                    if index == 0, let error = model.errorMessage {
                        Notice(message: error, actionTitle: model.errorNeedsSettings ? "打开设置" : nil) {
                            AppDelegate.shared.showSettings()
                        }
                    } else if index == 0, let confirmation = model.confirmation {
                        Notice(message: confirmation, actionTitle: "翻译") { model.translate() }
                    }
                }
                .padding(.bottom, 8)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// A short message over the first translation pane (an error, or a request to confirm), with an optional action.
private struct Notice: View {
    let message: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Color.claudeText)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.claudeAccent)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.claudeBackground)
    }
}

private struct IconButton: View {
    let symbol: String
    var active = false
    var help = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 24, height: 24)
                .foregroundStyle(active ? Color.claudeAccent : (hover ? Color.claudeText : Color.claudeTertiary))
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.claudeBorder.opacity(0.7) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

/// Claude-style send button: terracotta rounded square with an up arrow, a stop square while busy.
private struct SendButton: View {
    let busy: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: busy ? "stop.fill" : "arrow.up")
                .font(.system(size: busy ? 10 : 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: hover ? Theme.accentPressed : Theme.accent)))
        }
        .buttonStyle(.plain)
        .help(busy ? "停止" : "翻译（⏎）")
        .onHover { hover = $0 }
    }
}

private struct PulseDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color.claudeAccent)
            .frame(width: 6, height: 6)
            .opacity(on ? 1 : 0.25)
            .scaleEffect(on ? 1 : 0.7)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// Keeps the text view exactly as wide as the visible area so lines wrap.
final class WrappingScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let documentView, documentView.frame.width != contentSize.width else { return }
        documentView.setFrameSize(NSSize(width: contentSize.width, height: documentView.frame.height))
    }
}

struct PaneTextRepresentable: NSViewRepresentable {
    let model: TranslatorModel
    let pane: Int

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PaneTextView(usingTextLayoutManager: false)
        textView.isEditable = pane == 0
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = pane == 0
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 13, height: 0)
        textView.textContainer?.lineFragmentPadding = 5
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.insertionPointColor = Theme.accent
        textView.selectedTextAttributes = [.backgroundColor: Theme.selection]
        textView.placeholder = pane == 0 ? "Type text to translate" : "Translation appears here"
        textView.delegate = model
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.frame = NSRect(x: 0, y: 0, width: 300, height: 100)

        let scrollView = WrappingScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        model.register(textView, pane: pane)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
