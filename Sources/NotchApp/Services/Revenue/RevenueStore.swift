import Foundation
import Combine

/// Single source of truth for revenue. UI only touches `Payment`.
/// All @Published mutations happen on the main thread: direct calls come from
/// SwiftUI actions / main-runloop Timers, and async continuations hop via MainActor.
final class RevenueStore: ObservableObject {
    static let shared = RevenueStore()
    static let providerDefaultsKey = "revenueProvider"
    static let providersDefaultsKey = "revenueProviders"
    static let hasKeyPrefix = "revenueHasKey:"

    @Published var connectedProviderIds: Set<String> = []
    @Published var payments: [Payment] = []
    @Published var banner: Payment?
    @Published var isLive = false
    @Published var lastPaymentAt: Date?
    @Published var lastError: String?

    private var pollTimer: Timer?
    private var bannerClearTask: Task<Void, Never>?
    private var knownIds = Set<String>()
    private var didInitialLoad = false

    private let baseToday = 1053.0
    private let baseMonth = 18430.0
    private let baseMRR = 6420.0

    private init() {
        // Drop legacy insecure secret storage; keys live in Keychain only now.
        if UserDefaults.standard.object(forKey: "stripeKey") != nil {
            UserDefaults.standard.removeObject(forKey: "stripeKey")
        }
        // Load multi-provider set; migrate legacy single value in.
        let savedIds = (UserDefaults.standard.stringArray(forKey: Self.providersDefaultsKey) ?? [])
            .filter { RevenueProviderRegistry.provider(for: $0) != nil }
        if !savedIds.isEmpty {
            connectedProviderIds = Set(savedIds)
            // Complete migration: drop legacy single key if it lingers.
            if UserDefaults.standard.object(forKey: Self.providerDefaultsKey) != nil {
                UserDefaults.standard.removeObject(forKey: Self.providerDefaultsKey)
            }
        } else if let saved = UserDefaults.standard.string(forKey: Self.providerDefaultsKey),
            RevenueProviderRegistry.provider(for: saved) != nil {
            connectedProviderIds = [saved]
            persistIds()
            UserDefaults.standard.removeObject(forKey: Self.providerDefaultsKey)
        }
        if !connectedProviderIds.isEmpty {
            let seed = connectedProviderIds.sorted()
                .flatMap { MockPayments.ledger(for: $0) }
                .sorted { $0.timestamp > $1.timestamp }
            payments = seed
            knownIds = Set(seed.map(\.id))
            didInitialLoad = true
            lastPaymentAt = seed.first?.timestamp
            isLive = true
        }
        startPolling()
        Task { [weak self] in await self?.refresh() }
    }

    private func persistIds() {
        UserDefaults.standard.set(Array(connectedProviderIds).sorted(), forKey: Self.providersDefaultsKey)
    }

    // MARK: - Derived

    var connectedProviders: [any RevenueProvider] {
        connectedProviderIds.sorted().compactMap { RevenueProviderRegistry.provider(for: $0) }
    }

    var connectedProviderNames: String {
        connectedProviders.map(\.name).joined(separator: ", ")
    }

    var recentPayments: [Payment] {
        payments.sorted { $0.timestamp > $1.timestamp }
    }

    var todayTotal: Double {
        guard !payments.isEmpty else { return baseToday }
        return payments.filter { Calendar.current.isDateInToday($0.timestamp) }
            .reduce(0) { $0 + $1.amount }
    }

    var monthTotal: Double {
        guard !payments.isEmpty else { return baseMonth }
        let cal = Calendar.current
        let now = Date()
        return payments.filter { cal.isDate($0.timestamp, equalTo: now, toGranularity: .month) }
            .reduce(0) { $0 + $1.amount }
    }

    var mrr: Double {
        guard !payments.isEmpty else { return baseMRR }
        let monthAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date.distantPast
        let subs = payments.filter { $0.isSubscriptionLike && $0.timestamp >= monthAgo }
        guard !subs.isEmpty else { return max(500, monthTotal * 0.35) }
        return subs.reduce(0) { $0 + $1.amount }
    }

    var lastPaymentAgo: String {
        guard let t = lastPaymentAt else { return "no sales yet" }
        let s = max(0, Int(Date().timeIntervalSince(t)))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }

    /// In-memory key cache: Keychain is touched at most ONCE per provider per
    /// process. Without this, every rebuild (new ad-hoc identity) re-prompts,
    /// and a Deny would nag on every 30s poll. Cache holds even "" results.
    private var keyCache: [String: String] = [:]

    private func key(for providerId: String) -> String {
        if let cached = keyCache[providerId] { return cached }
        let loaded = KeychainHelper.load(account: providerId) ?? ""
        keyCache[providerId] = loaded
        return loaded
    }

    // MARK: - Actions (called from UI on the main thread)

    /// Key goes to Keychain ONLY; only provider ids are persisted in UserDefaults.
    /// Adds to the connected set (multi-connect).
    func connect(providerId: String, key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { lastError = "Paste a key first."; return }
        guard RevenueProviderRegistry.provider(for: providerId) != nil else { lastError = "Unknown provider."; return }
        KeychainHelper.save(trimmed, account: providerId)
        keyCache[providerId] = trimmed
        UserDefaults.standard.set(true, forKey: Self.hasKeyPrefix + providerId)
        lastError = nil
        connectedProviderIds.insert(providerId)
        persistIds()
        UserDefaults.standard.removeObject(forKey: Self.providerDefaultsKey)
        // Seed instantly so the UI isn't empty; refresh() reconciles with live data.
        // Merge: keep other providers' payments, (re)seed this provider without banner.
        let seed = MockPayments.ledger(for: providerId)
        let others = payments.filter { $0.provider != providerId }
        let merged = (others + seed).sorted { $0.timestamp > $1.timestamp }
        knownIds = Set(merged.map(\.id))
        payments = merged
        didInitialLoad = true
        lastPaymentAt = merged.first?.timestamp
        isLive = true
        Task { [weak self] in await self?.refresh() }
    }

    /// Removes ONE provider from the connected set.
    func disconnect(providerId: String) {
        KeychainHelper.delete(account: providerId)
        keyCache.removeValue(forKey: providerId)
        UserDefaults.standard.removeObject(forKey: Self.hasKeyPrefix + providerId)
        connectedProviderIds.remove(providerId)
        persistIds()
        payments = payments.filter { $0.provider != providerId }
        knownIds = Set(payments.map(\.id))
        if let b = banner, b.provider == providerId {
            bannerClearTask?.cancel()
            banner = nil
        }
        if connectedProviderIds.isEmpty {
            didInitialLoad = false
            bannerClearTask?.cancel()
            banner = nil
            isLive = false
            lastPaymentAt = nil
            lastError = nil
        } else {
            lastPaymentAt = payments.sorted { $0.timestamp > $1.timestamp }.first?.timestamp
            isLive = !payments.isEmpty
            lastError = nil
        }
    }

    /// Legacy: disconnect all.
    func disconnect() {
        for id in Array(connectedProviderIds) {
            KeychainHelper.delete(account: id)
            UserDefaults.standard.removeObject(forKey: Self.hasKeyPrefix + id)
        }
        keyCache.removeAll()
        connectedProviderIds = []
        persistIds()
        payments = []
        knownIds = []
        didInitialLoad = false
        bannerClearTask?.cancel()
        banner = nil
        isLive = false
        lastPaymentAt = nil
        lastError = nil
    }

    func refresh() async {
        let ids = connectedProviderIds.sorted()
        guard !ids.isEmpty else { return }
        // Snapshot for fallback on per-provider failure.
        let cached = await MainActor.run { self.payments }
        var aggregate: [Payment] = []
        var anyFailed = false
        for id in ids {
            guard let provider = RevenueProviderRegistry.provider(for: id) else { continue }
            // Keychain is touched ONLY for live-key providers with a real pasted key.
            // Everything else runs on mock data — zero password prompts, ever.
            let key: String
            if provider.usesLiveKey, UserDefaults.standard.bool(forKey: Self.hasKeyPrefix + provider.id) {
                key = self.key(for: provider.id)
            } else {
                key = ""
            }
            if key.isEmpty {
                // No key stored (or Keychain unavailable): offline-safe mock ledger.
                aggregate += MockPayments.ledger(for: provider.id)
                continue
            }
            do {
                let fetched = try await provider.fetchPayments(apiKey: key)
                aggregate += fetched
            } catch {
                anyFailed = true
                let slice = cached.filter { $0.provider == id }
                aggregate += slice.isEmpty ? MockPayments.ledger(for: id) : slice
            }
        }
        aggregate.sort { $0.timestamp > $1.timestamp }
        let finalAggregate = aggregate
        let failed = anyFailed
        await MainActor.run {
            if failed {
                self.lastError = "Fetch failed — showing cached data."
            } else {
                self.lastError = nil
            }
            self.ingest(finalAggregate)
        }
    }

    /// Demo path: inserts a mock payment and runs the exact live-banner flow.
    func simulateSale() {
        let providerId = connectedProviderIds.sorted().first ?? "stripe"
        let mock = MockPayments.singleMock(provider: providerId)
        knownIds.insert(mock.id)
        payments = ([mock] + payments).sorted { $0.timestamp > $1.timestamp }
        lastPaymentAt = mock.timestamp
        isLive = true
        showBanner(mock)
    }

    // MARK: - Private (main thread only)

    private func ingest(_ fetched: [Payment]) {
        guard !fetched.isEmpty else { return }
        let sorted = fetched.sorted { $0.timestamp > $1.timestamp }
        if !didInitialLoad {
            didInitialLoad = true
            knownIds = Set(sorted.map(\.id))
            payments = sorted
            lastPaymentAt = sorted.first?.timestamp
            isLive = true
            return
        }
        let fresh = sorted.filter { !knownIds.contains($0.id) }
        payments = sorted
        knownIds = Set(sorted.map(\.id))
        lastPaymentAt = sorted.first?.timestamp
        isLive = true
        if let newest = fresh.sorted(by: { $0.timestamp > $1.timestamp }).first {
            showBanner(newest)
        }
    }

    private func showBanner(_ payment: Payment) {
        banner = payment
        // Expand for the sale; remember prior state so we can collapse back.
        let wasExpanded = NotchManager.shared.isExpanded
        if !wasExpanded { NotchManager.shared.expand() }
        bannerClearTask?.cancel()
        bannerClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.banner?.id == payment.id { self.banner = nil }
                if !wasExpanded && NotchManager.shared.isExpanded {
                    NotchManager.shared.collapse()
                }
            }
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }
}
