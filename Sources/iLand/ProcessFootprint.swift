import Foundation
import Darwin

/// Leituras da guarda de processos (spec: docs/superpowers/specs/2026-11-06-guarda-de-processos-design.md).
enum ProcessFootprint {
    /// Memória total do processo (coluna "Memória" do Monitor de Atividade: conta comprimido e swap). nil sem acesso.
    static func bytes(_ pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return r == 0 ? info.ri_phys_footprint : nil
    }

    static let swapCeiling: Double = 8 * 1024   // MB. Baixo de propósito: o jetsam de 2026-11-06 veio com ~13 GB de swap.

    /// Folga em MB: RAM disponível + o que ainda cabe no teto de swap. ILAND_GUARD_HEADROOM_MB força um valor (teste).
    static func headroomMB(swapUsed: UInt64) -> Double {
        if let s = ProcessInfo.processInfo.environment["ILAND_GUARD_HEADROOM_MB"], let v = Double(s) { return v }
        var s = vm_statistics64()
        var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c) }
        }
        guard r == KERN_SUCCESS else { return .infinity }
        let pages = Double(s.free_count) + Double(s.inactive_count) + Double(s.speculative_count) + Double(s.purgeable_count)
        let ram = pages * Double(getpagesize()) / 1_048_576
        return ram + max(0, swapCeiling - Double(swapUsed) / 1_048_576)
    }

    /// Pode ser encerrado sozinho: do usuário, fora da Apple, fora de app (menos app de teste/dev).
    static func isDev(path: String, uid: UInt32) -> Bool {
        guard uid == getuid() else { return false }
        if ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"].contains(where: path.hasPrefix) { return false }
        guard path.contains(".app/") else { return true }
        return ["/Library/Caches/", "/node_modules/", "/DerivedData/", "/var/folders/"].contains(where: path.contains)
    }

    /// Sessões do Claude que já morreram (o processo `claude` gravado pelo hook SessionStart sumiu).
    static func deadSessions() -> Set<String> {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/processos/sessoes")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var dead = Set<String>()
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let pid = j["pid"] as? Int, let start = j["inicio"] as? Double else { continue }
            if let id = ProcessSampler.identity(pid: Int32(pid)), abs(id.startedAt.timeIntervalSince1970 - start) < 3, id.path.hasSuffix("claude") { continue }
            dead.insert(f.deletingPathExtension().lastPathComponent)
        }
        return dead
    }

    /// "subagente do Claude em CRM-loop", "sessão do Claude em CRM-loop" ou "deixado por sessão encerrada em CRM-loop".
    static func describe(owner: String, dead: Set<String>) -> String {
        let f = owner.split(separator: ":", maxSplits: 2).map(String.init)
        guard f.count == 3 else { return "" }
        if dead.contains(f[0]) { return "deixado por sessão encerrada em \(f[2])" }
        return f[1] == "main" ? "sessão do Claude em \(f[2])" : "subagente do Claude em \(f[2])"
    }

    /// Linha para o dono ler na próxima ação (hook pendente.sh do Claude).
    static func tellOwner(_ owner: String, _ text: String) {
        guard let sid = owner.split(separator: ":").first, sid.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/processos/pendente")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(sid).txt")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        h.seekToEndOfFile(); h.write(Data((text + "\n").utf8)); try? h.close()
    }

    /// Hora de início exata (segundos), para a chave PID + início não variar entre amostras.
    static func start(_ pid: Int32) -> Int? {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return n == Int32(MemoryLayout<proc_bsdinfo>.size) ? Int(info.pbi_start_tvsec) : nil
    }

    /// Registro de todo encerramento automático. Nada some sem rastro.
    static func logKill(_ line: [String: Any]) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/iLand")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("encerrados.jsonl")
        guard let d = try? JSONSerialization.data(withJSONObject: line) else { return }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        h.seekToEndOfFile(); h.write(d + Data("\n".utf8)); try? h.close()
    }

    static func recentKills(_ n: Int = 5) -> [[String: Any]] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/iLand/encerrados.jsonl")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").suffix(n).reversed().compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    /// Marcas de todos os processos do usuário numa chamada só: pid -> marca.
    static func allOwners() -> [Int32: String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Eww", "-U", String(getuid()), "-o", "pid=,command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [:] }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        task.waitUntilExit()
        var res: [Int32: String] = [:]
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " "), let pid = Int32(t[..<sp]),
                  let r = t.range(of: #"(?:^|\s)CLAUDE_PROC_OWNER=[0-9A-Za-z_-]+:[0-9A-Za-z_-]+:[^\s']*"#, options: [.regularExpression, .backwards]) else { continue }
            res[pid] = String(t[r]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "CLAUDE_PROC_OWNER=", with: "")
        }
        return res
    }

    /// Apaga o arquivo da sessão morta que não deixou nada vivo.
    static func forgetSession(_ sid: String) {
        let f = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/processos/sessoes/\(sid).json")
        try? FileManager.default.removeItem(at: f)
    }
}
