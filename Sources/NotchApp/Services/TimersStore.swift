import Foundation
import Combine
import AppKit
import AVFoundation

/// Timer state that survives notch close/open (and relaunch).
/// The old @State timer was destroyed with the view every close — hence the reset.
/// Countdown uses a wall-clock deadline so finishing works even with the notch closed.
/// Stopwatch persists elapsed + running the same way.
/// One daily alarm, stored as 24h hour + minute so matching is trivial.
struct AlarmItem: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var hour: Int // 0–23
    var minute: Int // 0–59
    var enabled: Bool = true

    /// "7:30 AM" for display.
    var label: String {
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        let ampm = hour < 12 ? "AM" : "PM"
        return String(format: "%d:%02d %@", h12, minute, ampm)
    }
}

final class TimersStore: ObservableObject {
    static let shared = TimersStore()

    @Published var seconds = 25 * 60
    @Published var running = false
    @Published var timeUp = false
    @Published var totalSeconds = 25 * 60
    @Published var finishedMinutes = 25

    @Published var swElapsed: Double = 0
    @Published var swRunning = false
    @Published var swLaps: [Double] = []

    @Published var alarms: [AlarmItem] = []
    @Published var alarmFired: String?

    // Alert sound: built-in system sound or a local music file (shared by timer + alarm)
    static let builtInSounds = ["Glass", "Hero", "Submarine", "Sosumi", "Ping", "Pop", "Purr", "Tink"]
    @Published var alarmSound: String = UserDefaults.standard.string(forKey: "alarmSound") ?? "Hero" {
        didSet { UserDefaults.standard.set(alarmSound, forKey: "alarmSound") }
    }
    @Published var customSoundURL: String? = UserDefaults.standard.string(forKey: "alarmSoundURL") {
        didSet {
            if let u = customSoundURL { UserDefaults.standard.set(u, forKey: "alarmSoundURL") }
            else { UserDefaults.standard.removeObject(forKey: "alarmSoundURL") }
        }
    }
    var customSoundName: String? {
        customSoundURL.flatMap { URL(string: $0)?.lastPathComponent }
    }

    private var customPlayer: AVPlayer?

    private var timer: Timer?
    private var swTimer: Timer?
    private let secsKey = "timerSeconds"
    private let runningKey = "timerRunning"
    private let deadlineKey = "timerDeadline"
    private let totalKey = "timerTotal"
    private let timeUpKey = "timerTimeUp"
    private let finishedKey = "timerFinishedMin"
    private let swElapsedKey = "swElapsed"
    private let swRunningKey = "swRunning"
    private let swStampKey = "swStamp"
    private let swLapsKey = "swLaps"
    private let alarmsKey = "clockAlarms"
    private var alarmTimer: Timer?
    private var alarmLastFired: [String: String] = [:]

    init() {
        let d = UserDefaults.standard
        let saved = d.integer(forKey: secsKey)
        if saved > 0 { seconds = saved }
        let savedTotal = d.integer(forKey: totalKey)
        if savedTotal > 0 {
            totalSeconds = savedTotal
        } else if saved > 0 {
            totalSeconds = saved
        }
        let savedFinished = d.integer(forKey: finishedKey)
        if savedFinished > 0 { finishedMinutes = savedFinished }
        timeUp = d.bool(forKey: timeUpKey)

        // If it was running when the app closed, catch up with elapsed time.
        // If the deadline already passed while closed, surface timeUp on next open + alarm.
        if d.bool(forKey: runningKey) {
            let deadline = d.double(forKey: deadlineKey)
            if deadline > 0 {
                let left = Int(deadline - Date().timeIntervalSince1970)
                if left <= 0 {
                    seconds = 0
                    running = false
                    timeUp = true
                    finishedMinutes = max(1, Int((Double(totalSeconds) / 60.0).rounded()))
                    persist()
                    playAlarm()
                } else {
                    seconds = left
                    timeUp = false
                    if seconds > 0 { start(resuming: true) }
                }
            } else if seconds > 0 {
                start(resuming: true)
            }
        }

        // Stopwatch restore.
        swElapsed = d.double(forKey: swElapsedKey)
        if let arr = d.array(forKey: swLapsKey) as? [Double] {
            swLaps = arr
        }
        if d.bool(forKey: swRunningKey) {
            let stamp = d.double(forKey: swStampKey)
            if stamp > 0 {
                swElapsed = max(0, swElapsed + (Date().timeIntervalSince1970 - stamp))
            }
            swStart(resuming: true)
        }

        // Alarm restore + store-level polling so firing works with notch closed.
        if let data = d.data(forKey: alarmsKey),
           let decoded = try? JSONDecoder().decode([AlarmItem].self, from: data) {
            alarms = decoded
        }
        snoozeUntil = d.double(forKey: snoozeKey)
        startAlarmPolling()
    }

    // MARK: Countdown

    func start(resuming: Bool = false) {
        timer?.invalidate()
        running = true
        if !resuming {
            if seconds > 0 { totalSeconds = seconds }
            timeUp = false
            finishedMinutes = max(1, Int((Double(totalSeconds) / 60.0).rounded()))
        }
        persist()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.seconds > 0 {
                self.seconds -= 1
                self.persist()
                if self.seconds <= 0 {
                    self.finishCountdown()
                }
            } else {
                self.finishCountdown()
            }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
        if !resuming { persist() }
    }

    func pause() {
        timer?.invalidate(); timer = nil
        running = false
        persist()
    }

    func toggle() { running ? pause() : start() }

    func set(_ s: Int) {
        timer?.invalidate(); timer = nil
        running = false
        timeUp = false
        seconds = max(0, s)
        if seconds > 0 {
            totalSeconds = seconds
            finishedMinutes = max(1, Int((Double(totalSeconds) / 60.0).rounded()))
        }
        persist()
    }

    /// Custom minutes entry: at least 1, no upper limit.
    func setMinutes(_ m: Int) {
        set(max(1, m) * 60)
    }

    func dismissTimeUp() {
        timeUp = false
        running = false
        seconds = totalSeconds > 0 ? totalSeconds : 25 * 60
        persist()
        NotchManager.shared.hideAlert()
    }

    private func finishCountdown() {
        timer?.invalidate(); timer = nil
        running = false
        seconds = 0
        if !timeUp {
            timeUp = true
            finishedMinutes = max(1, Int((Double(totalSeconds) / 60.0).rounded()))
        }
        persist()
        playAlarm()
        revealClock()
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(seconds, forKey: secsKey)
        d.set(running, forKey: runningKey)
        d.set(running ? Date().timeIntervalSince1970 + Double(seconds) : 0, forKey: deadlineKey)
        d.set(totalSeconds, forKey: totalKey)
        d.set(timeUp, forKey: timeUpKey)
        d.set(finishedMinutes, forKey: finishedKey)
    }

    /// Alert sound: local music file if chosen, else the picked system sound ×3.
    /// Store-level so it fires even when the notch/panel is closed.
    private func playAlarm() {
        if let s = customSoundURL, let url = URL(string: s) {
            customPlayer = AVPlayer(url: url)
            customPlayer?.play()
            return
        }
        let name = alarmSound.isEmpty ? "Hero" : alarmSound
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.6) { [name] in
                if let s = NSSound(named: name) {
                    s.play()
                } else if let f = NSSound(named: "Funk") {
                    f.play()
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    func pickLocalSound() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.allowedContentTypes = [.mp3, .mpeg4Audio, .wav, .aiff]
        p.prompt = "Use as alarm"
        guard p.runModal() == .OK, let url = p.url else { return }
        customSoundURL = url.absoluteString
    }

    func clearCustomSound() { customSoundURL = nil; customPlayer?.pause(); customPlayer = nil }

    /// Show the tiny alert pill under the notch for time-up / alarm
    /// (no full-panel takeover).
    private func revealClock() {
        NotchManager.shared.showAlert()
    }

    // MARK: Stopwatch (counts up, 0.1s tick on .common)

    func swStart(resuming: Bool = false) {
        swTimer?.invalidate()
        swRunning = true
        persistSW()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.swElapsed += 0.1
            self.persistSW()
        }
        swTimer = t
        RunLoop.main.add(t, forMode: .common)
        if !resuming { persistSW() }
    }

    func swPause() {
        swTimer?.invalidate(); swTimer = nil
        swRunning = false
        persistSW()
    }

    func swToggle() { swRunning ? swPause() : swStart() }

    func swReset() {
        swTimer?.invalidate(); swTimer = nil
        swRunning = false
        swElapsed = 0
        swLaps = []
        persistSW()
    }

    func swLap() {
        guard swElapsed > 0.05 else { return }
        // Round to tenths to keep the list stable.
        let v = (swElapsed * 10).rounded() / 10
        swLaps.append(v)
        if swLaps.count > 100 { swLaps.removeFirst(swLaps.count - 100) }
        persistSW()
    }

    func swClearLaps() {
        swLaps = []
        persistSW()
    }

    private func persistSW() {
        let d = UserDefaults.standard
        d.set(swElapsed, forKey: swElapsedKey)
        d.set(swRunning, forKey: swRunningKey)
        d.set(swRunning ? Date().timeIntervalSince1970 : 0, forKey: swStampKey)
        d.set(swLaps, forKey: swLapsKey)
    }

    // MARK: Alarm (daily HH:MM, minute-granularity, store-level)

    func addAlarm(hour: Int, minute: Int) {
        let h = min(23, max(0, hour))
        let m = min(59, max(0, minute))
        alarms.append(AlarmItem(hour: h, minute: m, enabled: true))
        alarms.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        persistAlarms()
    }

    func removeAlarm(_ id: UUID) {
        alarms.removeAll { $0.id == id }
        persistAlarms()
    }

    func setAlarmEnabled(_ id: UUID, enabled: Bool) {
        if let i = alarms.firstIndex(where: { $0.id == id }) {
            alarms[i].enabled = enabled
            persistAlarms()
        }
    }

    func updateAlarm(_ id: UUID, hour: Int, minute: Int) {
        if let i = alarms.firstIndex(where: { $0.id == id }) {
            alarms[i].hour = min(23, max(0, hour))
            alarms[i].minute = min(59, max(0, minute))
            alarms.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
            persistAlarms()
        }
    }

    func dismissAlarm() {
        alarmFired = nil
        snoozeUntil = 0
        UserDefaults.standard.set(0, forKey: snoozeKey)
        NotchManager.shared.hideAlert()
    }

    /// Snooze 5 min: clears the banner, re-fires once via the poll loop.
    func snoozeAlarm() {
        alarmFired = nil
        snoozeUntil = Date().timeIntervalSince1970 + 5 * 60
        UserDefaults.standard.set(snoozeUntil, forKey: snoozeKey)
        NotchManager.shared.hideAlert()
    }

    private var snoozeUntil: Double = 0
    private let snoozeKey = "alarmSnoozeUntil"

    private func persistAlarms() {
        if let data = try? JSONEncoder().encode(alarms) {
            UserDefaults.standard.set(data, forKey: alarmsKey)
        }
    }

    /// Cheap 10s poll on .common modes. Compares enabled alarms against
    /// current HH:MM; fires once per minute per alarm (minute-stamp guard).
    private func startAlarmPolling() {
        alarmTimer?.invalidate()
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            self?.checkAlarms()
        }
        alarmTimer = t
        RunLoop.main.add(t, forMode: .common)
        checkAlarms()
    }

    private func checkAlarms() {
        let now = Date()
        // Snooze re-fire (one-shot)
        if snoozeUntil > 0, now.timeIntervalSince1970 >= snoozeUntil {
            snoozeUntil = 0
            UserDefaults.standard.set(0, forKey: snoozeKey)
            alarmFired = "Snoozed alarm"
            playAlarm()
            revealClock()
            return
        }
        let cal = Calendar.current
        let h = cal.component(.hour, from: now)
        let m = cal.component(.minute, from: now)
        let stamp = String(format: "%04d%02d%02d%02d%02d",
            cal.component(.year, from: now), cal.component(.month, from: now),
            cal.component(.day, from: now), h, m)
        for alarm in alarms where alarm.enabled {
            guard alarm.hour == h && alarm.minute == m else { continue }
            let key = alarm.id.uuidString
            guard alarmLastFired[key] != stamp else { continue }
            alarmLastFired[key] = stamp
            alarmFired = alarm.label
            playAlarm()
            revealClock()
        }
    }
}
