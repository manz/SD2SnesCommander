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
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("patched_\(romURL.lastPathComponent)")

        try applyPatch(romPath: romPath, ipsPath: ipsPath, outputPath: tempURL.path)
        return tempURL.path
    }

    public static func findIPSPatch(for romPath: String) -> String? {
        let romURL = URL(fileURLWithPath: romPath)
        let romDirectory = romURL.deletingLastPathComponent()
        let romName = romURL.deletingPathExtension().lastPathComponent

        let ipsPatterns = [
            "\(romName).ips",
            "\(romName).IPS",
            "\(romURL.deletingPathExtension().path).ips",
            "\(romURL.deletingPathExtension().path).IPS"
        ]

        for pattern in ipsPatterns {
            let ipsURL = romDirectory.appendingPathComponent(pattern)
            if FileManager.default.fileExists(atPath: ipsURL.path) {
                return ipsURL.path
            }
        }

        return nil
    }

    private static func applyIPSPatch(to romData: Data, patch ipsData: Data) throws -> Data {
        guard ipsData.count >= 8 else {
            throw IPSError.invalidIPSFile
        }

        // Check IPS header "PATCH"
        let header = ipsData.subdata(in: 0..<5)
        let expectedHeader = "PATCH".data(using: .ascii)!
        guard header == expectedHeader else {
            throw IPSError.invalidIPSFile
        }

        var patchedData = romData
        var offset = 5

        while offset < ipsData.count - 3 {
            // Check for EOF marker
            let eofMarker = ipsData.subdata(in: offset..<offset+3)
            if eofMarker == "EOF".data(using: .ascii)! {
                break
            }

            // Read 3-byte address
            let addressBytes = ipsData.subdata(in: offset..<offset+3)
            let address = (Int(addressBytes[offset]) << 16) | (Int(addressBytes[offset+1]) << 8) | Int(addressBytes[offset+2])
            offset += 3

            // Read 2-byte length
            let lengthBytes = ipsData.subdata(in: offset..<offset+2)
            let length = (Int(lengthBytes[offset]) << 8) | Int(lengthBytes[offset+1])
            offset += 2

            if length == 0 {
                // RLE encoding
                let rleLength = (Int(ipsData[offset]) << 8) | Int(ipsData[offset+1])
                offset += 2
                let fillByte = ipsData[offset]
                offset += 1

                // Extend data if necessary
                let requiredSize = address + rleLength
                if patchedData.count < requiredSize {
                    patchedData.append(Data(count: requiredSize - patchedData.count))
                }

                // Fill with RLE data
                patchedData.replaceSubrange(address..<address+rleLength, with: Data(repeating: fillByte, count: rleLength))
            } else {
                // Normal patch
                let patchBytes = ipsData.subdata(in: offset..<offset+length)
                offset += length

                // Extend data if necessary
                let requiredSize = address + length
                if patchedData.count < requiredSize {
                    patchedData.append(Data(count: requiredSize - patchedData.count))
                }

                // Apply patch
                patchedData.replaceSubrange(address..<address+length, with: patchBytes)
            }
        }

        return patchedData
    }
}