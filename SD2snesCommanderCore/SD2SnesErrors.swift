import Foundation

public enum SD2SnesUSBError: Error, LocalizedError {
    case deviceNotFound
    case connectionFailed(String)
    case invalidResponse
    case transferFailed(String)
    case protocolError(String)
    case fileError(String)
    case invalidParameter(String)
    case bufferOverflow
    // Verbatim error string forwarded from the XPC daemon — prevents the
    // proxy from wrapping daemon errors in another "Protocol error:" layer.
    case remote(String)

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "SD2SNES device not found"
        case .connectionFailed(let message):
            return message.isEmpty ? "Connection failed" : "Connection failed: \(message)"
        case .invalidResponse:
            return "Invalid response from device"
        case .transferFailed(let message):
            return message.isEmpty ? "Transfer failed" : "Transfer failed: \(message)"
        case .protocolError(let message):
            return message.isEmpty ? "Protocol error" : "Protocol error: \(message)"
        case .fileError(let message):
            return message.isEmpty ? "File error" : "File error: \(message)"
        case .invalidParameter(let message):
            return message.isEmpty ? "Invalid parameter" : "Invalid parameter: \(message)"
        case .bufferOverflow:
            return "Result buffer too small"
        case .remote(let message):
            return message
        }
    }

    public init(from cError: sd2snes_error_t) {
        // The C side's sd2snes_error_string already mirrors the case name,
        // so we'd double-print it ("File error: File error") if we forwarded
        // it as the message. Leave the message empty and let errorDescription
        // print the case name on its own.
        switch cError {
        case SD2SNES_ERROR_DEVICE_NOT_FOUND:
            self = .deviceNotFound
        case SD2SNES_ERROR_CONNECTION_FAILED:
            self = .connectionFailed("")
        case SD2SNES_ERROR_TRANSFER_FAILED:
            self = .transferFailed("")
        case SD2SNES_ERROR_PROTOCOL_ERROR:
            self = .protocolError("")
        case SD2SNES_ERROR_INVALID_RESPONSE:
            self = .invalidResponse
        case SD2SNES_ERROR_FILE_ERROR:
            self = .fileError("")
        case SD2SNES_ERROR_INVALID_PARAMETER:
            self = .invalidParameter("")
        case SD2SNES_ERROR_BUFFER_OVERFLOW:
            self = .bufferOverflow
        default:
            self = .connectionFailed("Unknown error: \(cError)")
        }
    }
}
