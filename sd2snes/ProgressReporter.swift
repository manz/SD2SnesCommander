import Foundation

// Emits OSC 9;4 progress updates that kitty/ghostty/WezTerm pick up as
// taskbar progress, plus a textual bar on stderr for everything else.
// Other terminals quietly ignore the unknown OSC sequence.
enum ProgressReporter {
    private static let lock = NSLock()
    private static var lastPercent = -1
    private static var isActive = false

    static func start() {
        lock.lock()
        defer { lock.unlock() }
        isActive = true
        lastPercent = -1
        emitOSC(state: 1, percent: 0)
    }

    static func update(_ fraction: Double) {
        let percent = max(0, min(100, Int(fraction * 100)))
        lock.lock()
        defer { lock.unlock() }
        guard isActive, percent != lastPercent else { return }
        lastPercent = percent
        emitOSC(state: 1, percent: percent)
        emitTextBar(percent: percent)
    }

    static func finish(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return }
        isActive = false
        if success {
            emitTextBar(percent: 100, terminate: true)
            emitOSC(state: 0, percent: 0)
        } else {
            emitOSC(state: 2, percent: max(0, lastPercent))
            // leave the error state up briefly so terminal taskbars notice
            FileHandle.standardError.write(Data("\n".utf8))
        }
    }

    private static func emitOSC(state: Int, percent: Int) {
        // ESC ] 9 ; 4 ; <state> ; <percent> ESC \\
        let seq = "\u{1B}]9;4;\(state);\(percent)\u{1B}\\"
        FileHandle.standardError.write(Data(seq.utf8))
    }

    private static func emitTextBar(percent: Int, terminate: Bool = false) {
        let width = 30
        let filled = Int(Double(width) * Double(percent) / 100.0)
        let bar = String(repeating: "█", count: filled)
            + String(repeating: "░", count: max(0, width - filled))
        let suffix = terminate ? "\n" : ""
        let line = "\r\(bar) \(percent)%\(suffix)"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
