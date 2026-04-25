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

        let rest = Array(args.dropFirst(2))
        switch command {
        case "info":
            await handleInfo()
        case "ls":
            await handleLS(args: rest)
        case "cp":
            await handleCP(args: rest)
        case "get":
            await handleGet(args: rest)
        case "rm":
            await handleRM(args: rest)
        case "boot":
            await handleBoot(args: rest)
        case "reset":
            await handleReset()
        case "menu":
            await handleMenu()
        case "restart-daemon":
            handleRestartDaemon()
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
            info                       Show device information
            ls [path]                  List files on device (default: root)
            cp [-b|--boot] <file> [path]
                                       Upload file. -b/--boot: boot ROM after upload.
            get <remote> [local]       Download a file from the device
            rm <remote>                Delete a file from the device
            boot <remote>              Boot a ROM already on the device
            reset                      Reset the running ROM
            menu                       Return to the menu
            restart-daemon             Force-restart the bundled XPC USB daemon
            help                       Show this help message

        Examples:
            sd2snes info
            sd2snes ls
            sd2snes ls /games
            sd2snes cp -b game.sfc /games
            sd2snes get /games/save.srm save.srm
            sd2snes rm /games/old.sfc
            sd2snes boot /games/game.sfc
            sd2snes reset
            sd2snes menu
        """)
    }

    static func handleInfo() async {
        print("Connecting to SD2SNES device...")

        let client = SD2SnesUSBClient.shared

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
        let rawPath = args.first ?? ""
        let path = normalizeRemotePath(rawPath)

        print("Connecting to SD2SNES device...")

        let client = SD2SnesUSBClient.shared

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
        var bootAfter = false
        var positional: [String] = []
        for arg in args {
            switch arg {
            case "-b", "--boot":
                bootAfter = true
            default:
                positional.append(arg)
            }
        }

        guard let sourceFile = positional.first else {
            print("Error: No source file specified")
            print("Usage: sd2snes cp [-b|--boot] <file> [destination_path]")
            exit(1)
        }

        let destinationPath = normalizeRemotePath(positional.count > 1 ? positional[1] : "")

        let fileURL = URL(fileURLWithPath: sourceFile)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("✗ Source file '\(sourceFile)' does not exist")
            exit(1)
        }

        if bootAfter && !isBootableROM(fileURL) {
            print("✗ -b/--boot only works on ROM files (.smc/.sfc/.fig/.swc/.bs/.gb)")
            exit(1)
        }

        // Mirror the GUI's auto-IPS behavior: if a sibling .ips patch exists
        // alongside a ROM, apply it into a temp file and upload that.
        var uploadFromPath = fileURL.path
        var tempPatchedPath: String? = nil
        if isBootableROM(fileURL), let ipsPath = IPSPatcher.findIPSPatch(for: fileURL.path) {
            do {
                tempPatchedPath = try IPSPatcher.createTemporaryPatchedFile(
                    romPath: fileURL.path,
                    ipsPath: ipsPath
                )
                uploadFromPath = tempPatchedPath!
                print("✓ Applied IPS patch '\((ipsPath as NSString).lastPathComponent)'")
            } catch {
                print("⚠ IPS patch '\((ipsPath as NSString).lastPathComponent)' failed: \(error.localizedDescription) — uploading unpatched ROM")
            }
        }

        print("Connecting to SD2SNES device...")

        let client = SD2SnesUSBClient.shared

        do {
            try await client.connect()
            print("✓ Connected, uploading '\(fileURL.lastPathComponent)' to '\(destinationPath.isEmpty ? "/" : destinationPath)'")

            let remotePath = destinationPath.isEmpty
                ? fileURL.lastPathComponent
                : "\(destinationPath)/\(fileURL.lastPathComponent)"

            ProgressReporter.start()
            do {
                try await client.uploadFile(localPath: uploadFromPath, remotePath: remotePath) { fraction in
                    ProgressReporter.update(fraction)
                }
                ProgressReporter.finish(success: true)
            } catch {
                ProgressReporter.finish(success: false)
                throw error
            }

            if let tempPatchedPath {
                try? FileManager.default.removeItem(atPath: tempPatchedPath)
            }

            print("✓ Successfully uploaded '\(fileURL.lastPathComponent)'")

            if bootAfter {
                try await client.bootRom(path: remotePath)
                print("✓ Booting '\(remotePath)'")
            }

            await client.disconnect()
        } catch {
            if let tempPatchedPath {
                try? FileManager.default.removeItem(atPath: tempPatchedPath)
            }
            print("✗ Failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func isBootableROM(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["smc", "sfc", "fig", "swc", "bs", "gb"].contains(ext)
    }

    static func handleGet(args: [String]) async {
        guard let remoteArg = args.first else {
            print("Usage: sd2snes get <remote> [local]")
            exit(1)
        }
        let remotePath = normalizeRemotePath(remoteArg)
        let remoteName = (remotePath as NSString).lastPathComponent
        let localPath = args.count > 1
            ? URL(fileURLWithPath: args[1]).path
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(remoteName).path

        print("Connecting to SD2SNES device...")
        let client = SD2SnesUSBClient.shared
        do {
            try await client.connect()
            print("✓ Connected, downloading '\(remotePath)' to '\(localPath)'")

            ProgressReporter.start()
            do {
                try await client.downloadFile(remotePath: remotePath, localPath: localPath) { fraction in
                    ProgressReporter.update(fraction)
                }
                ProgressReporter.finish(success: true)
            } catch {
                ProgressReporter.finish(success: false)
                throw error
            }

            print("✓ Saved to '\(localPath)'")
            await client.disconnect()
        } catch {
            print("✗ Failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func handleRM(args: [String]) async {
        guard let remoteArg = args.first else {
            print("Usage: sd2snes rm <remote>")
            exit(1)
        }
        let remotePath = normalizeRemotePath(remoteArg)

        print("Connecting to SD2SNES device...")
        let client = SD2SnesUSBClient.shared
        do {
            try await client.connect()
            try await client.deleteFile(path: remotePath)
            print("✓ Deleted '\(remotePath)'")
            await client.disconnect()
        } catch {
            print("✗ Failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func handleBoot(args: [String]) async {
        guard let remoteArg = args.first else {
            print("Usage: sd2snes boot <remote>")
            exit(1)
        }
        let remotePath = normalizeRemotePath(remoteArg)

        print("Connecting to SD2SNES device...")
        let client = SD2SnesUSBClient.shared
        do {
            try await client.connect()
            try await client.bootRom(path: remotePath)
            print("✓ Booting '\(remotePath)'")
            await client.disconnect()
        } catch {
            print("✗ Failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func handleReset() async {
        print("Connecting to SD2SNES device...")
        let client = SD2SnesUSBClient.shared
        do {
            try await client.connect()
            try await client.reset()
            print("✓ Reset issued")
            await client.disconnect()
        } catch {
            print("✗ Failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func handleRestartDaemon() {
        // Tear down our own connection first so the proxy doesn't log a
        // spurious invalidation, then SIGKILL the daemon. Launchd respawns
        // it on the next XPC connection.
        let task = Process()
        task.launchPath = "/usr/bin/pkill"
        task.arguments = ["-9", "-x", "SD2SnesUSBService"]
        do {
            try task.run()
            task.waitUntilExit()
            switch task.terminationStatus {
            case 0:
                print("✓ Daemon killed; launchd will restart it on next use")
            case 1:
                print("ℹ Daemon was not running; nothing to restart")
            default:
                print("⚠ pkill exited with status \(task.terminationStatus)")
            }
        } catch {
            print("✗ Failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func handleMenu() async {
        print("Connecting to SD2SNES device...")
        let client = SD2SnesUSBClient.shared
        do {
            try await client.connect()
            try await client.menu()
            print("✓ Returning to menu")
            await client.disconnect()
        } catch {
            print("✗ Failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    // Firmware paths are relative to the SD root and never start with '/'.
    // Accept "/", "/Hacks", "Hacks", "Hacks/" all the same way.
    static func normalizeRemotePath(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    static func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

await SD2SnesCLI.main()

