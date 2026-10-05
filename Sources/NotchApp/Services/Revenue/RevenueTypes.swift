import Foundation

/// Normalized payment. UI only ever touches this — never provider SDK types.
struct Payment: Identifiable, Equatable, Sendable {
    let id: String
    let provider: String   // provider id, e.g. "stripe"
    let amount: Double
    let currency: String   // ISO code, e.g. "USD"
    let product: String
    let customer: String
    let timestamp: Date
    let status: String

    var formattedAmount: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: amount)) ?? "\(currency) \(amount)"
    }

    var isSubscriptionLike: Bool {
        let p = product.lowercased()
        return p.contains("subscription") || p.contains("plan") || p.contains("membership")
    }

    func agoString(now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(timestamp)))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }
}

protocol RevenueProvider: Sendable {
    var id: String { get }
    var name: String { get }
    /// Label for the credential field, e.g. "Restricted API key".
    var keyLabel: String { get }
    var keyPlaceholder: String { get }
    /// Which minimum / read-only credential to create in the provider dashboard.
    var keyHelp: String { get }
    func fetchPayments(apiKey: String) async throws -> [Payment]
    /// True only for adapters that actually call a live API with the key.
    /// Mock adapters never touch the Keychain — no password prompts, ever.
    var usesLiveKey: Bool { get }
}

extension RevenueProvider {
    var usesLiveKey: Bool { false }
}

enum RevenueError: Error {
    case missingKey
    case badURL
    case httpError
}
