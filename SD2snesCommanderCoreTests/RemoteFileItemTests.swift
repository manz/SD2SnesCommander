import Testing
@testable import SD2snesCommanderCore

struct RemoteFileItemTests {
    @Test func detectsROMExtensionsCaseInsensitively() {
        for ext in ["smc", "SMC", "sfc", "SFC", "fig", "swc", "bs", "gb"] {
            let item = RemoteFileItem(name: "game.\(ext)", isDirectory: false)
            #expect(item.isRomFile, "expected \(ext) to be a ROM extension")
        }
    }

    @Test func ignoresNonROMExtensions() {
        for name in ["save.srm", "readme.txt", "music.pcm", "patch.ips", "noext"] {
            let item = RemoteFileItem(name: name, isDirectory: false)
            #expect(!item.isRomFile, "expected \(name) to be reported as non-ROM")
        }
    }

    @Test func directoriesStillReportExtensionMatch() {
        // Existing semantics: isRomFile only inspects the extension, not the
        // file/directory flag. Locked in so a refactor can't quietly drift.
        let item = RemoteFileItem(name: "weird.sfc", isDirectory: true)
        #expect(item.isRomFile)
    }

    @Test func codableRoundTrip() throws {
        let original = RemoteFileItem(name: "Hack/game.sfc", isDirectory: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RemoteFileItem.self, from: data)
        #expect(decoded.name == original.name)
        #expect(decoded.isDirectory == original.isDirectory)
    }
}
