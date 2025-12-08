// Copyright (c) 2025 Alex Babaev. All rights reserved.

import Foundation
import Subprocess

/**
 05ac:12a8 Apple Inc. iPhone 6a49859aedc620eacc6943c34e8586417c655afa
                             6a49859aedc620eacc6943c34e8586417c655afa
 05ac:12a8 Apple Inc. iPhone 00008020001575602E85402E
                             00008020-001575602E85402E
 */

struct UsbConnection: Hashable, Comparable {
    var hubId: String
    var portId: String

    static func == (lhs: UsbConnection, rhs: UsbConnection) -> Bool {
        return lhs.hubId == rhs.hubId && lhs.portId == rhs.portId
    }

    static func < (lhs: UsbConnection, rhs: UsbConnection) -> Bool {
        return lhs.hubId == rhs.hubId
            ? lhs.portId < rhs.portId
            : lhs.hubId < rhs.hubId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(hubId)
        hasher.combine(portId)
    }

    func startCharging() async throws {
        #if os(macOS)
        print("(fake) Started charging: hub \(hubId); port: \(portId)")
        #else
        // uhubctl -a on -l ${hub} -p ${port}
        let uhubctlResult = try await run(.name("uhubctl"), arguments: [ "-a", "off", "-l", hubId, "-p", portId ], output: .string(limit: 1 << 20))
        log(uhubctlResult.standardOutput ?? "no output", level: .debug)
        #endif
    }

    func stopCharging() async throws {
        #if os(macOS)
        print("(fake) Stopped charging: hub \(hubId); port: \(portId)")
        #else
        // uhubctl -a on -l ${hub} -p ${port}
        let uhubctlResult = try await run(.name("uhubctl"), arguments: [ "-a", "on", "-l", hubId, "-p", portId ], output: .string(limit: 1 << 20))
        log(uhubctlResult.standardOutput ?? "no output", level: .debug)
        #endif
    }
}

struct UsbDevice: Hashable, Comparable {
    var deviceId: String
    var deviceName: String
    var deviceUUID: String

    static func == (lhs: UsbDevice, rhs: UsbDevice) -> Bool {
        return lhs.deviceId == rhs.deviceId && lhs.deviceUUID == rhs.deviceUUID
    }

    static func < (lhs: UsbDevice, rhs: UsbDevice) -> Bool {
        return lhs.deviceId == rhs.deviceId
            ? lhs.deviceUUID < rhs.deviceUUID
            : lhs.deviceId < rhs.deviceId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(deviceId)
        hasher.combine(deviceUUID)
    }

    static func connectedUsbDevices(noHubs: Bool = true) async throws -> [UsbDevice: UsbConnection] {
        #if os(macOS)
        let fileUrl = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "input.txt")
        let uhubctlResult = try String(contentsOf: fileUrl, encoding: .utf8)
        var lines: [String] = uhubctlResult.split(separator: "\n").map { "\($0)" }
        #else
        let uhubctlResult = try await run(.name("uhubctl"), arguments: [], output: .string(limit: 1 << 20))
        var lines: [String] = (uhubctlResult.standardOutput ?? "").split(separator: "\n").map { "\($0)" }
        #endif

        lines = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        log(lines.joined(separator: "\n"))

        var result: [UsbDevice: UsbConnection] = [:]

        func isDeviceOk(name: String, id: String) -> Bool {
            guard noHubs else { return true }

            let name = name.lowercased()
            if name.contains("generic usb") && name.contains("hub") || name.contains("usb2.0 hub") {
                return false
            }

            return true
        }

        var currentHubId: String?
        for line in lines {
            if line.hasPrefix("Current status for hub") {
                log("Found hub: “\(line)”")
                let parts = line.components(separatedBy: " ")
                if parts.count > 4 {
                    currentHubId = parts[4]
                    log(" ... processing hub “\(currentHubId ?? "nil")”")
                }
            } else if line.hasPrefix("Port ") {
                log(" Found port \(line)")
                let parts = line.components(separatedBy: .init(charactersIn: " :"))
                let deviceInfoParts = line.components(separatedBy: .init(charactersIn: "[]"))
                guard parts.count > 1, deviceInfoParts.count > 1, let currentHubId else { continue }

                let portId = parts[1]
                let deviceId = String(deviceInfoParts[1].prefix(9))
                let deviceNameAndUUID = String(deviceInfoParts[1].dropFirst(10).trimmingCharacters(in: .whitespaces))
                let (deviceName, deviceUUID) = if let lastSpaceIndex = deviceNameAndUUID.lastIndex(of: " ") {
                    (
                        String(deviceNameAndUUID[deviceNameAndUUID.startIndex ..< lastSpaceIndex]).trimmingCharacters(in: .whitespaces),
                        String(deviceNameAndUUID[deviceNameAndUUID.index(after: lastSpaceIndex)...]).trimmingCharacters(in: .whitespaces),
                    )
                } else {
                    (deviceNameAndUUID, "—")
                }

                log(" ... id \(portId): (\(deviceId), \(deviceName))")

                if isDeviceOk(name: deviceName, id: deviceId) {
                    log(" + device \(currentHubId) / \(portId) (\(deviceId) / \(deviceName) / \(deviceUUID)) can be controlled", level: .info)
                    result[.init(deviceId: deviceId, deviceName: deviceName, deviceUUID: deviceUUID)] =
                        .init(hubId: currentHubId, portId: portId)
                }
            }
        }
        return result
    }
}
