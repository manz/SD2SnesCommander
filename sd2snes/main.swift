//
//  main.swift
//  sd2snes
//
//  Created by Emmanuel Peralta on 23/09/2025.
//

import Foundation
import SD2snesCommanderCore

struct SD2SnesCLI {
    static func main() async {
        let args = CommandLine.arguments

        guard args.count > 1 else {
            printUsage()
            exit(1)
        }

        let command = args[1]

        switch command {
        case "info":
            await handleInfo()
        case "ls":
            await handleLS(args: Array(args.dropFirst(2)))
        case "cp":
            await handleCP(args: Array(args.dropFirst(2)))
        case "help", "--help", "-h":
            printUsage()
        default:
            print("Error: Unknown command '\(command)'")
            printUsage()
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        SD2SNES Command Line Tool

        Usage:
            sd2snes <command> [options]

        Commands:
            info                Show device information
            ls [path]          List files on device (default: root directory)
            cp <file> [path]   Upload file to device (default: root directory)
            help               Show this help message

        Examples:
            sd2snes info
            sd2snes ls
            sd2snes ls /games
            sd2snes cp game.sfc
            sd2snes cp game.sfc /games
        """)
    }

    static func handleInfo() async {
        print("Connecting to SD2SNES device...")

        let client = SD2SnesUSBClient()

        do {
            try await client.connect()
            print("✓ Connected to SD2SNES device")

            let deviceInfo = try await client.info()
            let isConnected = await client.isConnected

            print("Device Name: \(deviceInfo.deviceName ?? "Unknown")")
            print("Firmware: \(deviceInfo.firmwareString ?? "Unknown")")
            print("ROM: \(deviceInfo.romName ?? "None")")
            print("Status: \(isConnected ? "Connected" : "Disconnected")")

            await client.disconnect()
        } catch {
            print("✗ Failed to connect: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func handleLS(args: [String]) async {
        let path = args.first ?? ""

        print("Connecting to SD2SNES device...")

        let client = SD2SnesUSBClient()

        do {
            try await client.connect()
            print("✓ Connected, listing files in '\(path.isEmpty ? "/" : path)'")

            let files = try await client.listFiles(path: path)

            if files.isEmpty {
                print("No files found in '\(path.isEmpty ? "/" : path)'")
            } else {
                print("\nFiles in '\(path.isEmpty ? "/" : path)':")
                print("Type\tName")
                print("----\t----")

                for file in files {
                    let type = file.isDirectory ? "DIR" : "FILE"
                    print("\(type)\t\(file.name)")
                }
            }

            await client.disconnect()
        } catch {
            print("✗ Failed to list files: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func handleCP(args: [String]) async {
        guard let sourceFile = args.first else {
            print("Error: No source file specified")
            print("Usage: sd2snes cp <file> [destination_path]")
            exit(1)
        }

        let destinationPath = args.count > 1 ? args[1] : ""

        // Check if source file exists
        let fileURL = URL(fileURLWithPath: sourceFile)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("✗ Source file '\(sourceFile)' does not exist")
            exit(1)
        }

        print("Connecting to SD2SNES device...")

        let client = SD2SnesUSBClient()

        do {
            try await client.connect()
            print("✓ Connected, uploading '\(fileURL.lastPathComponent)' to '\(destinationPath.isEmpty ? "/" : destinationPath)'")

            // Construct remote path
            let remotePath = destinationPath.isEmpty ? fileURL.lastPathComponent :
                            destinationPath.hasSuffix("/") ? destinationPath + fileURL.lastPathComponent :
                            destinationPath + "/" + fileURL.lastPathComponent

            // Upload the file
            try await client.uploadFile(localPath: fileURL.path, remotePath: remotePath)
            print("✓ Successfully uploaded '\(fileURL.lastPathComponent)'")

            await client.disconnect()
        } catch {
            print("✗ Failed to upload file: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

Task {
    await SD2SnesCLI.main()
}

