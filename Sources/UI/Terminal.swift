// Copyright (c) 2025 Alex Babaev. All rights reserved.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum Key: Sendable, Equatable {
    case up
    case down
    case left
    case right
    case escape
    case char(Character)
    case other
}

@MainActor
final class Terminal {
    private var savedTermios: termios = .init()
    private var savedTermiosValid: Bool = false
    private var savedStderr: Int32 = -1

    func enterRawMode() throws {
        var current = termios()
        guard tcgetattr(STDIN_FILENO, &current) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        savedTermios = current
        savedTermiosValid = true

        var raw = current
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        // Keep ISIG so Ctrl+C still raises SIGINT and goes through the same shutdown path as a window close.
        withUnsafeMutablePointer(to: &raw.c_cc) { tuplePtr in
            tuplePtr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { ccPtr in
                ccPtr[Int(VMIN)] = 1
                ccPtr[Int(VTIME)] = 0
            }
        }
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func restoreMode() {
        guard savedTermiosValid else { return }
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
        savedTermiosValid = false
    }

    func enterAltScreen() {
        writeRaw("\u{1b}[?1049h")
        writeRaw("\u{1b}[?25l")
        writeRaw("\u{1b}[2J")
        writeRaw("\u{1b}[H")
    }

    func exitAltScreen() {
        writeRaw("\u{1b}[?25h")
        writeRaw("\u{1b}[?1049l")
    }

    func silenceStderr() {
        guard savedStderr == -1 else { return }
        savedStderr = dup(STDERR_FILENO)
        let devNull = open("/dev/null", O_WRONLY)
        if devNull >= 0 {
            _ = dup2(devNull, STDERR_FILENO)
            close(devNull)
        }
    }

    func restoreStderr() {
        guard savedStderr >= 0 else { return }
        _ = dup2(savedStderr, STDERR_FILENO)
        close(savedStderr)
        savedStderr = -1
    }

    func size() -> (rows: Int, cols: Int) {
        var w = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w) == 0, w.ws_col > 0, w.ws_row > 0 {
            return (Int(w.ws_row), Int(w.ws_col))
        }
        return (24, 80)
    }

    func writeRaw(_ s: String) {
        let data = Array(s.utf8)
        data.withUnsafeBufferPointer { buf in
            var remaining = buf.count
            var ptr = buf.baseAddress
            while remaining > 0, let p = ptr {
                let n = Foundation.write(STDOUT_FILENO, p, remaining)
                if n <= 0 { break }
                remaining -= n
                ptr = p.advanced(by: n)
            }
        }
    }

    nonisolated func readKeyBlocking() -> Key? {
        var byte: UInt8 = 0
        let n = Foundation.read(STDIN_FILENO, &byte, 1)
        if n <= 0 { return nil }

        if byte == 0x1b {
            var pollFd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollFd, 1, 50)
            if ready <= 0 { return .escape }

            var next: UInt8 = 0
            let m = Foundation.read(STDIN_FILENO, &next, 1)
            if m <= 0 { return .escape }
            if next != UInt8(ascii: "[") {
                return .other
            }
            var third: UInt8 = 0
            let k = Foundation.read(STDIN_FILENO, &third, 1)
            if k <= 0 { return .other }
            switch third {
                case UInt8(ascii: "A"): return .up
                case UInt8(ascii: "B"): return .down
                case UInt8(ascii: "C"): return .right
                case UInt8(ascii: "D"): return .left
                default: return .other
            }
        }

        if let scalar = Unicode.Scalar(UInt32(byte)) {
            return .char(Character(scalar))
        }
        return .other
    }
}

enum ANSI {
    static let reset = "\u{1b}[0m"
    static let baseColors = "\u{1b}[40;37m"
    static let reverse = "\u{1b}[7m"
    static let dim = "\u{1b}[2m"
    static let bold = "\u{1b}[1m"
    static let clearScreen = "\u{1b}[2J\u{1b}[H"

    static func moveTo(row: Int, col: Int) -> String {
        "\u{1b}[\(row);\(col)H"
    }
}
