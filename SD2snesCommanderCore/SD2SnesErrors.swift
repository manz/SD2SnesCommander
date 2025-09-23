import Foundation

public enum SD2SnesUSBError: Error, LocalizedError {
    case deviceNotFound
    case connectionFailed(String)
    case invalidResponse
    case transferFailed(String)
    case protocolError(String)
    case fileError(String)
    case invalidParameter(String)

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "SD2SNES device not found"
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .invalidResponse:
            return "Invalid response from device"
        case .transferFailed(let message):
            return "Transfer failed: \(message)"
        case .protocolError(let message):
            return "Protocol error: \(message)"
        case .fileError(let message):
            return "File error: \(message)"
        case .invalidParameter(let message):
            return "Invalid parameter: \(message)"
        }
    }

    public init(from cError: sd2snes_error_t) {
        switch cError {
        case SD2SNES_ERROR_DEVICE_NOT_FOUND:
            self = .deviceNotFound
        case SD2SNES_ERROR_CONNECTION_FAILED:
            self = .connectionFailed(String(cString: sd2snes_error_string(cError)))
        case SD2SNES_ERROR_TRANSFER_FAILED:
            self = .transferFailed(String(cString: sd2snes_error_string(cError)))
        case SD2SNES_ERROR_PROTOCOL_ERROR:
            self = .protocolError(String(cString: sd2snes_error_string(cError)))
        case SD2SNES_ERROR_INVALID_RESPONSE:
            self = .invalidResponse
        case SD2SNES_ERROR_FILE_ERROR:
            self = .fileError(String(cString: sd2snes_error_string(cError)))
        case SD2SNES_ERROR_INVALID_PARAMETER:
            self = .invalidParameter(String(cString: sd2snes_error_string(cError)))
        default:
            self = .connectionFailed("Unknown error: \(cError)")
        }
    }
}
