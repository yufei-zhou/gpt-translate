import Foundation
import UserNotifications

struct TargetText: Codable, Hashable {
    var lang: String
    var text: String
}

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var date: Date
    var source: String
    var sourceLang: String
    var targets: [TargetText]
    var model: String
    var pairs: [[String]]?
}

/// Translation history, kept for 30 days in a JSON file under Application Support.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let retention: TimeInterval = 30 * 24 * 3600

    @Published private(set) var entries: [HistoryEntry] = []
    private let url = AppPaths.support.appendingPathComponent("history.json")
    private var pruneTimer: Timer?
    /// False while history.json exists but can't be read (it was once written with complete file protection, which
    /// macOS sometimes keeps locked). Until it is read, nothing is written over it; new entries stay in memory.
    private var loaded = false

    private init() {
        loadIfNeeded()
        prune()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in HistoryStore.shared.prune() }
        }
    }

    func upsert(_ entry: HistoryEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            // Re-translating the same text replaces the previous record instead of piling up duplicates.
            entries.removeAll { $0.source == entry.source }
            entries.insert(entry, at: 0)
        }
        save()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    func prune() {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        let before = entries.count
        entries.removeAll { $0.date < cutoff }
        if entries.count != before { save() }
    }

    /// Reads the saved history, merging in anything recorded while it was unreadable.
    func loadIfNeeded() {
        guard !loaded else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { loaded = true; return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url) else { return }
        guard let saved = try? decoder.decode([HistoryEntry].self, from: data) else {
            // Unparseable: keep it aside rather than overwrite it.
            try? FileManager.default.moveItem(at: url, to: url.deletingPathExtension().appendingPathExtension("damaged.json"))
            loaded = true
            return
        }
        let recent = entries.filter { new in !saved.contains { $0.id == new.id } }
        entries = recent + saved.filter { old in !recent.contains { $0.source == old.source } }
        loaded = true
        if !recent.isEmpty { save() }
    }

    private func save() {
        loadIfNeeded()
        guard loaded else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// API spend in the current billing cycle, measured from the `usage` of every response this app receives.
/// A cycle starts on the renewal day, when the plan's monthly credits are renewed and the old ones expire.
@MainActor
final class UsageTracker: ObservableObject {
    static let shared = UsageTracker()
    private let defaults = UserDefaults.standard

    /// The current cycle's start date (yyyy-MM-dd).
    @Published private(set) var cycle: String
    @Published private(set) var appSpend: Double
    @Published private(set) var requests: Int
    /// All-time spend of this app; never reset, so balance estimates survive month rollover and 清零.
    @Published private(set) var lifetimeSpend: Double
    /// Account balance as last read from the Console, and this app's lifetime spend at that moment.
    @Published private(set) var balanceAnchor: Double?
    private var lifetimeAtAnchor: Double
    /// Console balance minus what this app has spent since it was entered.
    var estimatedBalance: Double? { balanceAnchor.map { $0 - (lifetimeSpend - lifetimeAtAnchor) } }

    /// Amount counted against the $100 budget: what is missing from the calibrated balance,
    /// or this cycle's app spend when no balance has been entered.
    var total: Double {
        guard let balance = estimatedBalance else { return appSpend }
        return max(0, AppSettings.shared.budget - balance)
    }

    var isBlocked: Bool { blockedMessage != nil }

    /// Why API calls are paused, or nil when they are allowed.
    var blockedMessage: String? {
        rollCycleIfNeeded()
        guard total >= AppSettings.shared.monthlyLimit else { return nil }
        if let balance = estimatedBalance {
            return String(format: "账户余额约 $%.2f，已暂停调用。", balance)
        }
        return String(format: "本期 API 用量已达 $%.0f 上限，已暂停调用。", AppSettings.shared.monthlyLimit)
    }

    private init() {
        let saved = defaults.string(forKey: "usage.month")
        // Before cycles, this held a calendar month ("2026-11"): that month's spend carries over into the current cycle.
        cycle = saved.map { $0.count == 7 ? Self.currentCycle() : $0 } ?? Self.currentCycle()
        appSpend = defaults.double(forKey: "usage.spend")
        requests = defaults.integer(forKey: "usage.requests")
        lifetimeSpend = defaults.double(forKey: "usage.lifetime")
        balanceAnchor = defaults.object(forKey: "usage.balance") as? Double
        lifetimeAtAnchor = defaults.double(forKey: "usage.lifetimeAtBalance")
        rollCycleIfNeeded()
    }

    /// The latest renewal day at or before `now` (the month's last day when it is shorter).
    static func cycleStart(renewalDay: Int, now: Date = Date()) -> Date {
        let calendar = Calendar.current
        func renewal(inMonthOf date: Date) -> Date {
            let month = calendar.dateInterval(of: .month, for: date)!
            let days = calendar.range(of: .day, in: .month, for: month.start)!.count
            return calendar.date(byAdding: .day, value: min(max(renewalDay, 1), days) - 1, to: month.start)!
        }
        let thisMonth = renewal(inMonthOf: now)
        return thisMonth <= now ? thisMonth : renewal(inMonthOf: calendar.date(byAdding: .month, value: -1, to: now)!)
    }

    static func currentCycle() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: cycleStart(renewalDay: AppSettings.shared.renewalDay))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Days since the cycle began; credits can arrive a while after the renewal day.
    var daysIntoCycle: Int {
        Calendar.current.dateComponents([.day], from: Self.cycleStart(renewalDay: AppSettings.shared.renewalDay), to: Date()).day ?? 0
    }

    /// New cycle: the old credits expired and a full budget arrives, so the balance estimate starts over from it.
    func rollCycleIfNeeded() {
        let now = Self.currentCycle()
        guard now != cycle else { return }
        // An earlier start means the renewal day moved back, not that a new cycle began.
        let isNewCycle = now > cycle
        cycle = now
        guard isNewCycle else { return save() }
        appSpend = 0
        requests = 0
        if balanceAnchor != nil {
            balanceAnchor = AppSettings.shared.budget
            lifetimeAtAnchor = lifetimeSpend
        }
        save()
    }

    /// The renewal day was corrected: keep counting this cycle's spend rather than starting over.
    func renewalDayChanged() {
        cycle = Self.currentCycle()
        save()
    }

    func record(model: String, usage: TokenUsage) {
        rollCycleIfNeeded()
        let cost = Models.cost(model: model, usage: usage)
        appSpend += cost
        lifetimeSpend += cost
        requests += 1
        save()
        checkThresholds()
    }

    func calibrateBalance(_ balance: Double) {
        balanceAnchor = balance
        lifetimeAtAnchor = lifetimeSpend
        defaults.removeObject(forKey: "usage.warned")
        defaults.removeObject(forKey: "usage.stopped")
        save()
        checkThresholds()
    }

    func checkThresholds() {
        let settings = AppSettings.shared
        let balance = estimatedBalance.map { String(format: "账户余额约 $%.2f", $0) }
        if total >= settings.monthlyLimit {
            if defaults.string(forKey: "usage.stopped") != cycle {
                defaults.set(cycle, forKey: "usage.stopped")
                Notifier.post(title: "GPT Translate 已暂停调用",
                              body: balance.map { "\($0)，已暂停调用。充值后在设置里重新校准余额即可恢复。" }
                                  ?? String(format: "本期 API 用量 $%.2f，已达到 $%.0f 上限。", total, settings.monthlyLimit))
            }
        } else if total >= settings.warnAt {
            if defaults.string(forKey: "usage.warned") != cycle {
                defaults.set(cycle, forKey: "usage.warned")
                Notifier.post(title: "API 用量提醒",
                              body: (balance ?? String(format: "本期已用 $%.2f", total))
                                  + String(format: "，用到 $%.0f 时将停止调用。", settings.monthlyLimit))
            }
        }
    }

    private func save() {
        defaults.set(cycle, forKey: "usage.month")
        defaults.set(appSpend, forKey: "usage.spend")
        defaults.set(requests, forKey: "usage.requests")
        defaults.set(lifetimeSpend, forKey: "usage.lifetime")
        defaults.set(balanceAnchor, forKey: "usage.balance")
        defaults.set(lifetimeAtAnchor, forKey: "usage.lifetimeAtBalance")
    }
}

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
