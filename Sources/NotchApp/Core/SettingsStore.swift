import SwiftUI

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var hoverDelay: Double = 0.05 {
        didSet { UserDefaults.standard.set(hoverDelay, forKey: "hoverDelay") }
    }
    @Published var hoverToOpen: Bool = true {
        didSet { UserDefaults.standard.set(hoverToOpen, forKey: "hoverToOpen") }
    }
    @Published var hideOnFullscreen: Bool = true {
        didSet { UserDefaults.standard.set(hideOnFullscreen, forKey: "hideOnFullscreen") }
    }
    @Published var simulateNotch: Bool = false {
        didSet { UserDefaults.standard.set(simulateNotch, forKey: "simulateNotch") }
    }
    @Published var collapsedMode: String = "Hidden" {
        didSet { UserDefaults.standard.set(collapsedMode, forKey: "collapsedMode") }
    }
    @Published var customMessage: String = "Hello from Notch!" {
        didSet { UserDefaults.standard.set(customMessage, forKey: "customMessage") }
    }
    @Published var enabledTools: Set<String> = Set(ToolRegistry.all.map(\.id)) {
        didSet { UserDefaults.standard.set(Array(enabledTools), forKey: "enabledTools") }
    }
    @Published var selectedTool: String = "home" {
        didSet { UserDefaults.standard.set(selectedTool, forKey: "selectedTool") }
    }
    @Published var musicTab: String = "YouTube" {
        didSet { UserDefaults.standard.set(musicTab, forKey: "musicTab") }
    }
    // 0 = embedded site, 1 = fast names list
    @Published var youTubeMode: Int = 0 {
        didSet { UserDefaults.standard.set(youTubeMode, forKey: "youTubeMode") }
    }
    // 0 = Timer, 1 = Stopwatch, 2 = Alarm
    @Published var clockMode: Int = 0 {
        didSet { UserDefaults.standard.set(clockMode, forKey: "clockMode") }
    }
    @Published var musicSidebarWidth: Double = 168 {
        didSet { UserDefaults.standard.set(musicSidebarWidth, forKey: "musicSidebarWidth") }
    }
    @Published var musicSidebarCollapsed: Bool = false {
        didSet { UserDefaults.standard.set(musicSidebarCollapsed, forKey: "musicSidebarCollapsed") }
    }
    @Published var autoCloseOnLeave: Bool = true {
        didSet { UserDefaults.standard.set(autoCloseOnLeave, forKey: "autoCloseOnLeave") }
    }
    @Published var outsideClickToClose: Bool = true {
        didSet { UserDefaults.standard.set(outsideClickToClose, forKey: "outsideClickToClose") }
    }

    init() {
        let d = UserDefaults.standard
        if d.object(forKey: "hoverDelay") != nil {
            hoverDelay = d.double(forKey: "hoverDelay")
            // Migrate old slow defaults to instant open
            if hoverDelay > 0.08 { hoverDelay = 0.05 }
        }
        if d.object(forKey: "hoverToOpen") != nil { hoverToOpen = d.bool(forKey: "hoverToOpen") }
        if d.object(forKey: "hideOnFullscreen") != nil { hideOnFullscreen = d.bool(forKey: "hideOnFullscreen") }
        if d.object(forKey: "simulateNotch") != nil { simulateNotch = d.bool(forKey: "simulateNotch") }
        if let s = d.string(forKey: "collapsedMode") {
            // Migrate old default Clock -> Hidden so pill hides under camera
            collapsedMode = (s == "Clock") ? "Hidden" : s
        }
        if let s = d.string(forKey: "customMessage") { customMessage = s }
        if let a = d.array(forKey: "enabledTools") as? [String], !a.isEmpty { enabledTools = Set(a) }
        if let s = d.string(forKey: "selectedTool") { selectedTool = s }
        if let s = d.string(forKey: "musicTab") { musicTab = (s == "MetroList" || s == "Audius" || s == "YT Music") ? "YouTube" : s }
        let sw = d.double(forKey: "musicSidebarWidth")
        if sw > 0 { musicSidebarWidth = min(300, max(110, sw)) }
        if d.object(forKey: "musicSidebarCollapsed") != nil { musicSidebarCollapsed = d.bool(forKey: "musicSidebarCollapsed") }
        if d.object(forKey: "youTubeMode") != nil { youTubeMode = min(1, max(0, d.integer(forKey: "youTubeMode"))) }
        if d.object(forKey: "clockMode") != nil { clockMode = min(2, max(0, d.integer(forKey: "clockMode"))) }
        if d.object(forKey: "autoCloseOnLeave") != nil { autoCloseOnLeave = d.bool(forKey: "autoCloseOnLeave") }
        if d.object(forKey: "outsideClickToClose") != nil { outsideClickToClose = d.bool(forKey: "outsideClickToClose") }
    }

    func isEnabled(_ id: String) -> Bool { enabledTools.contains(id) }
    func toggle(_ id: String) {
        if enabledTools.contains(id) { enabledTools.remove(id) }
        else { enabledTools.insert(id) }
    }
}
