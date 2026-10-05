import Foundation
import Combine
import AppKit

/// User-created calendar events (local, no system permission needed).
/// Shown alongside EventKit events; a tiny pill pops at the event time.
struct CustomEvent: Identifiable, Codable {
    var id = UUID()
    var title: String
    var date: Date
}

final class CalendarStore: ObservableObject {
    static let shared = CalendarStore()

    @Published var customEvents: [CustomEvent] = []
    /// Fired event banner: (title, time label). Pill clears it on Dismiss.
    @Published var eventFired: (title: String, time: String)?

    private let eventsKey = "calendarCustomEvents"
    private let notifiedKey = "calendarNotifiedIds"
    private var notifiedIds: Set<String> = []
    private var poll: Timer?

    init() {
        if let data = UserDefaults.standard.data(forKey: eventsKey),
           let list = try? JSONDecoder().decode([CustomEvent].self, from: data) {
            customEvents = list
        }
        if let arr = UserDefaults.standard.array(forKey: notifiedKey) as? [String] {
            notifiedIds = Set(arr)
        }
        // Prune events older than 7 days (and their notified marks).
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        let old = customEvents.filter { $0.date < cutoff }.map(\.id.uuidString)
        if !old.isEmpty {
            customEvents.removeAll { $0.date < cutoff }
            notifiedIds.subtract(old)
            saveAll()
        }
        poll = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.checkDue()
        }
        if let p = poll { RunLoop.main.add(p, forMode: .common) }
        checkDue()
    }

    func add(title: String, date: Date) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        customEvents.append(CustomEvent(title: clean, date: date))
        customEvents.sort { $0.date < $1.date }
        saveEvents()
    }

    func remove(_ id: UUID) {
        customEvents.removeAll { $0.id == id }
        notifiedIds.remove(id.uuidString)
        saveAll()
    }

    func events(on day: Date) -> [CustomEvent] {
        let cal = Calendar.current
        return customEvents.filter { cal.isDate($0.date, inSameDayAs: day) }
            .sorted { $0.date < $1.date }
    }

    func hasEvents(on day: Date) -> Bool {
        let cal = Calendar.current
        return customEvents.contains { cal.isDate($0.date, inSameDayAs: day) }
    }

    func dismissFired() { eventFired = nil }

    private func checkDue() {
        let now = Date()
        // Fire the earliest due event; the rest queue up on later polls.
        guard let due = customEvents
            .filter({ $0.date <= now && !notifiedIds.contains($0.id.uuidString) })
            .sorted(by: { $0.date < $1.date }).first else { return }
        notifiedIds.insert(due.id.uuidString)
        UserDefaults.standard.set(Array(notifiedIds), forKey: notifiedKey)
        eventFired = (due.title, due.date.formatted(date: .omitted, time: .shortened))
        NSSound(named: "Ping")?.play()
        NotchManager.shared.showAlert()
    }

    private func saveEvents() {
        if let data = try? JSONEncoder().encode(customEvents) {
            UserDefaults.standard.set(data, forKey: eventsKey)
        }
    }

    private func saveAll() {
        saveEvents()
        UserDefaults.standard.set(Array(notifiedIds), forKey: notifiedKey)
    }
}
