import Foundation
import AppKit
import SD2snesCommanderCore

class LocalFileManager {
    private let fileManager = Foundation.FileManager.default
    
    // MARK: - File Browser Operations
    
    @MainActor
    func browseForDirectory() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "Choose Directory"
        panel.prompt = "Select"

        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    @MainActor
    func browseForFile(allowedTypes: [String] = []) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose File"
        panel.prompt = "Select"

        if !allowedTypes.isEmpty {
            panel.allowedContentTypes = allowedTypes.compactMap { UTType(filenameExtension: $0) }
        }

        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    @MainActor
    func saveFile(suggestedName: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.title = "Save File"
        panel.prompt = "Save"
        panel.canCreateDirectories = true

        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
    
    // MARK: - File Operations
    
    func getFiles(at url: URL) -> [LocalFileItem] {
        do {
            let contents = try fileManager.contentsOfDirectory(at: url, 
                                                             includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                             options: [.skipsHiddenFiles])
            
            return contents.compactMap { fileURL in
                do {
                    let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    let isDirectory = resourceValues.isDirectory ?? false
                    let size = resourceValues.fileSize.map(Int64.init) ?? 0
                    
                    return LocalFileItem(
                        name: fileURL.lastPathComponent,
                        path: fileURL.path,
                        size: size,
                        isDirectory: isDirectory
                    )
                } catch {
                    return nil
                }
            }.sorted { item1, item2 in
                // Directories first, then alphabetically
                if item1.isDirectory != item2.isDirectory {
                    return item1.isDirectory
                }
                return item1.name.localizedCaseInsensitiveCompare(item2.name) == .orderedAscending
            }
            
        } catch {
            print("Error reading directory contents: \(error)")
            return []
        }
    }
    
    func fileExists(at path: String) -> Bool {
        return fileManager.fileExists(atPath: path)
    }
    
    func isDirectory(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
        return isDirectory.boolValue
    }
    
    func fileSize(at path: String) -> Int64? {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: path)
            return attributes[.size] as? Int64
        } catch {
            return nil
        }
    }
    
    // MARK: - ROM File Detection
    
    func isRomFile(_ filename: String) -> Bool {
        let romExtensions = ["smc", "sfc", "fig", "swc", "bs"]
        let fileExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        return romExtensions.contains(fileExtension)
    }
    
    // MARK: - Path Operations
    
    func parentDirectory(of path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let parentURL = url.deletingLastPathComponent()
        return parentURL.path == "/" ? nil : parentURL.path
    }
    
    func joinPath(_ components: String...) -> String {
        return components.reduce("") { result, component in
            if result.isEmpty {
                return component
            } else {
                return URL(fileURLWithPath: result).appendingPathComponent(component).path
            }
        }
    }
    
    // MARK: - System Integration
    
    func revealInFinder(at path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    
    func openWithDefaultApplication(at path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
    }
    
    // MARK: - Recent Locations
    
    private let recentLocationsKey = "RecentLocations"
    private let maxRecentLocations = 10
    
    func addToRecentLocations(_ path: String) {
        var recentLocations = getRecentLocations()
        
        // Remove if already exists
        recentLocations.removeAll { $0 == path }
        
        // Add to beginning
        recentLocations.insert(path, at: 0)
        
        // Limit to max count
        if recentLocations.count > maxRecentLocations {
            recentLocations = Array(recentLocations.prefix(maxRecentLocations))
        }
        
        UserDefaults.standard.set(recentLocations, forKey: recentLocationsKey)
    }
    
    func getRecentLocations() -> [String] {
        return UserDefaults.standard.stringArray(forKey: recentLocationsKey) ?? []
    }
    
    func clearRecentLocations() {
        UserDefaults.standard.removeObject(forKey: recentLocationsKey)
    }
    
    // MARK: - File Type Detection
    
    func getFileType(for filename: String) -> String {
        let fileExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        
        switch fileExtension {
        case "smc", "sfc", "fig", "swc":
            return "Super Famicom ROM"
        case "gb":
            return "Game Boy ROM"
        case "bs":
            return "BS-X ROM"
        case "srm":
            return "Save Data"
        case "rtc":
            return "Real-Time Clock"
        case "msu":
            return "MSU-1 Data"
        case "pcm":
            return "MSU-1 Audio"
        case "txt", "log":
            return "Text File"
        case "zip", "7z", "rar":
            return "Archive"
        default:
            return "File"
        }
    }
}

// MARK: - UTType Extensions

import UniformTypeIdentifiers

extension UTType {
    static let snesRom = UTType(filenameExtension: "smc") ?? UTType.data
    static let superfamicomRom = UTType(filenameExtension: "sfc") ?? UTType.data
}
