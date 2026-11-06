import Foundation
import Security

enum AppPaths {
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GPTTranslate", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var alignment: Bool { didSet { defaults.set(alignment, forKey: "alignment") } }
    @Published var budget: Double {
        didSet {
            defaults.set(budget, forKey: "budget")
            // Thresholds moved: let this month's reminder and stop notifications fire again at the new amounts.
            defaults.removeObject(forKey: "usage.warned")
            defaults.removeObject(forKey: "usage.stopped")
        }
    }
    @Published var warnPercent: Double { didSet { defaults.set(warnPercent, forKey: "warnPercent") } }
    @Published var stopPercent: Double { didSet { defaults.set(stopPercent, forKey: "stopPercent") } }
    /// Day of the month the plan's API credits renew (see each credit's expiry date in the Console).
    @Published var renewalDay: Int {
        didSet {
            defaults.set(renewalDay, forKey: "renewalDay")
            UsageTracker.shared.renewalDayChanged()
        }
    }
    @Published var serif: Bool { didSet { defaults.set(serif, forKey: "serif") } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }

    private init() {
        defaults.register(defaults: [
            "model": Models.terra.id,
            "alignment": true,
            "budget": 100.0,
            "warnPercent": 90.0,
            "stopPercent": 97.0,
            "renewalDay": 1,
            "serif": true,
            "fontSize": 15.0,
        ])
        model = defaults.string(forKey: "model") ?? Models.terra.id
        alignment = defaults.bool(forKey: "alignment")
        budget = defaults.double(forKey: "budget")
        warnPercent = defaults.double(forKey: "warnPercent")
        stopPercent = defaults.double(forKey: "stopPercent")
        renewalDay = defaults.integer(forKey: "renewalDay")
        serif = defaults.bool(forKey: "serif")
        fontSize = defaults.double(forKey: "fontSize")
    }

    /// Dollar amounts derived from the monthly budget and the two percentages.
    var warnAt: Double { budget * warnPercent / 100 }
    var monthlyLimit: Double { budget * stopPercent / 100 }
}

/// The API key lives in the login keychain, never on disk in plain text.
@MainActor
enum Keychain {
    private static let service = "io.github.yufei-zhou.GPTTranslate"
    private static let account = "openai-api-key"
    private static var cached: String?

    /// Whether a key is saved, without reading (decrypting) it, so it never triggers a Keychain prompt.
    static var hasKey: Bool {
        if cached != nil { return true }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static var apiKey: String? {
        if let cached { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8) else { return nil }
        cached = key
        return key
    }

    @discardableResult
    static func setAPIKey(_ key: String?) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        cached = nil
        guard let key, !key.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrLabel as String] = "GPT Translate API Key"
        let ok = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        if ok { cached = key }
        return ok
    }
}
