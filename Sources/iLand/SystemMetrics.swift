import Foundation
import Darwin
import IOKit.ps

struct Metrics {
    var cores: [Double] = []      // 0-100 por núcleo
    var cpuTotal = 0.0
    var memUsed: UInt64 = 0
    var memTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure = 1              // 1 normal, 2 atenção, 4 crítica
    var netDown = 0.0             // bytes/s
    var netUp = 0.0
    var battery: Int?
    var charging = false
    var diskUsedFraction = 0.0
    var diskFree: UInt64 = 0       // bytes livres para uso "importante" (conta o que o macOS pode limpar)
    var diskTotal: UInt64 = 0
}

final class MetricsSampler {
    private var lastTicks: [[UInt32]] = []
    private var lastNet: (down: UInt32, up: UInt32, at: Date)?
    // A leitura do disco ("capacidade importante") faz o macOS perguntar ao Fotos e a outros serviços
    // quanto espaço podem limpar. Em cada ciclo, isso deixou o photolibraryd com CPU alta (2026-11-06).
    // Por isso, o disco é lido só na abertura e no botão Atualizar (decisão do Anderson).
    private var diskCache: (free: UInt64, total: UInt64, used: Double)?
    private var diskStale = true

    /// Pede uma leitura nova do disco na próxima amostra. Chamar só na fila do SystemMonitor.
    func refreshDisk() { diskStale = true }

    func sample() -> Metrics {
        var m = Metrics()
        (m.cores, m.cpuTotal) = cpu()
        memory(&m)
        network(&m)
        power(&m)
        if diskStale { disk(&m); diskStale = false; if m.diskTotal > 0 { diskCache = (m.diskFree, m.diskTotal, m.diskUsedFraction) } }
        if let d = diskCache { (m.diskFree, m.diskTotal, m.diskUsedFraction) = (d.free, d.total, d.used) }
        return m
    }

    private func cpu() -> ([Double], Double) {
        var n: natural_t = 0
        var info: processor_info_array_t?
        var cnt: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt) == KERN_SUCCESS, let info else { return ([], 0) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(cnt) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        var ticks: [[UInt32]] = []
        for i in 0..<Int(n) { ticks.append((0..<states).map { UInt32(bitPattern: info[i * states + $0]) }) }
        defer { lastTicks = ticks }
        guard lastTicks.count == ticks.count else { return ([], 0) }

        var cores: [Double] = []
        var busyAll = 0.0, totalAll = 0.0
        for (now, before) in zip(ticks, lastTicks) {
            let d = (0..<states).map { Double(now[$0] &- before[$0]) }
            let total = d.reduce(0, +)
            let busy = total - d[Int(CPU_STATE_IDLE)]
            cores.append(total > 0 ? busy / total * 100 : 0)
            busyAll += busy
            totalAll += total
        }
        return (cores, totalAll > 0 ? busyAll / totalAll * 100 : 0)
    }

    private func memory(_ m: inout Metrics) {
        var s = vm_statistics64()
        var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c) }
        }
        if r == KERN_SUCCESS {
            let page = UInt64(getpagesize())
            let pages = UInt64(s.internal_page_count) - UInt64(s.purgeable_count) + UInt64(s.wire_count) + UInt64(s.compressor_page_count)
            m.memUsed = pages * page
        }
        m.memTotal = Foundation.ProcessInfo.processInfo.physicalMemory

        var sw = xsw_usage()
        var sz = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &sw, &sz, nil, 0) == 0 { m.swapUsed = sw.xsu_used }

        var p: Int32 = 1
        var psz = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &p, &psz, nil, 0) == 0 { m.pressure = Int(p) }
    }

    // loop-debt: contador de 32 bits (ifi_ibytes) dá a volta em 4 GB; o delta com &- cobre uma volta por amostra.
    private func network(_ m: inout Metrics) {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return }
        defer { freeifaddrs(ifap) }
        var down: UInt32 = 0, up: UInt32 = 0
        var ptr = ifap
        while let a = ptr {
            if a.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               String(cString: a.pointee.ifa_name).hasPrefix("en"),
               let d = a.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                down = down &+ d.pointee.ifi_ibytes
                up = up &+ d.pointee.ifi_obytes
            }
            ptr = a.pointee.ifa_next
        }
        let now = Date()
        if let last = lastNet {
            let dt = now.timeIntervalSince(last.at)
            if dt > 0 {
                m.netDown = Double(down &- last.down) / dt
                m.netUp = Double(up &- last.up) / dt
            }
        }
        lastNet = (down, up, now)
    }

    private func power(_ m: inout Metrics) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  let cap = d[kIOPSCurrentCapacityKey] as? Int else { continue }
            m.battery = cap
            m.charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
        }
    }

    private func disk(_ m: inout Metrics) {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity, total > 0 else { return }
        m.diskFree = UInt64(max(0, free))
        m.diskTotal = UInt64(total)
        m.diskUsedFraction = 1 - Double(free) / Double(total)
    }
}

enum ProcessSampler {
    static func sample() -> [ProcSample] {
        guard let out = run(["-Ao", "pid=,ppid=,uid=,pcpu=,rss=,etime=,tty=,comm="]) else { return [] }
        var list: [ProcSample] = []
        let now = Date()
        for line in out.split(separator: "\n") {
            let f = line.split(maxSplits: 7, omittingEmptySubsequences: true, whereSeparator: { $0 == " " })
            guard f.count == 8, let pid = Int32(f[0]), let ppid = Int32(f[1]), let uid = UInt32(f[2]),
                  let cpu = Double(f[3].replacingOccurrences(of: ",", with: ".")), let rss = Int(f[4]) else { continue }
            list.append(ProcSample(pid: pid, ppid: ppid, uid: uid, cpu: cpu, rssKB: rss,
                                   elapsed: parseElapsed(String(f[5])),
                                   tty: f[6].hasPrefix("tty") ? String(f[6]) : "",
                                   path: f[7].trimmingCharacters(in: .whitespaces),
                                   startedAt: now.addingTimeInterval(-parseElapsed(String(f[5])))))
        }
        return list.sorted { $0.cpu > $1.cpu }
    }

    /// Caminho e hora de início do processo que tem esse PID agora (nil se não existe mais).
    static func identity(pid: Int32) -> (path: String, startedAt: Date)? {
        guard let out = run(["-o", "etime=,comm=", "-p", String(pid)]) else { return nil }
        let f = out.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0 == " " })
        guard f.count == 2 else { return nil }
        return (f[1].trimmingCharacters(in: .whitespacesAndNewlines), Date().addingTimeInterval(-parseElapsed(String(f[0]))))
    }

    static func args(pid: Int32) -> String {
        run(["-o", "args=", "-p", String(pid)]) ?? ""
    }

    /// [[dd-]hh:]mm:ss
    static func parseElapsed(_ s: String) -> TimeInterval {
        var days = 0.0
        var rest = Substring(s)
        if let dash = s.firstIndex(of: "-") {
            days = Double(s[..<dash]) ?? 0
            rest = s[s.index(after: dash)...]
        }
        let secs = rest.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
        return days * 86400 + secs
    }

    private static func run(_ arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
