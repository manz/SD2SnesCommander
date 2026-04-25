import Foundation
import os.log

// XPC proxy. App and CLI route every USB call through the bundled
// SD2SnesUSBService daemon so the device is shared between processes
// (and the C globals live in exactly one place).
//
// Public API matches what callers had before the daemon split, so the
// migration was a name-only change for the consumers.
public actor SD2SnesUSBClient {
    public static let shared = SD2SnesUSBClient()

    private let logger = Logger(subsystem: "SD2snesCommanderCore", category: "USBClient")
    private var connection: NSXPCConnection?

    private init() {}

    // MARK: - Connection plumbing

    private func ensureConnection() -> NSXPCConnection {
        if let connection { return connection }
        let conn = NSXPCConnection(machServiceName: SD2SnesUSBServiceMachName)
        conn.remoteObjectInterface = NSXPCInterface(with: (any SD2SnesXPCProtocol).self)
        conn.invalidationHandler = { [weak self] in
            Task { await self?.handleInvalidation() }
        }
        conn.interruptionHandler = { [weak self] in
            Task { await self?.handleInterruption() }
        }
        conn.resume()
        connection = conn
        return conn
    }

    private func handleInvalidation() {
        logger.info("XPC connection invalidated")
        connection = nil
    }

    private func handleInterruption() {
        logger.info("XPC connection interrupted")
        connection = nil
    }

    private func proxyForCall(continuation: CheckedContinuation<Void, any Error>) -> any SD2SnesXPCProtocol {
        let conn = ensureConnection()
        return conn.remoteObjectProxyWithErrorHandler { error in
            continuation.resume(throwing: error)
        } as! any SD2SnesXPCProtocol
    }

    private func proxyForCall<T>(continuation: CheckedContinuation<T, any Error>) -> any SD2SnesXPCProtocol {
        let conn = ensureConnection()
        return conn.remoteObjectProxyWithErrorHandler { error in
            continuation.resume(throwing: error)
        } as! any SD2SnesXPCProtocol
    }

    // MARK: - Connection management

    public func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            proxyForCall(continuation: continuation).connect { errorMessage in
                if let errorMessage {
                    continuation.resume(throwing: SD2SnesUSBError.remote(errorMessage))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func disconnect() async {
        let conn = ensureConnection()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in
                continuation.resume()
            } as! any SD2SnesXPCProtocol
            proxy.disconnect {
                continuation.resume()
            }
        }
    }

    public var isConnected: Bool {
        get async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let conn = ensureConnection()
                let proxy = conn.remoteObjectProxyWithErrorHandler { _ in
                    continuation.resume(returning: false)
                } as! any SD2SnesXPCProtocol
                proxy.isConnected { value in
                    continuation.resume(returning: value)
                }
            }
        }
    }

    // MARK: - Device info

    public func info() async throws -> RemoteInfo {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RemoteInfo, any Error>) in
            proxyForCall(continuation: continuation).info { data, errorMessage in
                if let errorMessage {
                    continuation.resume(throwing: SD2SnesUSBError.remote(errorMessage))
                    return
                }
                guard let data,
                      let info = try? JSONDecoder().decode(RemoteInfo.self, from: data) else {
                    continuation.resume(throwing: SD2SnesUSBError.invalidResponse)
                    return
                }
                continuation.resume(returning: info)
            }
        }
    }

    // MARK: - File operations

    public func listFiles(path: String = "") async throws -> [RemoteFileItem] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[RemoteFileItem], any Error>) in
            proxyForCall(continuation: continuation).listFiles(path: path) { data, errorMessage in
                if let errorMessage {
                    continuation.resume(throwing: SD2SnesUSBError.remote(errorMessage))
                    return
                }
                guard let data,
                      let items = try? JSONDecoder().decode([RemoteFileItem].self, from: data) else {
                    continuation.resume(throwing: SD2SnesUSBError.invalidResponse)
                    return
                }
                continuation.resume(returning: items)
            }
        }
    }

    public func uploadFile(
        localPath: String,
        remotePath: String,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try await callWithProgress(progressHandler) { proxy, completion in
            proxy.uploadFile(localPath: localPath, remotePath: remotePath, reply: completion)
        }
    }

    public func downloadFile(
        remotePath: String,
        localPath: String,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try await callWithProgress(progressHandler) { proxy, completion in
            proxy.downloadFile(remotePath: remotePath, localPath: localPath, reply: completion)
        }
    }

    public func deleteFile(path: String) async throws {
        try await voidCall { proxy, reply in
            proxy.deleteFile(path: path, reply: reply)
        }
    }

    // MARK: - Device control

    public func bootRom(path: String) async throws {
        try await voidCall { proxy, reply in
            proxy.bootRom(path: path, reply: reply)
        }
    }

    public func reset() async throws {
        try await voidCall { proxy, reply in
            proxy.resetDevice(reply: reply)
        }
    }

    public func menu() async throws {
        try await voidCall { proxy, reply in
            proxy.menuReset(reply: reply)
        }
    }

    // MARK: - Helpers

    private func voidCall(
        _ body: (any SD2SnesXPCProtocol, @escaping (String?) -> Void) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            body(proxyForCall(continuation: continuation)) { errorMessage in
                if let errorMessage {
                    continuation.resume(throwing: SD2SnesUSBError.remote(errorMessage))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func callWithProgress(
        _ progressHandler: (@Sendable (Double) -> Void)?,
        _ body: (any SD2SnesXPCProtocol, @escaping (String?) -> Void) -> Void
    ) async throws {
        let conn = ensureConnection()
        if let progressHandler {
            conn.exportedInterface = NSXPCInterface(with: (any SD2SnesXPCProgressDelegate).self)
            conn.exportedObject = ProgressForwarder(handler: progressHandler)
        }
        defer {
            conn.exportedObject = nil
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            body(proxyForCall(continuation: continuation)) { errorMessage in
                if let errorMessage {
                    continuation.resume(throwing: SD2SnesUSBError.remote(errorMessage))
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

// Bridges the Swift @Sendable closure to the @objc protocol the daemon
// invokes. Held by NSXPCConnection.exportedObject for the duration of a
// transfer.
private final class ProgressForwarder: NSObject, SD2SnesXPCProgressDelegate {
    let handler: @Sendable (Double) -> Void
    init(handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }
    @objc func transferProgress(_ fraction: Double) {
        handler(fraction)
    }
}
