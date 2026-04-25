import Foundation
import os.log
import SD2snesCommanderCore

// XPC entry point. Each NSXPCConnection from app/CLI lands here and gets
// forwarded into the SD2SnesUSBDirect actor, which is the only thing in
// this process that touches IOKit.
final class SD2SnesUSBService: NSObject, SD2SnesXPCProtocol, @unchecked Sendable {
    private let logger = Logger(subsystem: "net.ringum.sd2snescommander.usbservice", category: "Service")
    private weak var connection: NSXPCConnection?

    init(connection: NSXPCConnection) {
        self.connection = connection
        super.init()
    }

    private var direct: SD2SnesUSBDirect { .shared }

    private var progressDelegate: (any SD2SnesXPCProgressDelegate)? {
        connection?.remoteObjectProxy as? any SD2SnesXPCProgressDelegate
    }

    // MARK: - Connection management

    @objc func connect(reply: @escaping (String?) -> Void) {
        Task {
            do {
                try await direct.connect()
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    @objc func disconnect(reply: @escaping () -> Void) {
        Task {
            await direct.disconnect()
            reply()
        }
    }

    @objc func isConnected(reply: @escaping (Bool) -> Void) {
        Task {
            reply(await direct.isConnected)
        }
    }

    // MARK: - Device info

    @objc func info(reply: @escaping (Data?, String?) -> Void) {
        Task {
            do {
                let info = try await direct.info()
                reply(try JSONEncoder().encode(info), nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    @objc func listFiles(path: String, reply: @escaping (Data?, String?) -> Void) {
        Task {
            do {
                let files = try await direct.listFiles(path: path)
                reply(try JSONEncoder().encode(files), nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    // MARK: - Transfers

    @objc func uploadFile(localPath: String, remotePath: String, reply: @escaping (String?) -> Void) {
        let delegate = progressDelegate
        Task {
            do {
                try await direct.uploadFile(localPath: localPath, remotePath: remotePath) { fraction in
                    delegate?.transferProgress(fraction)
                }
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    @objc func downloadFile(remotePath: String, localPath: String, reply: @escaping (String?) -> Void) {
        let delegate = progressDelegate
        Task {
            do {
                try await direct.downloadFile(remotePath: remotePath, localPath: localPath) { fraction in
                    delegate?.transferProgress(fraction)
                }
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    @objc func deleteFile(path: String, reply: @escaping (String?) -> Void) {
        Task {
            do {
                try await direct.deleteFile(path: path)
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    // MARK: - Device control

    @objc func bootRom(path: String, reply: @escaping (String?) -> Void) {
        Task {
            do {
                try await direct.bootRom(path: path)
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    @objc func resetDevice(reply: @escaping (String?) -> Void) {
        Task {
            do {
                try await direct.reset()
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    @objc func menuReset(reply: @escaping (String?) -> Void) {
        Task {
            do {
                try await direct.menu()
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }
}
