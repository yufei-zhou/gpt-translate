import AppKit

/// Decides whether ⌘C C with nothing selected translates the clipboard: only text copied in the last few minutes
/// that the panel hasn't seen yet. Each copy is used once, so reopening the panel later keeps your edits.
/// macOS doesn't record when the clipboard changed, so this notes it.
@MainActor
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()
    static let freshness: TimeInterval = 5 * 60

    private var changeCount = NSPasteboard.general.changeCount
    /// Unknown for whatever was on the clipboard before the app started, so that counts as old.
    var lastChange: Date?
    /// The clipboard as it was when the panel was last opened or closed; that copy counts as used.
    var usedChangeCount: Int?
    private var timer: Timer?

    func start() {
        // Reading changeCount is a cheap counter check; the contents are only read on ⌘C C.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardWatcher.shared.poll() }
        }
        timer?.tolerance = 0.5
    }

    private func poll() {
        let current = NSPasteboard.general.changeCount
        guard current != changeCount else { return }
        changeCount = current
        lastChange = Date()
    }

    func markUsed() {
        poll()
        usedChangeCount = changeCount
    }

    /// Clipboard text to translate: copied recently, not seen by the panel yet, and not a password or key.
    func unusedText() -> String {
        poll()
        guard changeCount != usedChangeCount, let lastChange,
              Date().timeIntervalSince(lastChange) <= Self.freshness else { return "" }
        return safeText()
    }

    private func safeText() -> String {
        let pasteboard = NSPasteboard.general
        // Password managers mark what they copy as concealed or transient.
        let hidden = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
            .contains { pasteboard.types?.contains(NSPasteboard.PasteboardType($0)) == true }
        let text = (pasteboard.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return hidden || SecretGuard.containsSecret(text) ? "" : text
    }
}
