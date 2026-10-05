import SwiftUI

/// Tiny wake-up popup under the notch: blinking time + Snooze/Stop.
/// Shown instead of the full panel when a timer ends or an alarm fires.
struct AlertPillView: View {
    @ObservedObject private var t = TimersStore.shared
    @ObservedObject private var cal = CalendarStore.shared
    @State private var blink = true

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            if t.timeUp {
                Text("Time Up · \(t.finishedMinutes) min")
                    .font(.callout).bold()
                    .foregroundStyle(Color.red)
                    .opacity(blink ? 1 : 0.3)
                Button("Dismiss") {
                    t.dismissTimeUp()
                }.buttonStyle(.borderedProminent).controlSize(.small)
            } else if let fired = t.alarmFired {
                Text("Alarm · \(fired)")
                    .font(.callout).bold()
                    .foregroundStyle(Color.red)
                    .opacity(blink ? 1 : 0.3)
                Button("Snooze") { t.snoozeAlarm() }
                    .buttonStyle(.bordered).controlSize(.small)
                Button("Stop") { t.dismissAlarm() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            } else if let ev = cal.eventFired {
                Text("\(ev.title) · \(ev.time)")
                    .font(.callout).bold()
                    .foregroundStyle(Color.orange)
                    .lineLimit(1)
                    .opacity(blink ? 1 : 0.3)
                Button("Dismiss") { cal.dismissFired(); NotchManager.shared.hideAlert() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        // Fixed size = window size: content can't drift left inside the pill.
        .frame(width: 360, height: 64)
        .background(Color.black)
        .cornerRadius(18)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.15), lineWidth: 1))
        .shadow(radius: 20)
        .onReceive(Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()) { _ in blink.toggle() }
    }
}
