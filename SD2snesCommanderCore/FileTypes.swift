import Foundation

// MARK: - Shared File Types

public struct LocalFileItem {
    public let name: String
    public let path: String
    public let size: Int64
    public let isDirectory: Bool

    public init(name: String, path: String, size: Int64, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
    }

    public var formattedSize: String {
        if isDirectory { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    public var isRomFile: Bool {
        let romExtensions = ["smc", "sfc", "fig", "swc", "bs"]
        return romExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
}

public struct RemoteFileItem {
    public let name: String
    public let isDirectory: Bool

    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }

    public var isRomFile: Bool {
        let romExtensions = ["smc", "sfc", "fig", "swc", "bs", "gb"]
        return romExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }
}