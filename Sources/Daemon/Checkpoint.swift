// Copyright (c) 2025 Alex Babaev. All rights reserved.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct PortState: Codable, Sendable, Hashable {
    var hubId: String
    var portId: String
    /// Wall-clock seconds since the reference date when the in-progress charge started, or nil if not charging.
    var chargingSince: TimeInterval?
    /// Wall-clock seconds since the reference date when the most recent completed charge ended, or nil if never charged.
    var lastChargeEndedAt: TimeInterval?
}

struct CheckpointFile: Codable, Sendable {
    var savedAt: TimeInterval
    var ports: [PortState]
}

struct Checkpoint {
    let path: String

    init(stateDir: String) {
        self.path = stateDir.hasSuffix("/")
            ? stateDir + "state.json"
            : stateDir + "/state.json"
    }

    func ensureDirectory() throws {
        let dir = (path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    func load() -> CheckpointFile? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CheckpointFile.self, from: data)
    }

    func write(_ file: CheckpointFile) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [ .prettyPrinted, .sortedKeys ]
        let data = try encoder.encode(file)
        let tmpPath = path + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmpPath), options: .atomic)
        if rename(tmpPath, path) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
