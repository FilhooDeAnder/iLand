// Uso: swiftc -parse-as-library Sources/iLand/SuspectTracker.swift Sources/iLand/History.swift test_history.swift -o /tmp/t_hist && /tmp/t_hist
import Foundation

@main struct HistoryCheck {
    static func main() {
        var r = RingBuffer<Int>(capacity: 3)
        assert(r.values.isEmpty && r.last == nil)
        r.append(1); r.append(2)
        assert(r.values == [1, 2] && r.last == 2)
        r.append(3); r.append(4); r.append(5)
        assert(r.values == [3, 4, 5] && r.last == 5 && r.count == 3, "cheia: descarta o mais antigo")
        for i in 0..<1000 { r.append(i) }
        assert(r.count == 3 && r.values == [997, 998, 999], "nunca passa da capacidade")

        let out = """
        Processes: 600 total
        PID    POWER
        80864  0.0
        17250  0.0
        Processes: 601 total
        Load Avg: 1.2, 1.1, 1.0
        PID    POWER
        80864  65.6
        17250  28.0
        48522  9.4
        48546  3.6
        2464   8.9
        999    0.0
        """
        let p = EnergyRank.parse(out)
        assert(p[80864] == 65.6 && p[17250] == 28.0 && p.count == 6, "vale o último bloco")

        func s(_ pid: Int32, _ path: String) -> ProcSample { ProcSample(pid: pid, ppid: 1, uid: 501, cpu: 0, rssKB: 0, elapsed: 0, tty: "", path: path) }
        let procs = [s(80864, "/usr/libexec/mediaanalysisd"), s(17250, "/System/Library/WindowServer"),
                     s(48522, "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"),
                     s(48546, "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)")]
        let top = EnergyRank.top(p, processes: procs, exclude: 2464, limit: 5)
        assert(top.map(\.name) == ["mediaanalysisd", "WindowServer", "Claude"], "agrupa por app, tira o top e quem está zerado")
        assert(abs(top[2].impact - 13.0) < 0.001)
        assert(EnergyRank.top(p, processes: [], limit: 2).count == 2)
        print("ok")
    }
}
