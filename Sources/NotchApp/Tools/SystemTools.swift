import SwiftUI
import EventKit
import AppKit

// MARK: Calendar
struct CalendarTool: View {
    private struct DayEvent: Identifiable, Sendable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
    }
    @State private var items: [DayEvent] = []
    @State private var displayMonth = Date()
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var permissionDenied = false
    @State private var hasLoaded = false
    @StateObject private var customs = CalendarStore.shared
    @State private var showEvForm = false
    @State private var evTitle = ""
    @State private var evDay = Date()
    @State private var evTime = Calendar.current.date(bySettingHour: 0, minute: 0, second: 0, of: Date()) ?? Date()

    private var cal: Calendar { Calendar.current }
    private var monthStart: Date {
        cal.date(from: cal.dateComponents([.year, .month], from: displayMonth)) ?? cal.startOfDay(for: Date())
    }
    private var monthTitle: String {
        displayMonth.formatted(.dateTime.month(.wide).year())
    }
    /// Monday-first cells: nil = leading blank, non-nil = date in visible month.
    private var cells: [Date?] {
        let dayCount = cal.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        let weekday = cal.component(.weekday, from: monthStart) // 1=Sun..7=Sat
        let leading = (weekday + 5) % 7 // Mon-first offset
        var out: [Date?] = Array(repeating: nil, count: leading)
        for d in 0..<dayCount {
            out.append(cal.date(byAdding: .day, value: d, to: monthStart))
        }
        return out
    }
    private var eventsByDay: [Date: [DayEvent]] {
        var map = Dictionary(grouping: items) { cal.startOfDay(for: $0.start) }
        // Merge local custom events so dots + day lists include them.
        for c in customs.customEvents {
            let key = cal.startOfDay(for: c.date)
            map[key, default: []].append(DayEvent(id: "custom-\(c.id.uuidString)", title: c.title, start: c.date, end: c.date, isAllDay: false))
        }
        return map
    }
    private var selectedEvents: [DayEvent] {
        (eventsByDay[cal.startOfDay(for: selectedDay)] ?? []).sorted { $0.start < $1.start }
    }

    var body: some View {
        ToolContainer("Calendar", subtitle: hasLoaded ? "\(items.count) events this month — tap a day" : "This month • tap a day to see what's on") {
            VStack(spacing: 8) {
                // Header row: month nav grouped left, Load top-right.
                HStack(spacing: 8) {
                    Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    Text(monthTitle).font(.subheadline).bold()
                        .frame(width: 150, alignment: .center)
                    Button { shiftMonth(1) } label: { Image(systemName: "chevron.right").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer()
                    Button("Load from Calendar") { load() }.controlSize(.small)
                }
                HStack(alignment: .top, spacing: 12) {
                    // LEFT: mini month calendar (Mon–Sun header, today highlighted, dots).
                    VStack(spacing: 4) {
                        HStack(spacing: 0) {
                            // Index IDs: weekday initials repeat ("T" twice), so id:\.self would collide.
                            ForEach(Array(["M","T","W","T","F","S","S"].enumerated()), id: \.offset) { _, d in
                                Text(d).font(.caption2).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                            ForEach(cells.indices, id: \.self) { i in
                                if let date = cells[i] {
                                    dayCell(date)
                                } else {
                                    Color.clear.frame(width: 24, height: 30)
                                }
                            }
                        }
                    }
                    .frame(minWidth: 140, maxWidth: 184, alignment: .top)
                    Divider()
                    // RIGHT: events for the selected day, scrollable + bounded.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(selectedDay.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).bold().foregroundStyle(.secondary)
                            Spacer()
                            Button(showEvForm ? "Cancel" : "+ Add event") {
                                if !showEvForm {
                                    evTitle = ""
                                    evDay = selectedDay
                                    evTime = cal.date(bySettingHour: 0, minute: 0, second: 0, of: selectedDay) ?? selectedDay
                                }
                                showEvForm.toggle()
                            }.controlSize(.small)
                        }
                        if showEvForm {
                            VStack(alignment: .leading, spacing: 6) {
                                TextField("Event title", text: $evTitle).textFieldStyle(.roundedBorder).controlSize(.small)
                                HStack {
                                    DatePicker("Date", selection: $evDay, displayedComponents: .date)
                                        .labelsHidden()
                                    DatePicker("Time", selection: $evTime, displayedComponents: .hourAndMinute)
                                        .labelsHidden()
                                    Spacer()
                                    Button("Save") {
                                        let dayParts = cal.dateComponents([.year, .month, .day], from: evDay)
                                        let timeParts = cal.dateComponents([.hour, .minute], from: evTime)
                                        var parts = DateComponents()
                                        parts.year = dayParts.year; parts.month = dayParts.month; parts.day = dayParts.day
                                        parts.hour = timeParts.hour ?? 0; parts.minute = timeParts.minute ?? 0
                                        if let at = cal.date(from: parts) {
                                            customs.add(title: evTitle, date: at)
                                        }
                                        showEvForm = false
                                    }
                                    .buttonStyle(.borderedProminent).controlSize(.small)
                                    .disabled(evTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }
                            .padding(8).background(Color.white.opacity(0.05)).cornerRadius(8)
                        }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                if !hasLoaded && selectedEvents.isEmpty {
                                    Text("Tap Load to read your agenda").font(.caption).foregroundStyle(.secondary)
                                } else if permissionDenied && selectedEvents.isEmpty {
                                    Text("Permission denied").font(.caption).foregroundStyle(.secondary)
                                } else if selectedEvents.isEmpty {
                                    if items.isEmpty {
                                        Text("Nothing this month 🎉").font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text("Nothing on this day 🎉").font(.caption).foregroundStyle(.secondary)
                                    }
                                } else {
                                    ForEach(selectedEvents) { e in
                                        HStack(spacing: 8) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(e.title).font(.caption).lineLimit(2)
                                                Text(e.isAllDay ? "all-day" : e.start.formatted(date: .omitted, time: .shortened))
                                                    .font(.caption2).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            if e.id.hasPrefix("custom-"),
                                               let uuid = UUID(uuidString: String(e.id.dropFirst(7))) {
                                                Button { customs.remove(uuid) } label: {
                                                    Image(systemName: "trash").font(.caption)
                                                }
                                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                            }
                                        }
                                        .padding(6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(.ultraThinMaterial)
                                        .cornerRadius(8)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .onChange(of: displayMonth) { _, _ in
                if hasLoaded && !permissionDenied { load() }
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let day = cal.component(.day, from: date)
        let isToday = cal.isDateInToday(date)
        let isSelected = cal.isDate(date, inSameDayAs: selectedDay)
        let hasEvents = eventsByDay[cal.startOfDay(for: date)] != nil
        return VStack(spacing: 1) {
            ZStack {
                if isSelected {
                    Circle().fill(Color.accentColor).frame(width: 22, height: 22)
                } else if isToday {
                    Circle().fill(Color.accentColor.opacity(0.25)).frame(width: 22, height: 22)
                } else {
                    Circle().fill(Color.clear).frame(width: 22, height: 22)
                }
                Text("\(day)")
                    .font(.caption)
                    .fontWeight(isToday || isSelected ? .bold : .regular)
                    .foregroundStyle(isSelected ? .white : (isToday ? .accentColor : .primary))
            }
            Circle()
                .fill(hasEvents ? (isSelected ? Color.white : Color.accentColor) : Color.clear)
                .frame(width: 4, height: 4)
        }
        .frame(width: 24, height: 30)
        .contentShape(Rectangle())
        .onTapGesture { selectedDay = cal.startOfDay(for: date) }
    }

    private func shiftMonth(_ delta: Int) {
        if let d = cal.date(byAdding: .month, value: delta, to: displayMonth) {
            displayMonth = d
        }
    }

    func load() {
        let store = EKEventStore()
        let mStart = monthStart
        let mEnd = cal.date(byAdding: DateComponents(month: 1), to: mStart) ?? Date().addingTimeInterval(31*86400)
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, _ in
                let fetched: [DayEvent] = granted
                    ? store.events(matching: store.predicateForEvents(withStart: mStart, end: mEnd, calendars: nil)).map {
                        DayEvent(
                            id: $0.eventIdentifier ?? UUID().uuidString,
                            title: $0.title ?? "Event",
                            start: $0.startDate ?? mStart,
                            end: $0.endDate ?? ($0.startDate ?? mStart),
                            isAllDay: $0.isAllDay
                        )
                    }
                    : []
                Task { @MainActor in
                    guard granted else { permissionDenied = true; hasLoaded = true; return }
                    permissionDenied = false
                    hasLoaded = true
                    items = fetched.sorted { $0.start < $1.start }
                }
            }
        }
    }
}

// MARK: Clock — state lives in TimersStore.shared so closing the notch never resets it
struct TimersTool: View {
    @StateObject private var t = TimersStore.shared
    @StateObject private var settings = SettingsStore.shared
    @State private var customText = ""
    @State private var alarmTime = Date()
    @State private var editingAlarmId: UUID?
    @State private var editDate = Date()
    @State private var blink = true
    @Namespace private var timerAnim

    private var subtitle: String {
        if settings.clockMode == 2 {
            if t.alarmFired != nil { return "Ringing — tap Dismiss" }
            if t.alarms.isEmpty { return "Set a daily alarm" }
            return "\(t.alarms.filter(\.enabled).count)/\(t.alarms.count) alarms on"
        }
        if settings.clockMode == 1 { return t.swRunning ? "Stopwatch running" : "Stopwatch" }
        if t.timeUp { return "Done — tap Dismiss" }
        return t.running ? "Running — safe to close the notch" : "Pomodoro / countdown"
    }

    var body: some View {
        ToolContainer("Clock", subtitle: subtitle) {
            VStack(spacing: 8) {
                Picker("", selection: $settings.clockMode) {
                    Text("Timer").tag(0)
                    Text("Stopwatch").tag(1)
                    Text("Alarm").tag(2)
                }
                .pickerStyle(.segmented)
                .controlSize(.regular)
                .frame(maxWidth: 340, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .center)

                if settings.clockMode == 0 { timerSection } else if settings.clockMode == 1 { stopwatchSection } else { alarmSection }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .onReceive(Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()) { _ in blink.toggle() }
        }
    }

    // MARK: Countdown
    private var timerSection: some View {
        VStack(spacing: 10) {
            Text("\(t.seconds / 60):\(String(format: "%02d", t.seconds % 60))")
                .font(.system(size: 64, design: .monospaced).weight(.bold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .center)
            if t.timeUp {
                Text("Time Up · \(t.finishedMinutes) min")
                    .font(.title3).bold()
                    .lineLimit(1)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.red.opacity(0.18))
                    .foregroundStyle(Color.red)
                    .cornerRadius(10)
                    .matchedGeometryEffect(id: "timeUpBadge", in: timerAnim)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .opacity(blink ? 1 : 0.3)
            }
            HStack(spacing: 8) {
                Button(t.running ? "Pause" : "Start") { t.toggle() }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
                Button("25m") { t.set(25 * 60) }.buttonStyle(.bordered).controlSize(.small)
                Button("5m") { t.set(5 * 60) }.buttonStyle(.bordered).controlSize(.small)
                Button("Reset") { t.set(t.totalSeconds > 0 ? t.totalSeconds : 25 * 60) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).controlSize(.small)
                if t.timeUp {
                    Button("Dismiss") { t.dismissTimeUp() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .animation(.spring(response: 0.45, dampingFraction: 0.75), value: t.timeUp)

            HStack(spacing: 6) {
                TextField("min", text: $customText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .controlSize(.small)
                    .multilineTextAlignment(.center)
                    .onSubmit { applyCustom() }
                Button("Set") { applyCustom() }.buttonStyle(.bordered).controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity)
    }

    private func applyCustom() {
        let trimmed = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = Int(trimmed) else { return } // ignore garbage
        t.setMinutes(m) // store clamps 1–180
        customText = ""
    }

    // MARK: Stopwatch
    private var stopwatchSection: some View {
        VStack(spacing: 10) {
            Text(fmtTenths(t.swElapsed))
                .font(.system(size: 64, design: .monospaced).weight(.bold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .center)
            HStack(spacing: 8) {
                Button(t.swRunning ? "Pause" : "Start") { t.swToggle() }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
                Button("Lap") { t.swLap() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(t.swElapsed < 0.05 && !t.swRunning)
                Button("Reset") { t.swReset() }
                    .buttonStyle(.plain).foregroundStyle(.secondary).controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            if !t.swLaps.isEmpty {
                Text("Laps (\(t.swLaps.count))").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if t.swLaps.isEmpty {
                        Text("Tap Lap to mark splits").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(t.swLaps.indices.reversed(), id: \.self) { i in
                            HStack {
                                Text("Lap \(i + 1)").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(fmtTenths(t.swLaps[i])).font(.caption).monospacedDigit()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.ultraThinMaterial)
                            .cornerRadius(6)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .background(Color.white.opacity(0.02))
            .cornerRadius(8)
        }
    }

    // MARK: Alarm
    private var alarmSection: some View {
        VStack(spacing: 10) {
            if let fired = t.alarmFired {
                HStack(spacing: 8) {
                    Text("Alarm · \(fired)")
                        .font(.callout).bold()
                        .lineLimit(1)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.red.opacity(0.18))
                        .foregroundStyle(Color.red)
                        .cornerRadius(10)
                        .matchedGeometryEffect(id: "alarmBadge", in: timerAnim)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .opacity(blink ? 1 : 0.3)
                    Button("Snooze") { t.snoozeAlarm() }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button("Stop") { t.dismissAlarm() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .animation(.spring(response: 0.45, dampingFraction: 0.75), value: t.alarmFired)
            }
            HStack(spacing: 8) {
                DatePicker("", selection: $alarmTime, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                Button("Add") {
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: alarmTime)
                    t.addAlarm(hour: parts.hour ?? 7, minute: parts.minute ?? 30)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            // Alert sound for timer + alarm: built-ins or your own file
            HStack(spacing: 6) {
                if let custom = t.customSoundName {
                    Button("\(custom) ✕") { t.clearCustomSound() }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("Tap to go back to built-in sounds")
                } else {
                    Picker("Sound", selection: $t.alarmSound) {
                        ForEach(TimersStore.builtInSounds, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 110)
                    .controlSize(.small)
                    Button("Local…") { t.pickLocalSound() }.controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            ScrollView {
                VStack(spacing: 4) {
                    if t.alarms.isEmpty {
                        Text("No alarms yet").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(t.alarms) { a in
                            if editingAlarmId == a.id {
                                HStack(spacing: 8) {
                                    DatePicker("", selection: $editDate, displayedComponents: .hourAndMinute)
                                        .datePickerStyle(.compact)
                                        .labelsHidden()
                                    Button("Done") {
                                        let parts = Calendar.current.dateComponents([.hour, .minute], from: editDate)
                                        t.updateAlarm(a.id, hour: parts.hour ?? 7, minute: parts.minute ?? 30)
                                        editingAlarmId = nil
                                    }
                                    .buttonStyle(.borderedProminent).controlSize(.small)
                                    Button("Cancel") { editingAlarmId = nil }.controlSize(.small)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(.ultraThinMaterial)
                                .cornerRadius(8)
                                .frame(maxWidth: .infinity, alignment: .center)
                            } else {
                                HStack(spacing: 10) {
                                    Button {
                                        if let d = Calendar.current.date(bySettingHour: a.hour, minute: a.minute, second: 0, of: Date()) {
                                            editDate = d
                                        }
                                        editingAlarmId = a.id
                                    } label: {
                                        Text(a.label).font(.caption).bold().monospacedDigit()
                                    }
                                    .buttonStyle(.plain)
                                    .help("Tap to edit")
                                    Toggle("", isOn: Binding(
                                        get: { a.enabled },
                                        set: { t.setAlarmEnabled(a.id, enabled: $0) }
                                    ))
                                    .toggleStyle(.switch).controlSize(.mini)
                                    .labelsHidden()
                                    Button { t.removeAlarm(a.id) } label: {
                                        Image(systemName: "trash").font(.caption)
                                    }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(.ultraThinMaterial)
                                .cornerRadius(8)
                                .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxHeight: .infinity)
            .background(Color.white.opacity(0.02))
            .cornerRadius(8)
        }
    }

    private func fmtTenths(_ e: Double) -> String {
        let tenths = Int((e * 10).rounded())
        let m = tenths / 600
        let s = (tenths / 10) % 60
        let th = tenths % 10
        return String(format: "%d:%02d.%d", m, s, th)
    }
}

// MARK: Stats
struct StatsTool: View {
    @StateObject private var p = StatsProvider.shared
    var body: some View {
        ToolContainer("Stats", subtitle: "Vitals without a menu-bar zoo") {
            HStack {
                VStack(alignment: .leading) { Text("CPU").font(.caption); Text("\(Int(p.cpu))%").bold() }
                Spacer()
                VStack(alignment: .leading) { Text("MEM").font(.caption); Text(String(format: "%.1f/%.0f", p.memUsedGB, p.memTotalGB)).bold() }
                Spacer()
                VStack(alignment: .leading) { Text("DISK").font(.caption); Text("\(Int(p.diskUsedPct))%").bold() }
                Spacer()
                VStack(alignment: .leading) { Text("BATT").font(.caption); Text("\(Int(p.batteryPct))%").bold() }
                Spacer()
                Button("Refresh") { p.refresh() }.controlSize(.small)
            }.padding().background(.ultraThinMaterial).cornerRadius(12)
        }
        .onAppear { p.refresh() }
    }
}

// MARK: ScreenTime
struct ScreenTimeTool: View {
    @State private var apps: [(String, String)] = []
    @State private var hasLoaded = false
    var body: some View {
        ToolContainer("Screen Time", subtitle: "Where the day went, app by app") {
            HStack {
                Spacer()
                Button("Load running apps") { load() }.controlSize(.small)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if !hasLoaded {
                        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    } else if apps.isEmpty {
                        Text("No running apps found").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(apps, id: \.0) { Text("\($0.0) — \($0.1)") }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { load() }
    }
    private func load() {
        apps = NSWorkspace.shared.runningApplications.prefix(12).map { ($0.localizedName ?? "?", "running") }
        hasLoaded = true
    }
}

// MARK: Weather (Open-Meteo, no key)
struct WeatherTool: View {
    @State private var text = ""
    @State private var isLoading = false
    @State private var hasLoaded = false
    var body: some View {
        ToolContainer("Weather", subtitle: "Open-Meteo, no key needed") {
            HStack {
                Spacer()
                Button("Fetch") { fetch() }.controlSize(.small)
            }
            ScrollView {
                if isLoading && !hasLoaded {
                    HStack { Spacer(); ProgressView("Loading…").font(.caption).foregroundStyle(.secondary); Spacer() }
                } else {
                    Text(text).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear { fetch() }
    }
    private func fetch() {
        guard !isLoading else { return }
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=37.32&longitude=-122.03&current=temperature_2m,relative_humidity_2m,weather_code&timezone=auto") else { return }
        isLoading = true
        URLSession.shared.dataTask(with: url) { d, _, _ in
            DispatchQueue.main.async {
                isLoading = false
                hasLoaded = true
                guard let d, let s = String(data: d, encoding: .utf8), !s.isEmpty else {
                    text = "Couldn't load weather — check connection and retry."
                    return
                }
                text = String(s.prefix(400))
            }
        }.resume()
    }
}

// MARK: Clipboard
struct ClipboardTool: View {
    @StateObject private var mon = ClipboardMonitor.shared
    @State private var q = ""
    var filtered: [ClipboardItem] {
        q.isEmpty ? mon.history : mon.history.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }
    var body: some View {
        ToolContainer("Clipboard", subtitle: "Click any item to copy it back") {
            TextField("Search clipboard...", text: $q).textFieldStyle(.roundedBorder)
            if filtered.isEmpty {
                Text(q.isEmpty ? "Copy something — it lands here." : "No matches — try another search.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List(filtered.prefix(30)) { item in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading) {
                            Text(String(item.text.prefix(120))).lineLimit(2)
                            Text("\(item.sourceApp) — \(item.date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                        // Fill the row so the whole text area copies (trash stays outside the tap).
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { mon.copy(item.text) }
                        Button { mon.remove(item) } label: {
                            Image(systemName: "trash").font(.caption)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }.listStyle(.plain).frame(maxHeight: .infinity)
            }
        }
    }
}

// MARK: Shelf (file parking)
struct ShelfTool: View {
    @State private var files: [String] = LocalStorage.load("shelf", as: [String].self) ?? []
    var body: some View {
        ToolContainer("Shelf", subtitle: "Drag files in to park, drag out to use anywhere") {
            HStack {
                Button("Add files...") {
                    let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false
                    if p.runModal() == .OK {
                        files += p.urls.map(\.path); LocalStorage.save(files, key: "shelf")
                    }
                }.controlSize(.small)
                Button("Clear") { files = []; LocalStorage.save(files, key: "shelf") }.controlSize(.small)
                Spacer()
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], alignment: .leading) {
                    ForEach(files, id: \.self) { f in
                        VStack(spacing: 4) {
                            Image(systemName: "doc").font(.title2)
                            Text(URL(fileURLWithPath: f).lastPathComponent).lineLimit(2).font(.caption)
                        }.padding(10).background(.ultraThinMaterial).cornerRadius(10)
                        .onDrag { NSItemProvider(object: URL(fileURLWithPath: f) as NSURL) }
                    }
                }
                if files.isEmpty {
                    Text("Empty — drag anything here").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for pr in providers {
                _ = pr.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.isFileURL {
                        DispatchQueue.main.async {
                            files.append(url.path); LocalStorage.save(files, key: "shelf")
                        }
                    }
                }
            }
            return true
        }
    }
}

// MARK: Files convert
struct FilesTool: View {
    @State private var status = "Pick an image to convert — stays on your Mac."
    var body: some View {
        ToolContainer("Files", subtitle: "Convert & shrink images locally") {
            HStack {
                Button("JPEG 80%") { convert(ext: "jpg", q: 0.8) }
                Button("PNG") { convert(ext: "png", q: 1.0) }
                Button("HEIC→JPG") { convert(ext: "jpg", q: 0.85) }
            }.controlSize(.small)
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
    }
    func convert(ext: String, q: CGFloat) {
        let p = NSOpenPanel(); p.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        guard p.runModal() == .OK, let url = p.url, let img = NSImage(contentsOf: url) else { return }
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { status = "Failed"; return }
        let props: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: q]
        let type: NSBitmapImageRep.FileType = ext == "png" ? .png : .jpeg
        guard let data = rep.representation(using: type, properties: props) else { status = "Failed"; return }
        let out = url.deletingPathExtension().appendingPathExtension(ext)
        try? data.write(to: out)
        status = "Saved \(out.lastPathComponent) (\(data.count/1024) KB)"
    }
}

// MARK: Sounds
struct SoundsTool: View {
    let rooms = ["Rain", "Forest", "Cafe", "Office", "Lo-Fi", "Waves", "Fire", "Night"]
    @State private var active = Set<String>()
    var body: some View {
        ToolContainer("Sounds", subtitle: active.isEmpty ? "Tap tiles to layer ambience" : "Playing: \(active.sorted().joined(separator: ", "))") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], alignment: .leading) {
                ForEach(rooms, id: \.self) { r in
                    Button(r) {
                        if active.contains(r) { active.remove(r) } else { active.insert(r) }
                        NSSound.beep()
                    }
                    .buttonStyle(.borderedProminent)
                    .opacity(active.contains(r) ? 1 : 0.5)
                    .controlSize(.small)
                }
            }
        }
    }
}
