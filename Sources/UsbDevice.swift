// Copyright (c) 2025 Alex Babaev. All rights reserved.

import Foundation
import Subprocess

struct UsbDevice: Hashable, Sendable {
    var deviceId: String
    var deviceName: String
    var deviceUUID: String
}

struct UsbConnection: Hashable, Sendable {
    var hubId: String
    var portId: String

    func setPower(_ on: Bool) async throws {
        let action = on ? "on" : "off"
        #if os(macOS)
        log("(fake) uhubctl -a \(action) -l \(hubId) -p \(portId)", level: .info)
        #else
        let result = try await run(.name("uhubctl"), arguments: [ "-a", action, "-l", hubId, "-p", portId ], output: .string(limit: 1 << 20))
        log(result.standardOutput ?? "no output", level: .debug)
        #endif
    }
}

struct UsbPort: Hashable, Sendable {
    var id: String
    var device: UsbDevice?
    var powerOn: Bool

    var isConnected: Bool { device != nil }
}

struct UsbHub: Hashable, Sendable {
    var id: String
    var descriptor: String
    var supportsPPPS: Bool
    var ports: [UsbPort]
}

struct Topology: Hashable, Sendable {
    var hubs: [UsbHub]

    static let empty: Topology = .init(hubs: [])

    static func read() async throws -> Topology {
        let raw = try await readRaw()
        return parse(raw)
    }

    static func readRaw() async throws -> String {
        #if os(macOS)
        let fileUrl = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "input.txt")
        return try String(contentsOf: fileUrl, encoding: .utf8)
        #else
        let result = try await run(.name("uhubctl"), arguments: [], output: .string(limit: 1 << 20))
        return result.standardOutput ?? ""
        #endif
    }

    static func parse(_ raw: String) -> Topology {
        var hubs: [UsbHub] = []

        var currentHubId: String?
        var currentDescriptor: String = ""
        var currentSupportsPPPS = false
        var currentPorts: [UsbPort] = []

        func flush() {
            if let id = currentHubId {
                hubs.append(.init(id: id, descriptor: currentDescriptor, supportsPPPS: currentSupportsPPPS, ports: currentPorts))
            }
            currentHubId = nil
            currentDescriptor = ""
            currentSupportsPPPS = false
            currentPorts = []
        }

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("Current status for hub") {
                flush()
                let parts = line.components(separatedBy: " ")
                if parts.count > 4 {
                    currentHubId = parts[4]
                }
                if let openIdx = line.firstIndex(of: "["), let closeIdx = line.lastIndex(of: "]"), openIdx < closeIdx {
                    let inside = line[line.index(after: openIdx) ..< closeIdx]
                    currentDescriptor = String(inside)
                    currentSupportsPPPS = inside.contains("ppps")
                }
            } else if line.hasPrefix("Port "), currentHubId != nil {
                if let port = parsePortLine(line) {
                    currentPorts.append(port)
                }
            }
        }
        flush()
        return .init(hubs: hubs)
    }

    private static func parsePortLine(_ line: String) -> UsbPort? {
        guard let colonIdx = line.firstIndex(of: ":") else { return nil }
        let head = line[line.startIndex ..< colonIdx]
        let portIdRaw = String(head.dropFirst("Port ".count)).trimmingCharacters(in: .whitespaces)
        guard !portIdRaw.isEmpty else { return nil }

        let afterColon = String(line[line.index(after: colonIdx) ..< line.endIndex]).trimmingCharacters(in: .whitespaces)
        let bracketStart = afterColon.firstIndex(of: "[")
        let flagsEnd: String.Index = bracketStart ?? afterColon.endIndex
        let flagsPart = afterColon[afterColon.startIndex ..< flagsEnd]
        let flagTokens = flagsPart.split(separator: " ").map { String($0) }
        // tokens are: <hex_status>, then a series of textual flags. uhubctl prints "off" iff power bit is clear.
        let powerOn: Bool
        if flagTokens.count <= 1 {
            powerOn = false
        } else {
            powerOn = !flagTokens.dropFirst().contains("off")
        }

        var device: UsbDevice? = nil
        if let s = bracketStart, let e = afterColon.lastIndex(of: "]"), s < e {
            let inside = String(afterColon[afterColon.index(after: s) ..< e])
            device = parseDeviceDescriptor(inside)
        }

        return .init(id: portIdRaw, device: device, powerOn: powerOn)
    }

    private static func parseDeviceDescriptor(_ inside: String) -> UsbDevice? {
        guard inside.count >= 9 else { return nil }
        let deviceId = String(inside.prefix(9))
        guard deviceId.contains(":") else { return nil }
        let rest = String(inside.dropFirst(9)).trimmingCharacters(in: .whitespaces)
        if rest.isEmpty {
            return .init(deviceId: deviceId, deviceName: "", deviceUUID: "—")
        }
        if let lastSpace = rest.lastIndex(of: " ") {
            let name = String(rest[rest.startIndex ..< lastSpace]).trimmingCharacters(in: .whitespaces)
            let uuid = String(rest[rest.index(after: lastSpace) ..< rest.endIndex]).trimmingCharacters(in: .whitespaces)
            return .init(deviceId: deviceId, deviceName: name, deviceUUID: uuid)
        } else {
            return .init(deviceId: deviceId, deviceName: rest, deviceUUID: "—")
        }
    }
}
