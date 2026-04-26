import Foundation
import Testing
@testable import SD2snesCommanderCore

struct WireFormatTests {
    private let blockSize = Int(USB_BLOCK_SIZE)

    // MARK: - Command packet packing

    @Test func packsMagicAndOpcodeFields() {
        var buf = [UInt8](repeating: 0xCC, count: blockSize)
        buf.withUnsafeMutableBufferPointer { bp in
            sd2snes_build_command_packet(
                bp.baseAddress, SD2SNES_OP_INFO, SD2SNES_SPACE_FILE,
                SD2SNES_FLAG_NONE, nil, 0
            )
        }
        // First 4 bytes must be "USBA".
        #expect(buf[0] == UInt8(ascii: "U"))
        #expect(buf[1] == UInt8(ascii: "S"))
        #expect(buf[2] == UInt8(ascii: "B"))
        #expect(buf[3] == UInt8(ascii: "A"))
        #expect(buf[4] == UInt8(SD2SNES_OP_INFO.rawValue))
        #expect(buf[5] == UInt8(SD2SNES_SPACE_FILE.rawValue))
        #expect(buf[6] == UInt8(SD2SNES_FLAG_NONE.rawValue))
        // The previous garbage from byte 7 onward must be zeroed.
        #expect(buf[7] == 0)
        #expect(buf[blockSize - 1] == 0)
    }

    @Test func encodesSizeAsU32BE() {
        var buf = [UInt8](repeating: 0, count: blockSize)
        let size: UInt32 = 0x01020304
        buf.withUnsafeMutableBufferPointer { bp in
            sd2snes_build_command_packet(
                bp.baseAddress, SD2SNES_OP_PUT, SD2SNES_SPACE_FILE,
                SD2SNES_FLAG_NONE, "x", size
            )
        }
        #expect(buf[252] == 0x01)
        #expect(buf[253] == 0x02)
        #expect(buf[254] == 0x03)
        #expect(buf[255] == 0x04)
    }

    @Test func writesPathStartingAtOffset256() {
        var buf = [UInt8](repeating: 0, count: blockSize)
        buf.withUnsafeMutableBufferPointer { bp in
            sd2snes_build_command_packet(
                bp.baseAddress, SD2SNES_OP_LS, SD2SNES_SPACE_FILE,
                SD2SNES_FLAG_NONE, "Hack", 0
            )
        }
        #expect(buf[256] == UInt8(ascii: "H"))
        #expect(buf[257] == UInt8(ascii: "a"))
        #expect(buf[258] == UInt8(ascii: "c"))
        #expect(buf[259] == UInt8(ascii: "k"))
        #expect(buf[260] == 0) // null terminator implied by surrounding zero fill
    }

    @Test func clipsOverlongParameterAt255Bytes() {
        // Anything past offset 256+255 = 511 would overflow, and the firmware
        // truncates anyway. Verify the build path drops the overflow.
        var buf = [UInt8](repeating: 0, count: blockSize)
        let oversized = String(repeating: "A", count: 300)
        buf.withUnsafeMutableBufferPointer { bp in
            sd2snes_build_command_packet(
                bp.baseAddress, SD2SNES_OP_PUT, SD2SNES_SPACE_FILE,
                SD2SNES_FLAG_NONE, oversized, 0
            )
        }
        // 255 'A's at offsets 256..510, byte 511 stays zero.
        #expect(buf[256] == UInt8(ascii: "A"))
        #expect(buf[256 + 254] == UInt8(ascii: "A"))
        #expect(buf[511] == 0)
    }

    // MARK: - Response header parsing

    @Test func rejectsResponseWithBadMagic() {
        var packet = [UInt8](repeating: 0, count: blockSize)
        packet[0] = 0x42 // not 'U'
        var err: UInt8 = 0xFF
        var size: UInt32 = 0xDEADBEEF
        let rc = packet.withUnsafeBufferPointer {
            sd2snes_parse_response_header($0.baseAddress, &err, &size)
        }
        #expect(rc == SD2SNES_ERROR_INVALID_RESPONSE)
    }

    @Test func decodesErrorCodeAndU32BETotalSize() {
        // Hand-craft a typical response: USBA opcode + error byte 0x05,
        // total_size = 0x12345678 stored big-endian at offsets 252..255.
        var packet = [UInt8](repeating: 0, count: blockSize)
        packet[0] = UInt8(ascii: "U")
        packet[1] = UInt8(ascii: "S")
        packet[2] = UInt8(ascii: "B")
        packet[3] = UInt8(ascii: "A")
        packet[4] = 0x0F // RESPONSE
        packet[5] = 0x05 // FatFs error code
        packet[252] = 0x12
        packet[253] = 0x34
        packet[254] = 0x56
        packet[255] = 0x78

        var err: UInt8 = 0
        var size: UInt32 = 0
        let rc = packet.withUnsafeBufferPointer {
            sd2snes_parse_response_header($0.baseAddress, &err, &size)
        }
        #expect(rc == SD2SNES_SUCCESS)
        #expect(err == 0x05)
        #expect(size == 0x12345678)
    }

    @Test func packAndParseSizeRoundTripsAcrossThreshold() {
        // Specifically guard against the pre-fix little-endian bug: anything
        // with non-zero bytes past 0xFF used to come back garbled.
        for size: UInt32 in [0, 1, 0xFF, 0x100, 0x12345678, 0xFFFFFFFF] {
            var packet = [UInt8](repeating: 0, count: blockSize)
            packet.withUnsafeMutableBufferPointer { bp in
                sd2snes_build_command_packet(
                    bp.baseAddress, SD2SNES_OP_PUT, SD2SNES_SPACE_FILE,
                    SD2SNES_FLAG_NONE, "x", size
                )
            }
            // Patch the magic + opcode bytes so the parser accepts it.
            packet[4] = 0x0F
            var err: UInt8 = 0
            var decoded: UInt32 = 0
            let rc = packet.withUnsafeBufferPointer {
                sd2snes_parse_response_header($0.baseAddress, &err, &decoded)
            }
            #expect(rc == SD2SNES_SUCCESS)
            #expect(decoded == size, "round-trip failed for size 0x\(String(size, radix: 16))")
        }
    }
}
