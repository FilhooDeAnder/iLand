// Uso: swiftc -parse-as-library Sources/iLand/ScreenTools.swift Sources/iLand/Notes.swift Tests/Unit/test_screentools.swift -o /tmp/t_scr && /tmp/t_scr
import Foundation

@main struct ScreenToolsCheck {
    static func main() {
        let c = RGB(r: 255, g: 128, b: 0)
        assert(c.hex == "#FF8000" && c.css == "rgb(255, 128, 0)" && c.hsl == "hsl(30, 100%, 50%)", "\(c.hex) \(c.hsl)")
        assert(RGB(r: 0, g: 0, b: 0).hsl == "hsl(0, 0%, 0%)" && RGB(r: 255, g: 255, b: 255).hex == "#FFFFFF")
        assert(RGB(r: 0, g: 0, b: 255).hsl == "hsl(240, 100%, 50%)")
        assert(RGB(r: 51, g: 102, b: 153).swiftUI == "Color(red: 0.200, green: 0.400, blue: 0.600)")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iland-notes-test-\(UUID().uuidString)")
        let n = NotesModel(directory: dir)
        assert(n.text.isEmpty)
        n.text = "olá, notas"; n.saveNow()
        assert(NotesModel(directory: dir).text == "olá, notas", "recarrega o que foi salvo")
        let attrs = try! FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("notes.txt").path)
        assert((attrs[.posixPermissions] as! Int) & 0o077 == 0, "arquivo só do usuário")
        try? FileManager.default.removeItem(at: dir)
        print("ok")
    }
}
