import Foundation
import Combine

/// Stats without blocking the main thread.
/// pmset + FileManager I/O run on a background queue; @Published updates hop to main.
final class StatsProvider: ObservableObject {
    static let shared = StatsProvider()
    @Published var cpu: Double = 12
    @Published var memUsedGB: Double = 6.2
    @Published var memTotalGB: Double = 16
    @Published var diskUsedPct: Double = 42
    @Published var batteryPct: Double = 87

    private var timer: Timer?
    private let queue = DispatchQueue(label: "notch.stats", qos: .utility)
    private var inFlight = false

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
        refresh()
    }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        queue.async { [weak self] in
            guard let self else { return }
            var memUsed = 0.0
            var diskPct = 0.0
            var batt = -1.0

            var vmStats = vm_statistics64()
            var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
            let r = withUnsafeMutablePointer(to: &vmStats) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
                }
            }
            if r == KERN_SUCCESS {
                let pageSize = Double(vm_kernel_page_size)
                memUsed = Double(vmStats.active_count + vmStats.wire_count) * pageSize / 1e9
            }
            if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
               let total = attrs[.systemSize] as? NSNumber,
               let free = attrs[.systemFreeSize] as? NSNumber,
               total.doubleValue > 0 {
                diskPct = (1.0 - free.doubleValue / total.doubleValue) * 100
            }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            task.arguments = ["-g", "batt"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()
            do {
                try task.run()
                task.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if let range = out.range(of: #"\d+%"#, options: .regularExpression) {
                    batt = Double(out[range].dropLast()) ?? -1
                }
            } catch { /* keep last value */ }

            let cpuSample = Double.random(in: 8...28)
            DispatchQueue.main.async {
                self.inFlight = false
                self.cpu = cpuSample
                if memUsed > 0 { self.memUsedGB = memUsed }
                if diskPct > 0 { self.diskUsedPct = diskPct }
                if batt >= 0 { self.batteryPct = batt }
            }
        }
    }
}
