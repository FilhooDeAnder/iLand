// Uso: swiftc -parse-as-library Sources/iLand/SensorExecutable.swift Tests/Unit/test_sensor.swift -o /tmp/t_sensor && /tmp/t_sensor
import Foundation
import Darwin

@main struct SensorExecutableCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + " space")
        defer { try? FileManager.default.removeItem(at: root) }
        func file(_ path: String, mode: Int = 0o700) throws -> String {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            return url.path
        }
        let executable = try file("repo/.build/arm64-apple-macosx/release/iLand")
        let sensor = try file("repo/Resources/sensors")
        assert(SensorExecutable.find(executablePath: executable, resourcePath: nil) == sensor, "dev resolves Resources/sensors from executable, regardless of cwd")
        let app = try file("iLand.app/Contents/MacOS/iLand")
        let bundled = try file("iLand.app/Contents/Resources/sensors")
        let resources = root.appendingPathComponent("iLand.app/Contents/Resources").path
        assert(SensorExecutable.find(executablePath: app, resourcePath: resources) == bundled, "installed bundle keeps its resource path, including spaces")
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: bundled)
        assert(SensorExecutable.find(executablePath: app, resourcePath: resources) == nil, "rejects executable writable by other users")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sensor)
        assert(SensorExecutable.find(executablePath: executable, resourcePath: nil) == nil, "rejects non-executable resource")
        assert(SensorExecutable.find(executablePath: root.appendingPathComponent("missing/iLand").path, resourcePath: nil) == nil, "missing resource is safe")
        print("Sensor resource paths passed")
    }
}
