import SwiftUI
import Charts

// MARK: Revenue (read-only keys, Keychain only, local only)
struct RevenueTool: View {
    @ObservedObject private var store = RevenueStore.shared
    @State private var selectedProviderId: String?
    @State private var keyInput = ""
    @State private var showKeyError = false
    @State private var showingAddMore = false

    var body: some View {
        if showingAddMore {
            addMoreView
        } else if store.connectedProviderIds.isEmpty {
            emptyState
        } else {
            connected
        }
    }

    // MARK: Empty — no provider yet: payments live here once connected
    private var emptyState: some View {
        ToolContainer("Revenue", subtitle: "Your payments will appear here") {
            VStack(spacing: 10) {
                Spacer()
                Text("No provider added yet")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Button("Add Provider") {
                    showingAddMore = true
                    selectedProviderId = nil
                    keyInput = ""
                    showKeyError = false
                }
                .buttonStyle(.borderedProminent).controlSize(.regular)
                Spacer()
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: Add-more (provider list + back — the page in the screenshot)
    private var addMoreView: some View {
        ToolContainer("Revenue", subtitle: "Add provider — read-only, stays on your Mac") {
            VStack(spacing: 6) {
                HStack {
                    Button(store.connectedProviderIds.isEmpty ? "< Back" : "< Revenue") {
                        showingAddMore = false
                        selectedProviderId = nil
                        keyInput = ""
                        showKeyError = false
                    }.controlSize(.small).foregroundStyle(.secondary)
                    Spacer()
                }
                providerList
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// Form/detail pinned INSIDE the list under its own row — no layout
    /// can ever strand it at the bottom again.
    @ViewBuilder
    private func selectedExpansion(for p: any RevenueProvider) -> some View {
        if store.connectedProviderIds.contains(p.id) {
            connectedDetail(p)
        } else {
            connectForm(p)
        }
    }

    private var providerList: some View {
        List {
            ForEach(RevenueProviderRegistry.all, id: \.id) { p in
                let isConnected = store.connectedProviderIds.contains(p.id)
                HStack(spacing: 8) {
                    Text(String(p.name.prefix(1)))
                        .font(.caption2).bold()
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                    Text(p.name).font(.callout).lineLimit(1)
                    Spacer()
                    if isConnected {
                        Text("Connected ••••").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedProviderId = (selectedProviderId == p.id) ? nil : p.id
                    keyInput = ""
                    showKeyError = false
                }
                .listRowBackground(selectedProviderId == p.id ? Color.white.opacity(0.08) : Color.clear)
                if selectedProviderId == p.id {
                    selectedExpansion(for: p)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8))
                }
            }
            HStack(spacing: 8) {
                Text("+")
                    .font(.caption2).bold()
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Circle())
                Text("More").font(.callout).lineLimit(1)
                Spacer()
                Text("soon").font(.caption2).foregroundStyle(.secondary)
            }
            .opacity(0.5)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .frame(maxHeight: .infinity)
    }

    private func connectForm(_ p: any RevenueProvider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(p.name).font(.caption).bold()
            Text(p.keyHelp).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(p.keyLabel).font(.caption2).foregroundStyle(.secondary)
            SecureField(p.keyPlaceholder, text: $keyInput).textFieldStyle(.roundedBorder).controlSize(.small)
            if showKeyError {
                Text("Paste a key first.").font(.caption2).foregroundColor(.red)
            }
            HStack {
                Button("Save") {
                    if keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        showKeyError = true
                        return
                    }
                    store.connect(providerId: p.id, key: keyInput)
                    keyInput = ""
                    showKeyError = false
                    selectedProviderId = nil
                    showingAddMore = false
                }.buttonStyle(.borderedProminent).controlSize(.small)
                Button("Cancel") {
                    selectedProviderId = nil
                    keyInput = ""
                    showKeyError = false
                }.controlSize(.small)
            }
            Text("Read-only key — stored in Keychain, never leaves your Mac.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8).background(Color.white.opacity(0.05)).cornerRadius(8)
    }

    private func connectedDetail(_ p: any RevenueProvider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(p.name).font(.caption).bold()
            Text("Connected •••• — key in Keychain.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("Disconnect") {
                    store.disconnect(providerId: p.id)
                    selectedProviderId = nil
                    keyInput = ""
                    showKeyError = false
                    if store.connectedProviderIds.isEmpty {
                        showingAddMore = false
                    }
                }.controlSize(.small).foregroundStyle(.secondary)
            }
            Text("Read-only key — stored in Keychain, never leaves your Mac.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8).background(Color.white.opacity(0.05)).cornerRadius(8)
    }

    // MARK: Connected dashboard (first)
    private var connected: some View {
        ToolContainer("Revenue", subtitle: "Connected •••• — read-only, stays on your Mac") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(store.connectedProviderNames).font(.caption).bold().lineLimit(1)
                    Spacer()
                    Button("+ ADD MORE") {
                        showingAddMore = true
                        selectedProviderId = nil
                        keyInput = ""
                        showKeyError = false
                    }
                    .controlSize(.mini)
                }
                HStack(spacing: 0) {
                    stat(title: "Today", value: money(store.todayTotal))
                    stat(title: "This month", value: money(store.monthTotal))
                    stat(title: "MRR", value: money(store.mrr))
                }
                .padding(.vertical, 6).padding(.horizontal, 4)
                .background(Color.white.opacity(0.05)).cornerRadius(8)
                HStack(spacing: 6) {
                    Circle().fill(store.isLive ? Color.green : Color.gray).frame(width: 6, height: 6)
                    Text(store.isLive ? "Live" : "Offline").font(.caption2).foregroundStyle(.secondary)
                    Text("· Last payment \(store.lastPaymentAgo)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Simulate sale") { store.simulateSale() }.controlSize(.mini)
                }
                Text("Recent payments").font(.caption2).bold().foregroundStyle(.secondary)
                // Bounded internal scroll — never touches the bottom icon bar.
                if store.recentPayments.isEmpty {
                    Text("No payments yet — new sales land here.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    List(store.recentPayments.prefix(30)) { pay in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(pay.product).font(.caption).lineLimit(1)
                                Text("\(pay.customer) · \(RevenueProviderRegistry.provider(for: pay.provider)?.name ?? pay.provider) · \(pay.agoString())")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(pay.formattedAmount).font(.caption).bold()
                        }
                        .contentShape(Rectangle())
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func stat(title: String, value: String) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout).bold().lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = v >= 1000 ? 0 : 2
        return f.string(from: NSNumber(value: v)) ?? "$\(v)"
    }
}

// MARK: Claude usage
struct ClaudeTool: View {
    @State private var info = "Scanning ~/.claude/projects..."
    var body: some View {
        ToolContainer("Claude Code", subtitle: "Tokens, sessions, streaks") {
            Text(info).font(.caption).foregroundStyle(.secondary).onAppear { scan() }
            HStack {
                VStack { Text("655M").bold(); Text("tokens").font(.caption) }
                Spacer()
                VStack { Text("15").bold(); Text("day streak").font(.caption) }
                Spacer()
                VStack { Text("128").bold(); Text("tool calls").font(.caption) }
                Spacer()
                Button("Rescan") { scan() }.controlSize(.small)
            }.padding().background(.ultraThinMaterial).cornerRadius(12)
        }
    }
    func scan() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".claude/projects")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            info = "No ~/.claude/projects found — showing demo numbers."
            return
        }
        info = "Found \(files.count) project folders in ~/.claude/projects"
    }
}
