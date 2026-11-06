import AppKit

/// Watches for ⌘C pressed twice in quick succession, like DeepL.
/// Uses a listen-only event tap, which needs the "Input Monitoring" permission.
final class HotkeyMonitor {
    /// Called with the pasteboard's change count from just before the first ⌘C, so the handler can tell whether
    /// anything was actually copied.
    var onDoubleCopy: ((Int) -> Void)?
    /// Esc pressed without modifiers, in any app.
    var onEscape: (() -> Void)?
    private var tap: CFMachPort?
    private var lastCopy: TimeInterval = 0
    private var changeCountBeforeCopy = 0
    private var retryTimer: Timer?
    private static let interval: TimeInterval = 0.5

    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    static func requestPermission() {
        CGRequestListenEventAccess()
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    /// Keeps retrying until the user grants Input Monitoring, then starts.
    func startWhenPermitted() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            if self?.start() == true { timer.invalidate() }
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .keyDown else { return }
        let flags = event.flags
        if event.getIntegerValueField(.keyboardEventKeycode) == 53,
           flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty {
            DispatchQueue.main.async { self.onEscape?() }
        }
        guard flags.contains(.maskCommand),
              !flags.contains(.maskShift), !flags.contains(.maskAlternate), !flags.contains(.maskControl) else {
            lastCopy = 0
            return
        }
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
        guard isLetterC(event) else {
            lastCopy = 0
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCopy < Self.interval {
            lastCopy = 0
            let baseline = changeCountBeforeCopy
            DispatchQueue.main.async { self.onDoubleCopy?(baseline) }
        } else {
            lastCopy = now
            // The tap sees the key before the frontmost app handles it, so this is the count before any copy.
            changeCountBeforeCopy = NSPasteboard.general.changeCount
            // A second ⌘C may follow: open the connection to the API now rather than when the panel asks.
            APIClient.warmUp()
        }
    }

    private func isLetterC(_ event: CGEvent) -> Bool {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        if length == 1 { return chars[0] == 0x63 || chars[0] == 0x43 }
        return event.getIntegerValueField(.keyboardEventKeycode) == 8
    }
}
