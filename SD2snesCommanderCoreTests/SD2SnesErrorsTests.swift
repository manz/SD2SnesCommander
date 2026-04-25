import Testing
@testable import SD2snesCommanderCore

struct SD2SnesErrorsTests {
    @Test func mapsKnownCErrorCodes() {
        let cases: [(sd2snes_error_t, SD2SnesUSBError)] = [
            (SD2SNES_ERROR_DEVICE_NOT_FOUND,   .deviceNotFound),
            (SD2SNES_ERROR_CONNECTION_FAILED,  .connectionFailed("")),
            (SD2SNES_ERROR_TRANSFER_FAILED,    .transferFailed("")),
            (SD2SNES_ERROR_PROTOCOL_ERROR,     .protocolError("")),
            (SD2SNES_ERROR_INVALID_RESPONSE,   .invalidResponse),
            (SD2SNES_ERROR_FILE_ERROR,         .fileError("")),
            (SD2SNES_ERROR_INVALID_PARAMETER,  .invalidParameter("")),
            (SD2SNES_ERROR_BUFFER_OVERFLOW,    .bufferOverflow),
        ]
        for (code, expected) in cases {
            let mapped = SD2SnesUSBError(from: code)
            #expect(sameCase(mapped, expected),
                    "C code \(code.rawValue) should map to \(expected) but got \(mapped)")
        }
    }

    @Test func remoteCaseDescriptionPassesThrough() {
        let err = SD2SnesUSBError.remote("Disk full")
        #expect(err.errorDescription == "Disk full")
    }

    @Test func emptyMessagesDoNotPrintTrailingColon() {
        #expect(SD2SnesUSBError.fileError("").errorDescription == "File error")
        #expect(SD2SnesUSBError.protocolError("").errorDescription == "Protocol error")
        #expect(SD2SnesUSBError.transferFailed("").errorDescription == "Transfer failed")
    }

    @Test func messagesAreAppendedWhenPresent() {
        #expect(SD2SnesUSBError.fileError("not found").errorDescription == "File error: not found")
    }

    private func sameCase(_ a: SD2SnesUSBError, _ b: SD2SnesUSBError) -> Bool {
        switch (a, b) {
        case (.deviceNotFound, .deviceNotFound),
             (.invalidResponse, .invalidResponse),
             (.bufferOverflow, .bufferOverflow):
            return true
        case (.connectionFailed, .connectionFailed),
             (.transferFailed, .transferFailed),
             (.protocolError, .protocolError),
             (.fileError, .fileError),
             (.invalidParameter, .invalidParameter),
             (.remote, .remote):
            return true
        default:
            return false
        }
    }
}
