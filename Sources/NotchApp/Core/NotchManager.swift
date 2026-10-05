import AppKit
import SwiftUI

/// Single owner of notch window state.
/// Rules for glitch-free behavior:
/// - Window frame is set INSTANTLY (no AppKit animate). SwiftUI content animates instead.
/// - Collapsed = window hidden entirely (real notch has no pixels).
/// - One mouse poller (0.15s) + hysteresis. No competing SwiftUI onHover open timers.
/// - Outside-click monitors installed ONCE, with open-grace so the opening click can't instantly close.
final class NotchManager: ObservableObject {
    static let shared = NotchManager()

    @Published var isExpanded = false
    @Published var hasNotch = true
    @Published var isFullscreen = false

    @Published var panelWidth: CGFloat = 760
    @Published var expandedHeight: CGFloat = 440
    let collapsedWidth: CGFloat = 200
    let collapsedHeight: CGFloat = 32

    /// Hover strip over the real camera housing (top-center only).
    /// Full menu-bar height so any touch of the notch triggers — milliseconds.
    let hotZoneWidth: CGFloat = 210
    let hotZoneHeight: CGFloat = 32
    var autoCloseDelay: Double = 0.45

    private var panel: NotchPanel?
    private var hosting: NSView?
    private var alertPanel: NotchPanel?
    private var openTimer: Timer?
    private var closeTimer: Timer?
    private var pollTimer: Timer?
    private var outsideTokens: [Any] = []
    private var resignObserver: Any?
    private var resizeObserver: Any?
    private var lastExpandAt = Date.distantPast
    private var outsideStrikes = 0
    private var didInstallMonitors = false
    private var isSettingFrame = false
    private var preFullscreenSize: CGSize?
    private let panelWidthKey = "notch.panelWidth"
    private let panelHeightKey = "notch.panelHeight"
    private let minPanelWidth: CGFloat = 520
    private let minPanelHeight: CGFloat = 340

    // MARK: Setup
    func setup() {
        loadPersistedSize()
        detectNotch()
        createPanel()
        installOutsideMonitorsOnce()
        startPolling()
    }

    func detectNotch() {
        if let screen = NSScreen.main, #available(macOS 14.0, *) {
            hasNotch = screen.safeAreaInsets.top > 0
        }
        if SettingsStore.shared.simulateNotch { hasNotch = true }
    }

    private func mainScreen() -> NSScreen? { NSScreen.main }

    private func loadPersistedSize() {
        let w = UserDefaults.standard.double(forKey: panelWidthKey)
        let h = UserDefaults.standard.double(forKey: panelHeightKey)
        if w > 0 { panelWidth = CGFloat(w) }
        if h > 0 { expandedHeight = CGFloat(h) }
        let clamped = clampSize(CGSize(width: panelWidth, height: expandedHeight))
        panelWidth = clamped.width
        expandedHeight = clamped.height
    }

    private func persistSize() {
        UserDefaults.standard.set(Double(panelWidth), forKey: panelWidthKey)
        UserDefaults.standard.set(Double(expandedHeight), forKey: panelHeightKey)
    }

    private func clampSize(_ size: CGSize) -> CGSize {
        var w = max(minPanelWidth, size.width)
        var h = max(minPanelHeight, size.height)
        if let screen = mainScreen() {
            // Cap below full screen so the bottom edge is ALWAYS grabbable.
            // A taller panel strands its resize edge off-screen = stuck giant.
            w = min(w, screen.frame.width * 0.9)
            h = min(h, screen.frame.height * 0.75)
        }
        return CGSize(width: w, height: h)
    }

    private func setFrameProgrammatic(_ frame: NSRect) {
        guard let panel else { return }
        isSettingFrame = true
        panel.setFrame(frame, display: false)
        hosting?.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height)
        isSettingFrame = false
    }

    func createPanel() {
        guard let screen = mainScreen() else { return }
        let clamped = clampSize(CGSize(width: panelWidth, height: expandedHeight))
        panelWidth = clamped.width
        expandedHeight = clamped.height
        // Start as invisible click-catcher over the real notch (no black = no dummy).
        let catcher = NSRect(
            x: screen.frame.midX - collapsedWidth / 2,
            y: screen.frame.maxY - collapsedHeight,
            width: collapsedWidth,
            height: collapsedHeight
        )
        let p = NotchPanel(contentRect: catcher)
        let root = NotchRootView()
            .environmentObject(SettingsStore.shared)
            .environmentObject(ThemeManager.shared)
            .environmentObject(self)
        let hv = NSHostingView(rootView: root)
        hv.autoresizingMask = [.width, .height]
        hv.frame = NSRect(x: 0, y: 0, width: collapsedWidth, height: collapsedHeight)
        p.contentView = hv
        hosting = hv
        panel = p
        p.minSize = NSSize(width: minPanelWidth, height: minPanelHeight)
        p.maxSize = NSSize(width: screen.frame.width * 0.9, height: screen.frame.height * 0.75)
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: p, queue: nil
        ) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            if self.isSettingFrame || self.isFullscreen || !self.isExpanded { return }
            guard let screen = self.mainScreen() else { return }
            let clamped = self.clampSize(panel.frame.size)
            // Live drag-resize keeps origin fixed, so re-center x and pin y to screen top.
            let centeredX = screen.frame.midX - clamped.width / 2
            let topY = screen.frame.maxY - clamped.height
            if abs(panel.frame.minX - centeredX) > 0.5
                || abs(panel.frame.minY - topY) > 0.5
                || abs(panel.frame.width - clamped.width) > 0.5
                || abs(panel.frame.height - clamped.height) > 0.5 {
                self.isSettingFrame = true
                panel.setFrame(NSRect(x: centeredX, y: topY, width: clamped.width, height: clamped.height), display: true)
                self.hosting?.frame = NSRect(x: 0, y: 0, width: clamped.width, height: clamped.height)
                self.isSettingFrame = false
            } else {
                self.hosting?.frame = NSRect(x: 0, y: 0, width: panel.frame.width, height: panel.frame.height)
            }
            if abs(clamped.width - self.panelWidth) > 0.5 || abs(clamped.height - self.expandedHeight) > 0.5 {
                self.panelWidth = clamped.width
                self.expandedHeight = clamped.height
                self.persistSize()
            }
        }
        // Visible but fully transparent catcher over hardware notch:
        // invisible (no dummy), yet hover + click land on us instantly.
        p.orderFrontRegardless()
    }

    // MARK: State machine (main thread only)
    func expand() {
        guard !isExpanded, let screen = mainScreen() else { return }
        // Ignore stale open timer fired after user already moved away
        openTimer?.invalidate(); openTimer = nil
        closeTimer?.invalidate(); closeTimer = nil
        outsideStrikes = 0
        let clamped = clampSize(CGSize(width: panelWidth, height: expandedHeight))
        panelWidth = clamped.width
        expandedHeight = clamped.height
        let frame = NSRect(
            x: screen.frame.midX - clamped.width / 2,
            y: screen.frame.maxY - clamped.height,
            width: clamped.width,
            height: clamped.height
        )
        // Instant frame set — SwiftUI content does the visual animation.
        setFrameProgrammatic(frame)
        panel?.orderFrontRegardless()
        panel?.makeKey()
        lastExpandAt = Date()
        isExpanded = true
    }

    func collapse() {
        guard isExpanded, let screen = mainScreen() else { return }
        openTimer?.invalidate(); openTimer = nil
        closeTimer?.invalidate(); closeTimer = nil
        outsideStrikes = 0
        if isFullscreen {
            isFullscreen = false
            if let prev = preFullscreenSize {
                let clamped = clampSize(prev)
                panelWidth = clamped.width
                expandedHeight = clamped.height
                persistSize()
            }
            preFullscreenSize = nil
        }
        isExpanded = false
        panel?.resignKey()
        // Back to invisible catcher over real notch (never orderOut — else nothing to click)
        let catcher = NSRect(
            x: screen.frame.midX - collapsedWidth / 2,
            y: screen.frame.maxY - collapsedHeight,
            width: collapsedWidth,
            height: collapsedHeight
        )
        setFrameProgrammatic(catcher)
        panel?.orderFrontRegardless()
    }

    func toggleFullscreen() {
        guard isExpanded, let screen = mainScreen() else { return }
        if isFullscreen {
            isFullscreen = false
            if let prev = preFullscreenSize {
                let clamped = clampSize(prev)
                panelWidth = clamped.width
                expandedHeight = clamped.height
                persistSize()
                let frame = NSRect(
                    x: screen.frame.midX - clamped.width / 2,
                    y: screen.frame.maxY - clamped.height,
                    width: clamped.width,
                    height: clamped.height
                )
                setFrameProgrammatic(frame)
            }
            preFullscreenSize = nil
        } else {
            preFullscreenSize = CGSize(width: panelWidth, height: expandedHeight)
            isFullscreen = true
            cancelClose()
            outsideStrikes = 0
            let f = screen.frame
            panelWidth = f.width
            expandedHeight = f.height
            setFrameProgrammatic(f)
            panel?.orderFrontRegardless()
            panel?.makeKey()
        }
    }

    func toggle() { isExpanded ? collapse() : expand() }

    // MARK: Tiny alert pill (timer done / alarm) — no full-panel takeover
    func showAlert() {
        guard let screen = mainScreen() else { return }
        let w: CGFloat = 360, h: CGFloat = 64
        let frame = NSRect(
            x: screen.frame.midX - w / 2,
            y: screen.frame.maxY - collapsedHeight - h - 6,
            width: w, height: h
        )
        if alertPanel == nil {
            let p = NotchPanel(contentRect: frame)
            let hv = NSHostingView(rootView: AlertPillView())
            hv.autoresizingMask = [.width, .height]
            hv.frame = NSRect(x: 0, y: 0, width: w, height: h)
            p.contentView = hv
            alertPanel = p
        } else {
            alertPanel?.setFrame(frame, display: true)
        }
        alertPanel?.orderFrontRegardless()
    }

    func hideAlert() {
        alertPanel?.orderOut(nil)
    }

    /// Back to the small default size (exits fullscreen first if active).
    func resetSize() {
        guard isExpanded, let screen = mainScreen() else { return }
        isFullscreen = false
        preFullscreenSize = nil
        panelWidth = 760
        expandedHeight = 440
        persistSize()
        let frame = NSRect(
            x: screen.frame.midX - panelWidth / 2,
            y: screen.frame.maxY - expandedHeight,
            width: panelWidth,
            height: expandedHeight
        )
        setFrameProgrammatic(frame)
    }

    // MARK: Open / close scheduling
    /// No automatic close is allowed this long after opening — the enter
    /// transition + first hover events are unstable and used to blink-loop.
    /// (Explicit user closes — outside click, chevron, ESC — bypass this.)
    private let openGrace: TimeInterval = 0.8

    private func autoCollapse() {
        guard Date().timeIntervalSince(lastExpandAt) > openGrace else { return }
        collapse()
    }

    private func hotRect(in screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.midX - hotZoneWidth / 2,
            y: screen.frame.maxY - hotZoneHeight,
            width: hotZoneWidth,
            height: hotZoneHeight
        )
    }

    func scheduleOpen() {
        guard SettingsStore.shared.hoverToOpen, !isExpanded, openTimer == nil,
              let screen = mainScreen() else { return }
        // Zero-delay fast path: hoverDelay 0.05 feels instant but still debounces fly-bys
        let delay = max(0.0, SettingsStore.shared.hoverDelay)
        if delay <= 0.001 {
            if hotRect(in: screen).contains(NSEvent.mouseLocation) { expand() }
            return
        }
        let zone = hotRect(in: screen)
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.openTimer = nil
            // Fly-by guard: only open if the mouse is STILL in the hot zone.
            // Without this, fast passes flash the panel open after leaving.
            guard zone.contains(NSEvent.mouseLocation) else { return }
            self?.expand()
        }
        openTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    func cancelOpen() { openTimer?.invalidate(); openTimer = nil }

    func scheduleClose() {
        guard SettingsStore.shared.autoCloseOnLeave, isExpanded, !isFullscreen, closeTimer == nil,
              Date().timeIntervalSince(lastExpandAt) > openGrace else { return }
        let t = Timer(timeInterval: autoCloseDelay, repeats: false) { [weak self] _ in
            self?.closeTimer = nil
            self?.autoCollapse()
        }
        closeTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    func cancelClose() { closeTimer?.invalidate(); closeTimer = nil }

    // MARK: Outside click (installed once)
    private func installOutsideMonitorsOnce() {
        guard !didInstallMonitors else { return }
        didInstallMonitors = true
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            // Grace: the click that opened must not instantly close
            guard self.isExpanded,
                  SettingsStore.shared.outsideClickToClose,
                  Date().timeIntervalSince(self.lastExpandAt) > 0.35,
                  let panel = self.panel else { return event }
            if !panel.frame.contains(NSEvent.mouseLocation) {
                DispatchQueue.main.async { self.collapse() }
            }
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.isExpanded,
                  SettingsStore.shared.outsideClickToClose,
                  Date().timeIntervalSince(self.lastExpandAt) > 0.35 else { return }
            DispatchQueue.main.async { self.collapse() }
        }
        if let local { outsideTokens.append(local) }
        if let global { outsideTokens.append(global) }
        let esc = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if self.isFullscreen && self.isExpanded && event.keyCode == 53 {
                DispatchQueue.main.async { self.toggleFullscreen() }
                return nil
            }
            return event
        }
        if let esc { outsideTokens.append(esc) }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.isExpanded,
                  (note.object as? NSWindow) === self.panel,
                  SettingsStore.shared.outsideClickToClose,
                  Date().timeIntervalSince(self.lastExpandAt) > 0.6 else { return }
            self.collapse()
        }
    }

    // MARK: Mouse polling with hysteresis
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let t = pollTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func tick() {
        guard let screen = mainScreen() else { return }
        let mouse = NSEvent.mouseLocation
        // Only the built-in screen's notch opens it — never middle of an external display
        guard screen.frame.contains(mouse) || !isExpanded else {
            // Mouse on another display while expanded: leave open, don't glitch-jump
            return
        }
        if !isExpanded {
            if hotRect(in: screen).contains(mouse) { scheduleOpen() } else { cancelOpen() }
        } else {
            guard let panel else { return }
            if isFullscreen { outsideStrikes = 0; cancelClose(); return }
            // Open-grace: ignore leave-events right after opening (transition
            // hover is unstable and used to blink-loop open/close).
            if Date().timeIntervalSince(lastExpandAt) < openGrace {
                outsideStrikes = 0
                cancelClose()
                return
            }
            // Hysteresis: require 3 straight outside polls (~0.45s) before closing
            if panel.frame.insetBy(dx: -24, dy: -24).contains(mouse) {
                outsideStrikes = 0
                cancelClose()
            } else {
                outsideStrikes += 1
                if outsideStrikes >= 3 { outsideStrikes = 0; autoCollapse() }
            }
        }
    }

    // Compat shims (old UI calls these)
    func cancelHover() { cancelOpen() }
    func scheduleAutoCollapse(delay: Double? = nil) { scheduleClose() }
    func cancelAutoCollapse() { cancelClose() }
}
