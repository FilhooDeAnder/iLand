import Foundation
import Darwin

/// Finds only executable resources owned by this user and not writable by others.
/// Search is anchored to the executable, never to the current working directory.
enum SensorExecutable {
    static func find(executablePath: String, resourcePath: String?) -> String? {
        var candidates: [String] = []
        if let resourcePath { candidates.append((resourcePath as NSString).appendingPathComponent("sensors")) }
        var directory = (executablePath as NSString).deletingLastPathComponent as NSString
        for _ in 0...3 {
            candidates.append(directory.appendingPathComponent("Resources/sensors"))
            candidates.append(directory.appendingPathComponent("sensors"))
            directory = directory.deletingLastPathComponent as NSString
        }
        return candidates.first { path in
            var info = stat()
            return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid()
                && (info.st_mode & (S_IWGRP | S_IWOTH)) == 0 && access(path, X_OK) == 0
        }
    }
}
