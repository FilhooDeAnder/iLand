// Uso: swiftc -parse-as-library Sources/iLand/SuspectTracker.swift test_supervisor.swift -o /tmp/t_sup && /tmp/t_sup
import Foundation

func sample(_ pid: Int32, ppid: Int32 = 1, cpu: Double, path: String) -> ProcSample {
    ProcSample(pid: pid, ppid: ppid, uid: 501, cpu: cpu, rssKB: 1000, elapsed: 60, tty: "", path: path)
}

@main struct SupervisorCheck {
    static func main() {
        var t = SuspectTracker()
        let t0 = Date()
        let yes = sample(10, cpu: 97, path: "/usr/bin/yes")
        assert(t.update([yes], now: t0).isEmpty, "não pode ser suspeito de imediato")
        assert(t.update([yes], now: t0.addingTimeInterval(299)).isEmpty, "antes de 5 min")
        assert(t.update([yes], now: t0.addingTimeInterval(301)) == [10], "depois de 5 min")
        assert(t.update([sample(10, cpu: 20, path: "/usr/bin/yes")], now: t0.addingTimeInterval(302)).isEmpty, "caiu: zera")
        assert(t.update([yes], now: t0.addingTimeInterval(303)).isEmpty, "recomeça a contagem")

        assert(Origin.hint(for: yes, args: "yes").contains("sem processo pai"))
        let chrome = sample(11, ppid: 5, cpu: 98, path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        assert(Origin.hint(for: chrome, args: "--user-data-dir=/x/puppeteer_dev_chrome_profile-abc").contains("automação"))
        assert(chrome.appName == "Google Chrome")
        let daemon = sample(12, cpu: 90, path: "/usr/libexec/spotlightknowledged.updater")
        assert(Origin.hint(for: daemon, args: "").isEmpty, "daemon do sistema não é órfão")
        let sh = sample(20, ppid: 21, cpu: 1, path: "/bin/sh")
        let cl = sample(21, ppid: 22, cpu: 1, path: "/Users/x/claude")
        let app = sample(22, ppid: 1, cpu: 1, path: "/Applications/Claude.app/Contents/MacOS/Claude")
        let child = sample(23, ppid: 20, cpu: 90, path: "/usr/bin/yes")
        assert(Origin.chain([sh, cl, app]).map(\.name) == ["sh", "claude", "Claude"])
        assert(Origin.chain([sh, sh, app]).map(\.name) == ["sh", "Claude"], "repetidos em sequência viram um")
        assert(Origin.hint(for: child, args: "yes").contains("sem processo pai") == false, "tem pai: não é órfão")
        let dead = sample(30, ppid: 1, cpu: 1, path: "/bin/sh")
        assert(Origin.hint(for: sample(31, ppid: 30, cpu: 90, path: "/usr/bin/yes"), ancestors: [dead], args: "yes") == "quem iniciou já fechou")
        assert(sample(1, cpu: 1, path: "/sbin/launchd").isProtected && sample(5, cpu: 1, path: "/System/Library/WindowServer").name == "WindowServer")
        assert(!yes.isProtected)
        assert(ProcTarget(pid: 1, path: "/usr/bin/yes", startedAt: t0).matches(path: "/usr/bin/yes", startedAt: t0.addingTimeInterval(2)))
        assert(!ProcTarget(pid: 1, path: "/usr/bin/yes", startedAt: t0).matches(path: "/usr/bin/yes", startedAt: t0.addingTimeInterval(60)), "PID reutilizado")
        assert(!ProcTarget(pid: 1, path: "/usr/bin/yes", startedAt: t0).matches(path: "/bin/sleep", startedAt: t0), "outro programa")
        assert(Redact.command("node app.js --token abc123 --port 3000") == "node app.js --token ••• --port 3000")
        assert(Redact.command("curl -H 'Authorization: Bearer abc.def' x").contains("Bearer •••"))
        assert(Redact.command("AWS_SECRET_ACCESS_KEY=xyz run") == "AWS_SECRET_ACCESS_KEY=••• run")
        assert(Redact.command("psql postgres://user:pa55@host/db").contains("://•••@") && !Redact.command("psql postgres://user:pa55@host/db").contains("pa55"))
        assert(!Redact.command("claude --key sk-ant-api03-abcdefghij").contains("abcdefghij"))
        assert(Redact.command("ls -la /tmp") == "ls -la /tmp")
        print("ok")
    }
}
