import Foundation

// MARK: - Stripe (the one real path; offline-safe fallback to mock)

struct StripeProvider: RevenueProvider {
    let id = "stripe"
    let name = "Stripe"
    let keyLabel = "Restricted API key"
    let keyPlaceholder = "rk_live_…"
    let keyHelp = "Stripe Dashboard → Developers → API keys → create a restricted key with only Balance: Read / Charges: Read."
    var usesLiveKey: Bool { true }

    func fetchPayments(apiKey: String) async throws -> [Payment] {
        // Real path first; ANY failure (offline, bad key, non-200) falls back to mock.
        if let live = try? await fetchLive(apiKey: apiKey), !live.isEmpty {
            return live
        }
        return MockPayments.ledger(for: "stripe")
    }

    private func fetchLive(apiKey: String) async throws -> [Payment] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw RevenueError.missingKey }
        guard let url = URL(string: "https://api.stripe.com/v1/balance_transactions?limit=10") else {
            throw RevenueError.badURL
        }
        var req = URLRequest(url: url, timeoutInterval: 12)
        let basic = Data("\(key):".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw RevenueError.httpError }
        let list = try JSONDecoder().decode(StripeBalanceList.self, from: data)
        return list.data.map { txn in
            let product: String
            if let d = txn.txnDescription, !d.isEmpty { product = d } else { product = "Stripe payment" }
            return Payment(
                id: txn.id,
                provider: "stripe",
                amount: Double(txn.amount) / 100.0,
                currency: txn.currency.uppercased(),
                product: (txn.txnDescription?.isEmpty == false ? txn.txnDescription! : "Stripe payment"),
                customer: "Stripe customer",
                timestamp: Date(timeIntervalSince1970: txn.created),
                status: txn.status ?? "succeeded"
            )
        }
    }
}

private struct StripeBalanceList: Decodable, Sendable {
    let data: [StripeBalanceTxn]
}

private struct StripeBalanceTxn: Decodable, Sendable {
    let id: String
    let amount: Int // smallest currency unit (cents)
    let currency: String
    let created: TimeInterval
    let status: String?
    let txnDescription: String?
    enum CodingKeys: String, CodingKey {
        case id, amount, currency, created, status
        case txnDescription = "description"
    }
}

// MARK: - Mock-backed adapters (no real client-side integration yet)

struct PolarProvider: RevenueProvider {
    let id = "polar"
    let name = "Polar"
    let keyLabel = "Access token"
    let keyPlaceholder = "polar_…"
    let keyHelp = "Polar Settings → Tokens → create a read-only token (Products + Orders read)."
    func fetchPayments(apiKey: String) async throws -> [Payment] {
        // TODO(real): GET https://api.polar.sh/v1/orders with Bearer token, map to [Payment].
        return MockPayments.ledger(for: "polar")
    }
}

struct DodoProvider: RevenueProvider {
    let id = "dodo"
    let name = "Dodo Payments"
    let keyLabel = "API key (restricted)"
    let keyPlaceholder = "dodo_…"
    let keyHelp = "Dodo Dashboard → API keys → create a read-only key (Payments read)."
    func fetchPayments(apiKey: String) async throws -> [Payment] {
        // TODO(real): GET Dodo Payments payments endpoint with restricted key, map to [Payment].
        return MockPayments.ledger(for: "dodo")
    }
}

struct RazorpayProvider: RevenueProvider {
    let id = "razorpay"
    let name = "Razorpay"
    let keyLabel = "Key secret (read-only user)"
    let keyPlaceholder = "rzp_live_…"
    let keyHelp = "Razorpay → create a read-only IAM user/key with Payments: View only. Never paste a full-access secret."
    func fetchPayments(apiKey: String) async throws -> [Payment] {
        // TODO(real): GET https://api.razorpay.com/v1/payments with Basic auth, map to [Payment].
        return MockPayments.ledger(for: "razorpay")
    }
}

struct LemonSqueezyProvider: RevenueProvider {
    let id = "lemonsqueezy"
    let name = "Lemon Squeezy"
    let keyLabel = "API key (read-only)"
    let keyPlaceholder = "Paste API key…"
    let keyHelp = "Lemon Squeezy Settings → API → key with Orders + Subscriptions read."
    func fetchPayments(apiKey: String) async throws -> [Payment] {
        // TODO(real): GET https://api.lemonsqueezy.com/v1/orders with Bearer token, map to [Payment].
        return MockPayments.ledger(for: "lemonsqueezy")
    }
}

struct PaddleProvider: RevenueProvider {
    let id = "paddle"
    let name = "Paddle"
    let keyLabel = "API key (read-only)"
    let keyPlaceholder = "pdl_live_…"
    let keyHelp = "Paddle → Developer tools → API key with Transactions read-only."
    func fetchPayments(apiKey: String) async throws -> [Payment] {
        // TODO(real): GET https://api.paddle.com/transactions with Bearer token, map to [Payment].
        return MockPayments.ledger(for: "paddle")
    }
}

struct PayPalProvider: RevenueProvider {
    let id = "paypal"
    let name = "PayPal"
    let keyLabel = "Client secret (read-only app)"
    let keyPlaceholder = "Paste client secret…"
    let keyHelp = "PayPal Developer → App with read-only payment scopes. Paste the secret (stored in Keychain only)."
    func fetchPayments(apiKey: String) async throws -> [Payment] {
        // TODO(real): OAuth client-credentials → GET /v2/payments/captures, map to [Payment].
        return MockPayments.ledger(for: "paypal")
    }
}

struct GumroadProvider: RevenueProvider {
    let id = "gumroad"
    let name = "Gumroad"
    let keyLabel = "Access token (read-only)"
    let keyPlaceholder = "Paste access token…"
    let keyHelp = "Gumroad Settings → Advanced → create a token with sales read scope."
    func fetchPayments(apiKey: String) async throws -> [Payment] {
        // TODO(real): GET Gumroad sales endpoint with access token, map to [Payment].
        return MockPayments.ledger(for: "gumroad")
    }
}

// MARK: - Registry

enum RevenueProviderRegistry {
    static let all: [any RevenueProvider] = [
        StripeProvider(),
        PolarProvider(),
        DodoProvider(),
        RazorpayProvider(),
        LemonSqueezyProvider(),
        PaddleProvider(),
        PayPalProvider(),
        GumroadProvider()
    ]

    static func provider(for id: String) -> (any RevenueProvider)? {
        all.first { $0.id == id }
    }
}

// MARK: - Realistic mock data (offline-safe)

enum MockPayments {
    /// Deterministic ~30-day ledger per provider so totals look real and
    /// re-polls return stable ids (no phantom "new payment" banners).
    static func ledger(for provider: String) -> [Payment] {
        let now = Date()
        let cal = Calendar.current
        let usd: [Double] = [49, 19, 99, 49, 149, 29, 249, 99, 49, 999, 19, 79, 39, 299, 149]
        let inr: [Double] = [3999, 999, 7999, 3999, 11999, 1999, 19999, 7999, 3999, 79999, 999, 5999, 2999, 23999, 11999]
        let products = ["Pro subscription", "Starter plan", "Team plan", "Pro subscription",
                        "Scale plan", "Add-on: extra seats", "Lifetime deal", "Team plan",
                        "Pro subscription", "Enterprise invoice", "Starter plan", "Pro subscription",
                        "Scale plan", "Add-on: priority support", "Team plan"]
        let customers = ["acme.co", "hobby dev", "indie hacker", "saas co", "design agency",
                         "fintech startup", "creator", "devtools inc"]
        let currency = provider == "razorpay" ? "INR" : "USD"
        let amounts = provider == "razorpay" ? inr : usd
        var out: [Payment] = []
        let count = 42
        for i in 0..<count {
            // First few land today so "Today" is non-zero; rest spread over ~30 days.
            let dayOffset = i < 4 ? 0 : (i * 30) / count
            let hourJitter = (i * 37) % 14
            let minuteJitter = (i * 53) % 60
            var ts = cal.date(byAdding: .day, value: -dayOffset, to: now) ?? now
            ts = cal.date(byAdding: .hour, value: -hourJitter, to: ts) ?? ts
            ts = cal.date(byAdding: .minute, value: -minuteJitter, to: ts) ?? ts
            if ts > now { ts = now }
            out.append(Payment(
                id: "\(provider)-mock-\(i)",
                provider: provider,
                amount: amounts[i % amounts.count],
                currency: currency,
                product: products[i % products.count],
                customer: customers[i % customers.count],
                timestamp: ts,
                status: "succeeded"
            ))
        }
        return out.sorted { $0.timestamp > $1.timestamp }
    }

    /// Fresh unique payment for the Simulate sale demo button.
    static func singleMock(provider: String) -> Payment {
        let options: [(Double, String)] = [(49, "Pro subscription"), (29, "Starter plan"), (99, "Team plan"), (149, "Scale plan")]
        let pick = options[Int(Date().timeIntervalSince1970) % options.count]
        return Payment(
            id: "\(provider)-demo-\(UUID().uuidString.prefix(8))",
            provider: provider,
            amount: pick.0,
            currency: provider == "razorpay" ? "INR" : "USD",
            product: pick.1,
            customer: "Demo customer",
            timestamp: Date(),
            status: "succeeded"
        )
    }
}
