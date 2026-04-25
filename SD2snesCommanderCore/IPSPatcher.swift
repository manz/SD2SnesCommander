import Foundation

public struct IPSPatcher {
    public enum IPSError: Error, LocalizedError {
        case invalidIPSFile
        case fileTooLarge
        case readError
        case writeError
        case invalidPatch

        public var errorDescription: String? {
            switch self {
            case .invalidIPSFile:
                return "Invalid IPS file format"
            case .fileTooLarge:
                return "File too large for IPS patching"
            case .readError:
                return "Failed to read file"
            case .writeError:
                return "Failed to write patched file"
            case .invalidPatch:
                return "Invalid patch data"
            }
        }
    }

    public static func applyPatch(romPath: String, ipsPath: String, outputPath: String) throws {
        guard let romData = try? Data(contentsOf: URL(fileURLWithPath: romPath)) else {
            throw IPSError.readError
        }

        guard let ipsData = try? Data(contentsOf: URL(fileURLWithPath: ipsPath)) else {
            throw IPSError.readError
        }

        let patchedData = try applyIPSPatch(to: romData, patch: ipsData)

        do {
            try patchedData.write(to: URL(fileURLWithPath: outputPath))
        } catch {
            throw IPSError.writeError
        }
    }

    public static func createTemporaryPatchedFile(romPath: String, ipsPath: String) throws -> String {
        let romURL = URL(fileURLWithPath: romPath)
        let tempFileName = "patched_\(UUID().uuidString)_\(romURL.lastPathComponent)"
        let tempPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(tempFileName).path

        try applyPatch(romPath: romPath, ipsPath: ipsPath, outputPath: tempPath)
        return tempPath
    }

    public static func findIPSPatch(for romPath: String) -> String? {
        let romURL = URL(fileURLWithPath: romPath)
        let romDirectory = romURL.deletingLastPathComponent()
        let romName = romURL.deletingPathExtension().lastPathComponent

        for ext in ["ips", "IPS"] {
            let candidate = romDirectory.appendingPathComponent("\(romName).\(ext)").path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func applyIPSPatch(to romData: Data, patch ipsData: Data) throws -> Data {
        guard ipsData.count >= 8 else {
            throw IPSError.invalidIPSFile
        }

        // Header "PATCH"
        let header = ipsData.subdata(in: 0..<5)
        guard String(data: header, encoding: .ascii) == "PATCH" else {
            throw IPSError.invalidIPSFile
        }

        var patchedData = Data(romData)
        var offset = 5

        while offset < ipsData.count - 3 {
            // EOF marker
            let eofMarker = ipsData.subdata(in: offset..<offset+3)
            if eofMarker == Data([0x45, 0x4F, 0x46]) { // "EOF"
                break
            }

            guard offset + 5 <= ipsData.count else {
                throw IPSError.invalidPatch
            }

            // 24-bit offset
            let offsetBytes = ipsData.subdata(in: offset..<offset+3)
            let patchOffset = Int(offsetBytes[0]) << 16 | Int(offsetBytes[1]) << 8 | Int(offsetBytes[2])
            offset += 3

            // 16-bit size
            let sizeBytes = ipsData.subdata(in: offset..<offset+2)
            let size = Int(sizeBytes[0]) << 8 | Int(sizeBytes[1])
            offset += 2

            if size == 0 {
                // RLE
                guard offset + 2 <= ipsData.count else {
                    throw IPSError.invalidPatch
                }
                let rleSizeBytes = ipsData.subdata(in: offset..<offset+2)
                let rleSize = Int(rleSizeBytes[0]) << 8 | Int(rleSizeBytes[1])
                offset += 2

                guard offset < ipsData.count else {
                    throw IPSError.invalidPatch
                }
                let fillByte = ipsData[offset]
                offset += 1

                let requiredSize = patchOffset + rleSize
                if patchedData.count < requiredSize {
                    patchedData.append(Data(count: requiredSize - patchedData.count))
                }
                for i in 0..<rleSize {
                    if patchOffset + i < patchedData.count {
                        patchedData[patchOffset + i] = fillByte
                    }
                }
            } else {
                // Normal patch
                guard offset + size <= ipsData.count else {
                    throw IPSError.invalidPatch
                }
                let patchData = ipsData.subdata(in: offset..<offset+size)
                offset += size

                let requiredSize = patchOffset + size
                if patchedData.count < requiredSize {
                    patchedData.append(Data(count: requiredSize - patchedData.count))
                }
                for i in 0..<size {
                    if patchOffset + i < patchedData.count {
                        patchedData[patchOffset + i] = patchData[i]
                    }
                }
            }
        }

        return patchedData
    }
}
