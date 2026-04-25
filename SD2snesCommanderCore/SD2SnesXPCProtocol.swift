import Foundation

// Mach service name registered by the bundled SD2SnesUSBService XPC helper.
// Keep in sync with the MachServices key in the service's Info.plist.
public let SD2SnesUSBServiceMachName = "net.ringum.sd2snescommander.usbservice"

// Progress callback channel used during long transfers. The app/CLI hands an
// object conforming to this protocol to the daemon via the connection's
// exportedObject and the daemon calls back as data flows.
@objc public protocol SD2SnesXPCProgressDelegate {
    func transferProgress(_ fraction: Double)
}

// XPC-vended USB API. Reply blocks carry an optional error string — nil means
// success; the caller maps it back to SD2SnesUSBError. Structured payloads
// (RemoteInfo, RemoteFileItem array) cross the wire as JSON-encoded Data so
// we don't need NSSecureCoding ceremony for our value types.
@objc public protocol SD2SnesXPCProtocol {
    func connect(reply: @escaping (String?) -> Void)
    func disconnect(reply: @escaping () -> Void)
    func isConnected(reply: @escaping (Bool) -> Void)

    func info(reply: @escaping (Data?, String?) -> Void)
    func listFiles(path: String, reply: @escaping (Data?, String?) -> Void)

    func uploadFile(localPath: String, remotePath: String, reply: @escaping (String?) -> Void)
    func downloadFile(remotePath: String, localPath: String, reply: @escaping (String?) -> Void)

    func deleteFile(path: String, reply: @escaping (String?) -> Void)
    func bootRom(path: String, reply: @escaping (String?) -> Void)
    func resetDevice(reply: @escaping (String?) -> Void)
    func menuReset(reply: @escaping (String?) -> Void)
}
