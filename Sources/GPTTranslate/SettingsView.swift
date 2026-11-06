import AppKit
import Combine
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var usage = UsageTracker.shared
    @State private var keyInput = ""
    @State private var hasKey = Keychain.hasKey
    @State private var keyState: KeyState = .idle
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var hasPermission = HotkeyMonitor.hasPermission
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private enum KeyState: Equatable { case idle, testing, ok, failed(String) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Text("API Key")
                    SecureField("API Key", text: $keyInput, prompt: Text(maskedKey))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { saveKey() }
                    keyStatusIcon
                    Button(keyInput.isEmpty && hasKey ? "测试" : "保存") { saveKey() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(Color.claudeAccent)
                        .disabled(keyState == .testing || (keyInput.isEmpty && !hasKey))
                }
                if case .failed(let message) = keyState {
                    Text(message).foregroundStyle(.red)
                }
            }

            Section {
                Picker("模型", selection: $settings.model) {
                    ForEach(Models.translation) { Text($0.name).tag($0.id) }
                }
                Toggle("对照高亮", isOn: $settings.alignment)
                Toggle("衬线字体", isOn: $settings.serif)
                    .onChange(of: settings.serif) { AppDelegate.shared.panelController.model.restyle() }
                Stepper("字号  \(Int(settings.fontSize))", value: $settings.fontSize, in: 12...22)
                    .onChange(of: settings.fontSize) { AppDelegate.shared.panelController.model.restyle() }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("本期")
                        Spacer()
                        Text(String(format: "$%.2f", usage.total))
                            .font(.system(size: 20, weight: .semibold, design: .serif))
                        // The budget is edited in place, like the figures below; the thresholds follow it.
                        HStack(spacing: -2) {
                            Text("/ $").foregroundStyle(Color.claudeText)
                            DecimalField(value: $settings.budget, alignment: .leading, minimum: 1)
                        }
                    }
                    ProgressView(value: min(usage.total, settings.budget), total: max(settings.budget, 0.01))
                        .tint(usage.total >= settings.warnAt ? .red : Color.claudeAccent)
                    // Usage is budget minus balance, so a balance above the budget leaves nothing to measure.
                    if let balance = usage.estimatedBalance, balance > settings.budget + 0.005 {
                        Text("账户余额高于月预算，无法计算用量，请调整其中一个。")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                }
                LabeledContent("账户余额") { BalanceField(usage: usage) }
                Stepper("续期日  每月 \(settings.renewalDay) 日", value: $settings.renewalDay, in: 1...31)
                percentField("提醒", value: $settings.warnPercent)
                percentField("停用", value: $settings.stopPercent)
            }

            Section {
                Toggle("开机启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { setLaunchAtLogin(launchAtLogin) }
                if let loginError {
                    Text(loginError).foregroundStyle(.red)
                }
                LabeledContent("⌘C C") {
                    if hasPermission && AppDelegate.shared.hotkey.isRunning {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("授权输入监控") {
                            HotkeyMonitor.requestPermission()
                            HotkeyMonitor.openPrivacySettings()
                        }
                    }
                }
                HStack {
                    Button("翻译历史") { AppDelegate.shared.showHistory() }
                    Spacer()
                    Button("退出") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .tint(Color.claudeAccent)
        .onReceive(refresh) { _ in
            hasPermission = HotkeyMonitor.hasPermission
            usage.rollCycleIfNeeded()
            if hasPermission && !AppDelegate.shared.hotkey.isRunning { _ = AppDelegate.shared.hotkey.start() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    @ViewBuilder private var keyStatusIcon: some View {
        switch keyState {
        case .testing: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .idle: EmptyView()
        }
    }

    private func percentField(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 1) {
                DecimalField(value: value, alignment: .trailing)
                Text("%").foregroundStyle(Color.claudeText)
            }
        }
    }

    private var maskedKey: String {
        hasKey ? "••••••••••••••••" : "sk-…"
    }

    /// Saves the typed key (if any) to Keychain, then checks it with a minimal GPT-6 Luna request.
    private func saveKey() {
        let typed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            guard Keychain.setAPIKey(typed) else {
                keyState = .failed("无法写入钥匙串")
                return
            }
            hasKey = true
            keyInput = ""
        }
        guard let key = typed.isEmpty ? Keychain.apiKey : typed else { return }
        keyState = .testing
        Task {
            let (body, _) = Models.requestBody(model: Models.luna.id, system: "Reply with OK.", user: "ping", maxTokens: 16)
            do {
                let result = try await APIClient.stream(key: key, body: body) { _ in }
                UsageTracker.shared.record(model: result.model, usage: result.usage)
                keyState = .ok
            } catch {
                keyState = .failed(APIClient.describe(error).message)
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled { try service.register() }
            if !enabled, service.status == .enabled { try service.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
    }

}

/// Number field that takes "." or "," as the decimal mark, since the system region may use a comma.
private struct DecimalField: View {
    @Binding var value: Double
    var alignment: TextAlignment
    var minimum: Double = 0
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .labelsHidden()
            .fixedSize()
            .multilineTextAlignment(alignment)
            .focused($focused)
            .onAppear { text = Self.format(value) }
            .onSubmit { commit() }
            .onChange(of: focused) { if !focused { commit() } }
            .onChange(of: value) { if !focused { text = Self.format(value) } }
    }

    private func commit() {
        if let parsed = Self.parse(text), parsed >= minimum { value = parsed }
        text = Self.format(value)
    }

    static func parse(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

/// The account balance, edited in place: shows the live estimate, and typing the figure from the Console recalibrates it.
private struct BalanceField: View {
    @ObservedObject var usage: UsageTracker
    @State private var text = ""
    @FocusState private var focused: Bool

    private var shown: String { usage.estimatedBalance.map { String(format: "%.2f", $0) } ?? "" }

    var body: some View {
        // Negative spacing cancels the text field's built-in inset so "$" sits against the number.
        HStack(spacing: -3) {
            Text(usage.estimatedBalance == nil ? "$" : "约 $").foregroundStyle(Color.claudeText)
            TextField("", text: $text, prompt: Text("—"))
                .labelsHidden()
                .fixedSize()
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onAppear { text = shown }
                .onSubmit { commit() }
                .onChange(of: focused) { if !focused { commit() } }
                .onChange(of: usage.estimatedBalance) { if !focused { text = shown } }
        }
    }

    /// Recalibrates only when the figure was actually changed.
    private func commit() {
        if text != shown, let balance = DecimalField.parse(text), balance >= 0 { usage.calibrateBalance(balance) }
        text = shown
    }
}

struct HistoryView: View {
    @ObservedObject private var store = HistoryStore.shared
    @State private var query = ""

    private var filtered: [HistoryEntry] {
        guard !query.isEmpty else { return store.entries }
        return store.entries.filter { entry in
            entry.source.localizedCaseInsensitiveContains(query)
                || entry.targets.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.claudeTertiary)
                TextField("搜索", text: $query).textFieldStyle(.plain)
                Button("清空") { confirmClear() }.disabled(store.entries.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Rectangle().fill(Color.claudeBorder).frame(height: 1)
            if filtered.isEmpty {
                Spacer()
                Image(systemName: store.entries.isEmpty ? "clock" : "magnifyingglass")
                    .font(.system(size: 28)).foregroundStyle(Color.claudeAccent.opacity(0.6))
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { entry in
                            HistoryRow(entry: entry)
                                .contentShape(Rectangle())
                                .onTapGesture { AppDelegate.shared.open(entry: entry) }
                                .contextMenu {
                                    Button("删除") { store.delete(entry.id) }
                                }
                            Rectangle().fill(Color.claudeBorder).frame(height: 1).padding(.leading, 16)
                        }
                    }
                }
            }
        }
        .background(Color.claudeBackground)
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "清空全部翻译历史？"
        alert.informativeText = "此操作无法撤销。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { store.clear() }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.source)
                .font(Font(Theme.contentFont(size: 14, weight: .medium))).foregroundStyle(Color.claudeText).lineLimit(2)
            ForEach(entry.targets.prefix(2), id: \.self) { target in
                Text(target.text).font(Font(Theme.contentFont(size: 13)))
                    .foregroundStyle(Color.claudeText.opacity(0.85)).lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hover ? Color.claudeBorder.opacity(0.45) : .clear)
        .onHover { hover = $0 }
    }
}
