// Copyright (c) 2025 Alex Babaev. All rights reserved.

import Foundation
import Subprocess

struct Configuration {
    var chargingDuration: TimeInterval
}

struct UsbDevice: Hashable {
    var deviceId: String
    var deviceName: String

    var hubId: String
    var portId: String

    static func == (lhs: UsbDevice, rhs: UsbDevice) -> Bool {
        return lhs.hubId == rhs.hubId && lhs.portId == rhs.portId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(hubId)
        hasher.combine(portId)
    }
}

@main
struct NanoCharger {
    private static func connectedUsbDevices(noHubs: Bool = true) throws -> [UsbDevice] {
        #if os(macOS)
        let fileUrl = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "input.txt")
        let uhubctlResult = try String(contentsOf: fileUrl, encoding: .utf8)
        var lines: [String] = uhubctlResult.split(separator: "\n").map { "\($0)" }
        #else
        let uhubctlResult = try await run(.name("uhubctl"), arguments: [], output: .string(limit: 1 << 20))
        var lines: [String] = (uhubctlResult.standardOutput ?? "").split(separator: "\n")
        #endif

        lines = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var result: [UsbDevice] = []

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
                let parts = line.components(separatedBy: " ")
                if parts.count > 4 {
                    currentHubId = parts[4]
                }
            } else if line.hasPrefix("Port ") {
                let parts = line.components(separatedBy: .init(charactersIn: " :"))
                let deviceInfoParts = line.components(separatedBy: .init(charactersIn: "[]"))
                guard parts.count > 1, deviceInfoParts.count > 1, let currentHubId else { continue }

                let portId = parts[1]
                let deviceId = String(deviceInfoParts[1].prefix(9))
                let deviceName = String(deviceInfoParts[1].dropFirst(10).trimmingCharacters(in: .whitespacesAndNewlines))

                if isDeviceOk(name: deviceName, id: deviceId) {
                    result.append(.init(deviceId: deviceId, deviceName: deviceName, hubId: currentHubId, portId: portId))
                }
            }
        }
        return result
    }

    static func main() async {
        print("Start")

        do {
            let devices = try connectedUsbDevices()
            print(devices.map { "\($0.hubId); \($0.portId) -> \($0.deviceId); \($0.deviceName)" }.joined(separator: "\n"))
        } catch {
            print("Error \(error)")
        }

        print("Finish")
    }
}

