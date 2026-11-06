import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    let hotkey = HotkeyMonitor()
    let panelController = PanelController()
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        _ = HistoryStore.shared
        UsageTracker.shared.rollCycleIfNeeded()
        Notifier.requestPermission()

        ClipboardWatcher.shared.start()
        hotkey.onDoubleCopy = { [weak self] baseline in self?.handleDoubleCopy(since: baseline) }
        if !hotkey.start() {
            HotkeyMonitor.requestPermission()
            hotkey.startWhenPermitted()
            showSettings()
        } else if !Keychain.hasKey {
            showSettings()
        }
        // Read the key now rather than on the first translation: after a rebuild the Keychain asks for permission,
        // and that prompt taking focus from an open panel left the panel unable to close.
        if Keychain.hasKey { DispatchQueue.main.async { _ = Keychain.apiKey } }
        hotkey.onEscape = { [weak self] in self?.panelController.escapePressedElsewhere() }
    }

    /// An accessory app has no visible menu bar, but ⌘C/⌘V/⌘A/⌘Z only reach text fields
    /// through the key equivalents of a main menu, so install a hidden Edit menu.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// Launching the app again (Spotlight, Finder) opens Settings, since there is no Dock or menu bar icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// gpttranslate://translate?text=…  ·  gpttranslate://settings  ·  gpttranslate://history
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch url.host {
            case "translate":
                let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "text" }?.value ?? ""
                panelController.show(text: text, translate: !text.isEmpty)
            case "history":
                showHistory()
            case "debug-eval":
                Task { await Evaluator.run(models: [Models.terra.id, Models.luna.id]) }
            case "debug-eval-modes":
                Task { await Evaluator.compareModes(model: Models.terra.id) }
            case "debug-balance":
                if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "value" })?.value.flatMap(Double.init) {
                    UsageTracker.shared.calibrateBalance(value)
                }
            case "debug-type":
                let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "text" }?.value ?? ""
                panelController.model.debugType(text)
            case "debug-history-status":
                let file = AppPaths.support.appendingPathComponent("history.json")
                var report = "entries: \(HistoryStore.shared.entries.count)\n"
                do { report += "read: \(try Data(contentsOf: file).count) bytes\n" } catch { report += "read error: \(error)\n" }
                try? report.write(to: AppPaths.support.appendingPathComponent("debug/history-status.txt"), atomically: true, encoding: .utf8)
            case "debug-prefill":
                // The no-selection path of ⌘C C; ?age=N pretends the clipboard changed N seconds ago and is unused.
                // Records only the decision and lengths, never the clipboard text, and never translates it.
                if let age = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "age" })?.value.flatMap(Double.init) {
                    ClipboardWatcher.shared.lastChange = Date().addingTimeInterval(-age)
                    ClipboardWatcher.shared.usedChangeCount = nil
                }
                let unused = ClipboardWatcher.shared.unusedText()
                if unused.isEmpty { panelController.reopen() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    let decision = unused.isEmpty ? "reopen" : "translate clipboard (length \((unused as NSString).length))"
                    try? "\(decision)\n\(self?.panelController.model.debugSourceSelection() ?? "")"
                        .write(to: AppPaths.support.appendingPathComponent("debug/prefill.txt"), atomically: true, encoding: .utf8)
                }
            case "debug-renewal":
                // ?day=N sets the renewal day through the setting, then records the cycle and spend.
                if let day = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "day" })?.value.flatMap(Int.init) {
                    AppSettings.shared.renewalDay = day
                }
                let usage = UsageTracker.shared
                try? String(format: "cycle %@ days %d spend %.4f requests %d balance %@", usage.cycle, usage.daysIntoCycle,
                            usage.appSpend, usage.requests, usage.estimatedBalance.map { String(format: "%.2f", $0) } ?? "nil")
                    .write(to: AppPaths.support.appendingPathComponent("debug/renewal.txt"), atomically: true, encoding: .utf8)
            case "debug-hide":
                panelController.hide()
            case "debug-new":
                panelController.debugCommandKey("n")
            case "debug-scroll":
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let pane = Int(items.first { $0.name == "pane" }?.value ?? "") ?? 1
                let fraction = Double(items.first { $0.name == "f" }?.value ?? "") ?? 0.5
                // Records the offsets right after scrolling and again 0.3 s later, to catch panes pulling each other.
                let model = panelController.model
                let now = model.debugScroll(pane: pane, fraction: fraction)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    try? "\(now)\nlater: \(model.debugScrollOffsets())"
                        .write(to: AppPaths.support.appendingPathComponent("debug/scroll.txt"), atomically: true, encoding: .utf8)
                }
            case "debug-clear":
                panelController.model.debugClearSource()
            case "debug-history":
                // ?index=N opens that entry; ?share=0.46 sets the split first; ?snapshot=1 captures right away,
                // before the panel can lose focus and hide.
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let value = { (name: String) in items.first { $0.name == name }?.value }
                if let share = value("share").flatMap(Double.init) {
                    UserDefaults.standard.set(share, forKey: "panelSourceShare")
                    panelController.hide()
                }
                let index = value("index").flatMap(Int.init) ?? 0
                HistoryStore.shared.loadIfNeeded()
                let entries = HistoryStore.shared.entries
                if entries.indices.contains(index) { open(entry: entries[index]) }
                if value("snapshot") != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.writeSnapshots() }
                }
            case "debug-deselect":
                debugClickBlankWhileEditing()
            case "debug-paste":
                debugPasteIntoKeyField()
            case "debug-snapshot":
                writeSnapshots()
            case "debug-select":
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let pane = Int(items.first { $0.name == "pane" }?.value ?? "") ?? 0
                panelController.model.debugSelect(pane: pane, text: items.first { $0.name == "text" }?.value ?? "")
            default:
                showSettings()
            }
        }
    }

    /// Renders every visible window of this app to PNG (no screen-recording permission needed),
    /// plus a text dump of the translator state, for automated checks.
    private func writeSnapshots() {
        let dir = AppPaths.support.appendingPathComponent("debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for window in NSApp.windows where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = window is TranslatorPanel ? "panel" : (window.title.isEmpty ? "window-\(window.windowNumber)" : window.title)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        try? panelController.model.debugState().write(to: dir.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
    }

    /// Focuses the API key field and sends it a real ⌘V key event through NSApp, the same path a keypress takes.
    private func debugPasteIntoKeyField() {
        showSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let window = self?.settingsWindow, let field = Self.firstSecureField(in: window.contentView) else { return }
            window.makeFirstResponder(field)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, characters: "v", charactersIgnoringModifiers: "v",
                                         isARepeat: false, keyCode: 9)
            if let event { NSApp.sendEvent(event) }
        }
    }

    /// Puts the caret in a number field, then sends a real click to an empty spot of the Settings window
    /// and records whether editing ended.
    private func debugClickBlankWhileEditing() {
        showSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let window = self?.settingsWindow, let content = window.contentView,
                  let field = Self.textFields(in: content).first(where: { !($0 is NSSecureTextField) && $0.isEditable }) else { return }
            window.makeFirstResponder(field)
            let before = String(describing: type(of: window.firstResponder!))
            let point = NSPoint(x: 8, y: 8)  // bottom-left margin, outside every card
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
            }
            let after = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            try? "before: \(before)\nafter: \(after)\n".write(to: AppPaths.support.appendingPathComponent("debug/deselect.txt"), atomically: true, encoding: .utf8)
        }
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? [] + view.subviews.flatMap { textFields(in: $0) }
    }

    private static func firstSecureField(in view: NSView?) -> NSSecureTextField? {
        guard let view else { return nil }
        if let field = view as? NSSecureTextField { return field }
        for sub in view.subviews { if let found = firstSecureField(in: sub) { return found } }
        return nil
    }

    /// With a selection, ⌘C rewrites the pasteboard and its text gets translated. With nothing selected the pasteboard
    /// stays as it was (see openWithoutSelection). Apps write the copy asynchronously, so wait up to ~0.4 s for it.
    private func handleDoubleCopy(since baseline: Int) {
        func check(_ attempt: Int) {
            let pasteboard = NSPasteboard.general
            if pasteboard.changeCount != baseline {
                let text = (pasteboard.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                panelController.show(text: text, translate: !text.isEmpty)
            } else if attempt < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { check(attempt + 1) }
            } else {
                openWithoutSelection()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { check(0) }
    }

    /// ⌘C C with nothing selected: translates text copied in the last few minutes that the panel hasn't seen yet;
    /// otherwise reopens the panel as it was left.
    private func openWithoutSelection() {
        let text = ClipboardWatcher.shared.unusedText()
        if text.isEmpty {
            panelController.reopen()
        } else {
            panelController.show(text: text, translate: true)
        }
    }

    func showSettings() {
        panelController.hide()
        if settingsWindow == nil {
            // Height fitted to the content so the bottom margin matches the top one.
            let height = NSHostingView(rootView: SettingsView().frame(width: 500).fixedSize(horizontal: false, vertical: true))
                .fittingSize.height - 12  // grouped forms add extra bottom inset
            settingsWindow = makeWindow(title: "GPT Translate 设置", size: NSSize(width: 500, height: height),
                                        view: SettingsView())
        }
        present(settingsWindow)
    }

    func showHistory() {
        HistoryStore.shared.loadIfNeeded()
        panelController.hide()
        if historyWindow == nil {
            historyWindow = makeWindow(title: "翻译历史", size: NSSize(width: 560, height: 620), view: HistoryView())
        }
        present(historyWindow)
    }

    func open(entry: HistoryEntry) {
        panelController.show(entry: entry)
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow<V: View>(title: String, size: NSSize, view: V) -> NSWindow {
        let window = DeselectingWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(size)
        window.center()
        return window
    }
}

/// Clicking anywhere outside a text field ends editing, as users expect, instead of leaving the caret behind.
final class DeselectingWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, firstResponder is NSText,
           let hit = contentView?.hitTest(contentView?.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow),
           !(hit is NSText || hit is NSTextField || hit.superview is NSTextField) {
            makeFirstResponder(nil)
        }
        super.sendEvent(event)
    }
}
