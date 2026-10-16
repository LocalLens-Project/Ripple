import Foundation

struct EditSession: Codable {
    let source: URL
    let filename: String
    let effects: [ClickEffect]
    let selectedID: UUID?
    let currentTime: Double
    var glassEffects: [GlassEffect]?
    var selectedGlassID: UUID?

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ripple", isDirectory: true)
    }
    static var file: URL { directory.appendingPathComponent("CurrentEdit.json") }
}
