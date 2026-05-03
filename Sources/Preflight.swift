// Copyright (c) 2025 Alex Babaev. All rights reserved.

import Foundation
import Subprocess
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum PreflightMode: Sendable {
    case ui
    case daemon
}

struct PreflightError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

enum Preflight {
    static let minimumUhubctlVersion: [Int] = [ 2, 6, 0 ]

    static func run(mode: PreflightMode) async throws {
        #if os(macOS)
        FileHandle.standardError.write(Data("nanocharger: running in dev/stub mode (uhubctl calls are faked)\n".utf8))
        _ = mode
        #else
        try checkUhubctlAvailable()
        try await checkUhubctlVersion()
        #endif
    }

    static func checkUhubctlAvailable() throws {
        guard locateInPath("uhubctl") != nil else {
            throw PreflightError(message: """
                Error: required tool 'uhubctl' was not found in PATH.
                  Install it on Raspberry Pi OS with: sudo apt install uhubctl
                  Source: https://github.com/mvp/uhubctl
                """)
        }
    }

    static func checkUhubctlVersion() async throws {
        let raw: String
        do {
            let result = try await Subprocess.run(.name("uhubctl"), arguments: [ "--version" ], output: .string(limit: 1 << 16))
            raw = result.standardOutput ?? ""
        } catch {
            throw PreflightError(message: "Error: 'uhubctl --version' failed: \(error)")
        }

        guard let version = parseVersion(raw) else {
            throw PreflightError(message: """
                Error: could not parse uhubctl version. Raw output:
                \(raw.trimmingCharacters(in: .whitespacesAndNewlines))
                """)
        }

        if compareVersion(version, minimumUhubctlVersion) < 0 {
            let have = version.map(String.init).joined(separator: ".")
            let want = minimumUhubctlVersion.map(String.init).joined(separator: ".")
            throw PreflightError(message: """
                Error: uhubctl \(have) is too old; nanocharger requires >= \(want).
                  Install a newer build from https://github.com/mvp/uhubctl
                """)
        }
    }

    static func locateInPath(_ name: String) -> String? {
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in pathEnv.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = String(dir) + "/" + name
            var st = stat()
            if stat(candidate, &st) == 0 {
                let mode = st.st_mode
                let isRegular = (Int32(mode) & Int32(S_IFMT)) == Int32(S_IFREG)
                let isExec = access(candidate, X_OK) == 0
                if isRegular && isExec {
                    return candidate
                }
            }
        }
        return nil
    }

    static func parseVersion(_ raw: String) -> [Int]? {
        var startIdx: String.Index? = nil
        var i = raw.startIndex
        while i < raw.endIndex {
            if raw[i].isNumber {
                startIdx = i
                break
            }
            i = raw.index(after: i)
        }
        guard let start = startIdx else { return nil }

        var end = start
        while end < raw.endIndex {
            let c = raw[end]
            if c.isNumber || c == "." {
                end = raw.index(after: end)
            } else {
                break
            }
        }
        let versionStr = raw[start ..< end]
        let nums = versionStr
            .split(separator: ".", omittingEmptySubsequences: true)
            .compactMap { Int($0) }
        return nums.isEmpty ? nil : nums
    }

    static func compareVersion(_ a: [Int], _ b: [Int]) -> Int {
        let n = max(a.count, b.count)
        for i in 0 ..< n {
            let ai = i < a.count ? a[i] : 0
            let bi = i < b.count ? b[i] : 0
            if ai < bi { return -1 }
            if ai > bi { return 1 }
        }
        return 0
    }
}
