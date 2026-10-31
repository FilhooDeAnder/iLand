import Foundation
import IOKit
import UserNotifications

/// Potência em watts, lida do registro IOKit da bateria (AppleSmartBattery). Barato; só é lido com o painel aberto.
struct PowerReading {
    var system: Double?    // W que o Mac está consumindo (PowerTelemetryData.SystemLoad)
    var battery: Double?   // W entrando (+, carregando) ou saindo (-) da bateria: corrente x tensão
}

enum PowerReader {
    static func read() -> PowerReading? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        func prop(_ k: String) -> Any? { IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
        var r = PowerReading()
        if let a = (prop("Amperage") as? NSNumber)?.int64Value, let v = (prop("Voltage") as? NSNumber)?.int64Value, v > 0 {
            r.battery = Double(a) * Double(v) / 1_000_000   // mA x mV -> W
        }
        if let t = prop("PowerTelemetryData") as? [String: Any], let load = (t["SystemLoad"] as? NSNumber)?.doubleValue, load > 0 {
            r.system = load / 1000                          // mW -> W
        }
        return r.system == nil && r.battery == nil ? nil : r
    }
}

/// Roda `top -l 2 -stats pid,power` (~1 s de CPU de sistema por chamada) fora da fila do monitor, no máximo a cada 10 s.
/// Quem chama garante que é só com a aba Gráficos visível.
final class EnergyTop {
    static let every: TimeInterval = 10
    private let lock = NSLock()
    private var running = false
    private var lastStart = Date.distantPast
    private var result: (at: Date, power: [Int32: Double], topPid: Int32)?

    /// Último resultado com menos de 30 s (nil = ainda medindo).
    func latest(now: Date) -> (power: [Int32: Double], topPid: Int32)? {
        lock.lock(); defer { lock.unlock() }
        guard let r = result, now.timeIntervalSince(r.at) < 30 else { return nil }
        return (r.power, r.topPid)
    }

    func pollIfDue(now: Date) {
        lock.lock()
        guard !running, now.timeIntervalSince(lastStart) >= Self.every else { lock.unlock(); return }
        running = true
        lastStart = now
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = Self.run()
            guard let self else { return }
            self.lock.lock()
            if let r { self.result = (Date(), r.power, r.pid) }
            self.running = false
            self.lock.unlock()
        }
    }

    private static func run() -> (power: [Int32: Double], pid: Int32)? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        task.arguments = ["-l", "2", "-n", "15", "-o", "power", "-stats", "pid,power"]
        task.environment = ["LC_ALL": "C"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let pid = task.processIdentifier
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, let out = String(data: data, encoding: .utf8) else { return nil }
        return (EnergyRank.parse(out), pid)
    }
}

/// Notificação do macOS. Com bundle (iLand.app): UNUserNotificationCenter (pede autorização uma vez).
/// Binário solto (.build/release/iLand) ou autorização negada: `osascript`, com título e texto como argv do script
/// (`on run argv`), nunca interpolados em código AppleScript nem em shell.
enum Notifier {
    private static let lock = NSLock()
    private static var authorized: Bool?   // nil = ainda não perguntou

    static func send(_ a: Alert) { send(title: a.title, message: a.message, id: a.kind.rawValue) }

    static func send(title: String, message: String, id: String) {
        let a = Note(title: title, message: message, id: id)
        guard Bundle.main.bundleIdentifier != nil else { return osascript(a) }
        let center = UNUserNotificationCenter.current()
        lock.lock(); let auth = authorized; lock.unlock()
        if let auth { return auth ? post(a, center) : osascript(a) }
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            lock.lock(); authorized = ok; lock.unlock()
            ok ? post(a, center) : osascript(a)
        }
    }

    private struct Note { let title: String; let message: String; let id: String }

    private static func post(_ a: Note, _ center: UNUserNotificationCenter) {
        let c = UNMutableNotificationContent()
        c.title = a.title
        c.body = a.message
        center.add(UNNotificationRequest(identifier: "iland.\(a.id)", content: c, trigger: nil)) { err in
            if err != nil { osascript(a) }
        }
    }

    private static func osascript(_ a: Note) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)", "-e", "end run",
                          a.title, a.message]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        DispatchQueue.global(qos: .utility).async {
            do { try task.run(); task.waitUntilExit() } catch {}
        }
    }
}
