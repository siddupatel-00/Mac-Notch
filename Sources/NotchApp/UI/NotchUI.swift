import SwiftUI

struct NotchRootView: View {
    @EnvironmentObject var manager: NotchManager
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        // No global .animation here on purpose: the window frame is set instantly in
        // AppKit and only the content animates. A root-level animation + window
        // frame animation together is what made it grow from the middle and stutter.
        VStack(spacing: 0) {
            if manager.isExpanded {
                ExpandedView()
                    // Fill the AppKit window; never pin a fixed width/height here.
                    // A fixed .frame(width: panelWidth, height:) becomes a required
                    // Auto Layout constraint in NSHostingView that blocks live
                    // shrink (window can't go smaller than the old larger value).
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.background)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: manager.isFullscreen ? 0 : 22, bottomTrailingRadius: manager.isFullscreen ? 0 : 22, topTrailingRadius: 0))
                    .overlay(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: manager.isFullscreen ? 0 : 22, bottomTrailingRadius: manager.isFullscreen ? 0 : 22, topTrailingRadius: 0).stroke(Color.white.opacity(0.15), lineWidth: 1))
                    .shadow(radius: 30)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    // No onHover close here on purpose: the enter-transition hover
                    // state is unstable and blink-looped with the close timer.
                    // Mouse polling in NotchManager is the single source of truth.
            } else {
                // Invisible catcher over hardware notch: zero visuals, instant hover + click.
                // Clear (not black) = no dummy notch in photos or screenshots.
                Color.clear
                    .frame(width: manager.collapsedWidth, height: manager.collapsedHeight)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { manager.scheduleOpen() } else { manager.cancelHover() }
                    }
                    .onTapGesture { manager.expand() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: manager.isExpanded)
    }
}

struct ExpandedView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var manager: NotchManager
    @ObservedObject private var revenue = RevenueStore.shared

    var visibleTools: [ToolDef] {
        ToolRegistry.all.filter { settings.isEnabled($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(settings.selectedTool == "home"
                     ? "Notch"
                     : (ToolRegistry.all.first(where: { $0.id == settings.selectedTool })?.name ?? "Notch"))
                    .bold().foregroundColor(theme.accent)
                Spacer()
                Button(action: { manager.resetSize() }) {
                    Image(systemName: "arrow.counterclockwise").foregroundColor(.secondary)
                }.buttonStyle(.plain).help("Reset to small size")
                Button(action: { manager.toggleFullscreen() }) {
                    Image(systemName: manager.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").foregroundColor(.secondary)
                }.buttonStyle(.plain)
                Button(action: { manager.collapse() }) {
                    Image(systemName: "chevron.up").foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }.padding(.horizontal).padding(.top, 10)

            // Live sale banner (additive): shows on new payments, auto-clears in RevenueStore.
            if let sale = revenue.banner {
                LiveSaleBanner(payment: sale)
                    .padding(.horizontal)
                    .padding(.top, 6)
            }

            // Content
            Group {
                switch settings.selectedTool {
                case "home": HomeTool()
                case "music": MusicTool()
                case "revenue": RevenueTool()
                case "scratchpad": ScratchpadTool()
                case "shelf": ShelfTool()
                case "calendar": CalendarTool()
                case "timers": TimersTool()
                case "stats": StatsTool()
                case "screentime": ScreenTimeTool()
                case "weather": WeatherTool()
                case "clipboard": ClipboardTool()
                case "notes": NotesTool()
                case "files": FilesTool()
                case "links": LinksTool()
                case "emoji": EmojiTool()
                case "sounds": SoundsTool()
                case "message": MessageTool()
                case "claude": ClaudeTool()
                case "units": UnitsTool()
                default: HomeTool()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundColor(theme.current == .minimal ? .white : .primary)

            // Icon bar — centered when it fits (fullscreen), scrollable when it overflows
            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(visibleTools) { t in
                            Button(action: { settings.selectedTool = t.id }) {
                                VStack(spacing: 2) {
                                    Image(systemName: t.icon).font(.system(size: 14))
                                    Text(t.name).font(.system(size: 8))
                                }
                                .frame(width: 52, height: 44)
                                .background(settings.selectedTool == t.id ? theme.accent.opacity(0.25) : Color.white.opacity(0.06))
                                .cornerRadius(10)
                                .foregroundColor(theme.accent)
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .frame(minWidth: geo.size.width, alignment: .center)
                }
            }
            .frame(height: 54)
            .padding(.bottom, 10)
        }
        .onChange(of: revenue.banner?.id) { _, newId in
            if newId != nil { manager.expand() }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var theme: ThemeManager
    var body: some View {
        ScrollView {
            Form {
                Section("Behavior") {
                    Toggle("Hover to open", isOn: $settings.hoverToOpen)
                    Slider(value: $settings.hoverDelay, in: 0...0.3, step: 0.01) { Text("Open delay: \(settings.hoverDelay, specifier: "%.2f")s (0 = instant)") }
                    Toggle("Close when mouse leaves", isOn: $settings.autoCloseOnLeave)
                    Toggle("Close on outside click", isOn: $settings.outsideClickToClose)
                    Toggle("Hide on fullscreen", isOn: $settings.hideOnFullscreen)
                    Toggle("Simulated notch (no-notch Macs)", isOn: $settings.simulateNotch)
                    Picker("Collapsed shows", selection: $settings.collapsedMode) {
                        Text("Hidden").tag("Hidden")
                        Text("Clock").tag("Clock")
                        Text("Message").tag("Message")
                        Text("Revenue").tag("Revenue")
                        Text("Visitors").tag("Visitors")
                    }
                }
                Section("Theme") {
                    Picker("Theme", selection: $theme.current) {
                        ForEach(AppTheme.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                }
                Section("Tools (\(ToolRegistry.all.count))") {
                    ForEach(ToolRegistry.all) { t in
                        Toggle(t.name, isOn: Binding(
                            get: { settings.isEnabled(t.id) },
                            set: { _ in settings.toggle(t.id) }
                        ))
                    }
                }
            }.padding(20)
        }.frame(width: 420, height: 560)
    }
}

/// Top overlay for new payments. Additive — nothing else in NotchUI changed.
struct LiveSaleBanner: View {
    let payment: Payment

    var body: some View {
        HStack(spacing: 10) {
            Text("💰").font(.title2)
            VStack(alignment: .leading, spacing: 1) {
                Text("NEW PAYMENT").font(.caption2).bold().foregroundColor(.green)
                Text(payment.formattedAmount).font(.headline).bold().foregroundColor(.white)
                Text("\(payment.product) · \(payment.agoString())")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.green.opacity(0.12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.35), lineWidth: 1))
        .cornerRadius(12)
    }
}
