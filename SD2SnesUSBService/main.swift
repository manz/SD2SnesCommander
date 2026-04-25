import Foundation
import SD2snesCommanderCore

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: (any SD2SnesXPCProtocol).self)
        // App/CLI may export an SD2SnesXPCProgressDelegate before kicking off
        // a transfer; describe it so the proxy resolves on the wire.
        newConnection.remoteObjectInterface = NSXPCInterface(with: (any SD2SnesXPCProgressDelegate).self)

        let exported = SD2SnesUSBService(connection: newConnection)
        newConnection.exportedObject = exported

        newConnection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
