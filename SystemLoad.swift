import Foundation
import Darwin

// MARK: - Lightweight system-pressure sampling
//
// Two cheap signals Navi uses to decide whether to keep flying or just hover:
//   • cpuBusyFraction() — system-wide busy ratio since the previous call (delta of
//     kernel CPU ticks). Catches genuine CPU saturation (VM builds, etc.).
//   • loadPerCore()     — 1-minute load average normalised by core count.
//
// Neither perfectly captures WindowServer compositing pressure, but together they're
// a good-enough, near-zero-cost proxy for "the machine is working hard right now".

final class SystemLoad {
    // mach_host_self() hands back a port send-right that accrues a reference per call,
    // so grab it once for the app's lifetime rather than leaking one every sample.
    private let host = mach_host_self()
    private let cores = Double(ProcessInfo.processInfo.activeProcessorCount)

    private var prevBusy: UInt64 = 0
    private var prevTotal: UInt64 = 0

    /// System-wide busy fraction (0...1) over the interval since the last call.
    /// The first call primes the baseline and returns 0.
    func cpuBusyFraction() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride
                                           / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(host, HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }

        // cpu_ticks order: user, system, idle, nice.
        let user   = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle   = UInt64(info.cpu_ticks.2)
        let nice   = UInt64(info.cpu_ticks.3)
        let busy   = user &+ system &+ nice
        let total  = busy &+ idle

        defer { prevBusy = busy; prevTotal = total }
        let dTotal = total &- prevTotal
        let dBusy  = busy &- prevBusy
        guard prevTotal != 0, dTotal > 0 else { return 0 }
        return min(1.0, max(0.0, Double(dBusy) / Double(dTotal)))
    }

    /// 1-minute load average divided by core count (≈ "how many cores deep" the queue is).
    func loadPerCore() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        let n = getloadavg(&loads, 3)
        guard n > 0, cores > 0 else { return 0 }
        return loads[0] / cores
    }
}
