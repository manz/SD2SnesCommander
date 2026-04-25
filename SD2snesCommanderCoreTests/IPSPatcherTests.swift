import Foundation
import Testing
@testable import SD2snesCommanderCore

struct IPSPatcherTests {
    // MARK: - Helpers

    private func writeTempFile(_ data: Data, ext: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ipstest_\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    private func ipsHeader() -> Data { Data("PATCH".utf8) }
    private func ipsFooter() -> Data { Data("EOF".utf8) }

    private func ipsRecord(offset: Int, payload: Data) -> Data {
        var d = Data()
        d.append(UInt8((offset >> 16) & 0xFF))
        d.append(UInt8((offset >> 8) & 0xFF))
        d.append(UInt8(offset & 0xFF))
        let size = payload.count
        d.append(UInt8((size >> 8) & 0xFF))
        d.append(UInt8(size & 0xFF))
        d.append(payload)
        return d
    }

    private func ipsRleRecord(offset: Int, count: Int, fill: UInt8) -> Data {
        var d = Data()
        d.append(UInt8((offset >> 16) & 0xFF))
        d.append(UInt8((offset >> 8) & 0xFF))
        d.append(UInt8(offset & 0xFF))
        d.append(0x00) // size = 0 -> RLE
        d.append(0x00)
        d.append(UInt8((count >> 8) & 0xFF))
        d.append(UInt8(count & 0xFF))
        d.append(fill)
        return d
    }

    // MARK: - Header / structure

    @Test func rejectsMissingPatchHeader() throws {
        let rom = try writeTempFile(Data([0, 0, 0, 0]), ext: "smc")
        let bogus = try writeTempFile(Data("NOTAPATCH".utf8 + ipsFooter()), ext: "ips")
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("out_\(UUID().uuidString).smc")
        defer {
            try? FileManager.default.removeItem(at: rom)
            try? FileManager.default.removeItem(at: bogus)
            try? FileManager.default.removeItem(at: out)
        }

        #expect(throws: IPSPatcher.IPSError.self) {
            try IPSPatcher.applyPatch(romPath: rom.path, ipsPath: bogus.path, outputPath: out.path)
        }
    }

    @Test func rejectsTooShortFile() throws {
        let rom = try writeTempFile(Data([0, 0]), ext: "smc")
        let tiny = try writeTempFile(Data("PATCH".utf8), ext: "ips")
        defer {
            try? FileManager.default.removeItem(at: rom)
            try? FileManager.default.removeItem(at: tiny)
        }

        #expect(throws: IPSPatcher.IPSError.self) {
            try IPSPatcher.applyPatch(
                romPath: rom.path,
                ipsPath: tiny.path,
                outputPath: NSTemporaryDirectory() + "x.smc"
            )
        }
    }

    // MARK: - Normal patch records

    @Test func appliesSingleNormalRecord() throws {
        let rom = Data(repeating: 0xAA, count: 16)
        let romURL = try writeTempFile(rom, ext: "smc")

        var ips = ipsHeader()
        ips.append(ipsRecord(offset: 4, payload: Data([0x11, 0x22, 0x33])))
        ips.append(ipsFooter())
        let ipsURL = try writeTempFile(ips, ext: "ips")

        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("out_\(UUID().uuidString).smc")
        defer {
            try? FileManager.default.removeItem(at: romURL)
            try? FileManager.default.removeItem(at: ipsURL)
            try? FileManager.default.removeItem(at: outURL)
        }

        try IPSPatcher.applyPatch(romPath: romURL.path, ipsPath: ipsURL.path, outputPath: outURL.path)

        let result = try Data(contentsOf: outURL)
        let expected = Data([0xAA, 0xAA, 0xAA, 0xAA, 0x11, 0x22, 0x33] + [UInt8](repeating: 0xAA, count: 9))
        #expect(result == expected)
    }

    @Test func extendsROMWhenPatchOverflowsEnd() throws {
        let rom = Data(repeating: 0x00, count: 4)
        let romURL = try writeTempFile(rom, ext: "smc")

        var ips = ipsHeader()
        ips.append(ipsRecord(offset: 6, payload: Data([0xDE, 0xAD])))
        ips.append(ipsFooter())
        let ipsURL = try writeTempFile(ips, ext: "ips")

        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("out_\(UUID().uuidString).smc")
        defer {
            try? FileManager.default.removeItem(at: romURL)
            try? FileManager.default.removeItem(at: ipsURL)
            try? FileManager.default.removeItem(at: outURL)
        }

        try IPSPatcher.applyPatch(romPath: romURL.path, ipsPath: ipsURL.path, outputPath: outURL.path)

        let result = try Data(contentsOf: outURL)
        // 4 zeros (original), 2 zero-extended bytes at offsets 4..5, then DE AD at 6..7.
        let expected = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xDE, 0xAD])
        #expect(result == expected)
    }

    // MARK: - RLE records

    @Test func appliesRLERecord() throws {
        let rom = Data(repeating: 0x55, count: 8)
        let romURL = try writeTempFile(rom, ext: "smc")

        var ips = ipsHeader()
        ips.append(ipsRleRecord(offset: 2, count: 4, fill: 0xFF))
        ips.append(ipsFooter())
        let ipsURL = try writeTempFile(ips, ext: "ips")

        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("out_\(UUID().uuidString).smc")
        defer {
            try? FileManager.default.removeItem(at: romURL)
            try? FileManager.default.removeItem(at: ipsURL)
            try? FileManager.default.removeItem(at: outURL)
        }

        try IPSPatcher.applyPatch(romPath: romURL.path, ipsPath: ipsURL.path, outputPath: outURL.path)

        let result = try Data(contentsOf: outURL)
        let expected = Data([0x55, 0x55, 0xFF, 0xFF, 0xFF, 0xFF, 0x55, 0x55])
        #expect(result == expected)
    }

    // MARK: - findIPSPatch

    @Test func findsSiblingIPSWithMatchingBaseName() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ipsfind_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rom = dir.appendingPathComponent("game.sfc")
        let ips = dir.appendingPathComponent("game.ips")
        try Data().write(to: rom)
        try Data().write(to: ips)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(IPSPatcher.findIPSPatch(for: rom.path) == ips.path)
    }

    @Test func returnsNilWhenNoSiblingIPS() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ipsfind_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rom = dir.appendingPathComponent("lonely.sfc")
        try Data().write(to: rom)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(IPSPatcher.findIPSPatch(for: rom.path) == nil)
    }
}
