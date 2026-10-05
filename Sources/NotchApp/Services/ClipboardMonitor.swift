import Foundation
import AppKit
import Combine

struct ClipboardItem: Identifiable, Codable {
    var id = UUID()
    var text: String
    var date: Date
    var sourceApp: String
}

final class ClipboardMonitor: ObservableObject {
    static let shared = ClipboardMonitor()
    @Published var history: [ClipboardItem] = []
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?

    init() {
        load()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        if let s = pb.string(forType: .string), !s.isEmpty {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
            let item = ClipboardItem(text: String(s.prefix(2000)), date: Date(), sourceApp: front)
            DispatchQueue.main.async {
                self.history.insert(item, at: 0)
                if self.history.count > 100 { self.history = Array(self.history.prefix(100)) }
                self.save()
            }
        }
    }

    func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func remove(_ item: ClipboardItem) {
        history.removeAll { $0.id == item.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "clipboardHistory")
        }
    }
    private func load() {
        if let data = UserDefaults.standard.data(forKey: "clipboardHistory"),
           let h = try? JSONDecoder().decode([ClipboardItem].self, from: data) {
            history = h
        }
    }
}
