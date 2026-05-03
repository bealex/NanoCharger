// Copyright (c) 2025 Alex Babaev. All rights reserved.

import Foundation

struct ScheduledPort: Codable, Sendable, Hashable {
    var hubId: String
    var portId: String
    var label: String?
    var chargeDurationMinutes: Int
    var restIntervalMinutes: Int
}

struct DaemonConfig: Codable, Sendable {
    var maxConcurrentOn: Int
    var tickSeconds: Int
    var checkpointSeconds: Int
    var ports: [ScheduledPort]

    static func load(from path: String) throws -> DaemonConfig {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(DaemonConfig.self, from: data)
    }

    /// Returns the list of warnings produced by static validation. An empty array means the config is healthy.
    func validate() -> [String] {
        var warnings: [String] = []

        guard maxConcurrentOn > 0 else {
            warnings.append("maxConcurrentOn must be > 0; got \(maxConcurrentOn)")
            return warnings
        }
        guard tickSeconds > 0 else {
            warnings.append("tickSeconds must be > 0; got \(tickSeconds)")
            return warnings
        }
        guard checkpointSeconds > 0 else {
            warnings.append("checkpointSeconds must be > 0; got \(checkpointSeconds)")
            return warnings
        }

        for port in ports {
            if port.chargeDurationMinutes <= 0 {
                warnings.append("port \(port.hubId)/\(port.portId): chargeDurationMinutes must be > 0")
            }
            if port.restIntervalMinutes < 0 {
                warnings.append("port \(port.hubId)/\(port.portId): restIntervalMinutes must be >= 0")
            }
        }

        // Duplicate (hubId, portId) check
        var seen: Set<String> = []
        for port in ports {
            let key = "\(port.hubId)/\(port.portId)"
            if seen.contains(key) {
                warnings.append("duplicate scheduled port: \(key)")
            }
            seen.insert(key)
        }

        // Duty-cycle feasibility: if the sum across all ports of charge/(charge+rest) exceeds maxConcurrentOn,
        // at least one device cannot meet its requested cadence. Warn but don't fail.
        let dutySum = ports.reduce(0.0) { acc, p in
            let total = Double(p.chargeDurationMinutes + p.restIntervalMinutes)
            guard total > 0 else { return acc }
            return acc + Double(p.chargeDurationMinutes) / total
        }
        if dutySum > Double(maxConcurrentOn) + 1e-9 {
            let formatted = String(format: "%.2f", dutySum)
            warnings.append("schedule is over-subscribed: sum of duty cycles = \(formatted), exceeds maxConcurrentOn = \(maxConcurrentOn). Some devices will not get their requested charging cadence.")
        }

        return warnings
    }
}
