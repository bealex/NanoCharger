// Copyright (c) 2025 Alex Babaev. All rights reserved.

import Foundation

actor Scheduler {
    private let config: DaemonConfig
    private let checkpoint: Checkpoint

    private var states: [String: PortState] = [:]
    private var lastCheckpointAt: TimeInterval = 0

    init(config: DaemonConfig, checkpoint: Checkpoint) {
        self.config = config
        self.checkpoint = checkpoint
    }

    func runForever() async {
        await recoverOnStartup()
        let interval = max(1, config.tickSeconds)
        while !Task.isCancelled {
            do {
                try await tick()
            } catch {
                log("tick failed: \(error)", level: .info)
            }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    // MARK: - Startup recovery

    private func recoverOnStartup() async {
        states.removeAll()
        // Seed states for every configured port.
        for p in config.ports {
            states[key(p.hubId, p.portId)] = .init(
                hubId: p.hubId,
                portId: p.portId,
                chargingSince: nil,
                lastChargeEndedAt: nil
            )
        }

        // Load and merge persisted state.
        if let loaded = checkpoint.load() {
            let now = Date.timeIntervalSinceReferenceDate
            for persisted in loaded.ports {
                let k = key(persisted.hubId, persisted.portId)
                guard var s = states[k] else { continue }
                if let chargingSince = persisted.chargingSince {
                    // Charge was interrupted at the checkpoint timestamp.
                    let durationLimit = chargingSince + Double(durationSeconds(for: persisted.hubId, persisted.portId) ?? 0)
                    let endedAt = min(max(loaded.savedAt, chargingSince), durationLimit)
                    s.chargingSince = nil
                    s.lastChargeEndedAt = min(endedAt, now)
                } else {
                    s.lastChargeEndedAt = persisted.lastChargeEndedAt
                }
                states[k] = s
            }
            log("Recovered checkpoint from \(Date(timeIntervalSinceReferenceDate: loaded.savedAt))", level: .info)
        } else {
            log("No prior checkpoint; starting fresh.", level: .info)
        }

        // Reconcile actual hardware state to our model: anything we don't think should be on, turn off.
        // Also warn about configured ports that don't exist on any visible hub.
        do {
            let topology = try await Topology.read()
            var visiblePorts: Set<String> = []
            for hub in topology.hubs {
                for port in hub.ports {
                    visiblePorts.insert(key(hub.id, port.id))
                    if port.powerOn, let state = states[key(hub.id, port.id)], state.chargingSince == nil {
                        log("Reconcile: \(key(hub.id, port.id)) is on but should be off; turning off.", level: .info)
                        try? await UsbConnection(hubId: hub.id, portId: port.id).setPower(false)
                    }
                }
            }
            for configured in states.keys where !visiblePorts.contains(configured) {
                log("Warning: configured port \(configured) is not visible in uhubctl output; will be skipped until it appears.", level: .info)
            }
        } catch {
            log("Recovery topology read failed: \(error)", level: .info)
        }

        try? await persist()
    }

    // MARK: - Tick

    private func tick() async throws {
        let now = Date.timeIntervalSinceReferenceDate
        let topology = try await Topology.read()
        let presentPorts = presentPortsLookup(topology: topology)

        // 1) Stop completed charges.
        var didTransition = false
        for (k, var state) in states {
            if let started = state.chargingSince {
                let cfg = configFor(hubId: state.hubId, portId: state.portId)
                let durationSec = Double((cfg?.chargeDurationMinutes ?? 0) * 60)
                if now - started >= durationSec {
                    log("Stop charging \(k) (duration reached)", level: .info)
                    try? await UsbConnection(hubId: state.hubId, portId: state.portId).setPower(false)
                    state.chargingSince = nil
                    state.lastChargeEndedAt = now
                    states[k] = state
                    didTransition = true
                }
            }
        }

        // 2) Diagnostic mismatch detection: if a port we think isn't charging is on, log + reconcile.
        for (k, state) in states {
            if state.chargingSince == nil, let port = presentPorts[k], port.powerOn {
                log("Reconcile: \(k) is on but state says off; turning off.", level: .info)
                try? await UsbConnection(hubId: state.hubId, portId: state.portId).setPower(false)
            }
        }

        // 3) Compute eligibility.
        var eligible: [(state: PortState, waitingSince: TimeInterval)] = []
        for (k, state) in states {
            guard state.chargingSince == nil else { continue }
            guard presentPorts[k] != nil else { continue }
            let cfg = configFor(hubId: state.hubId, portId: state.portId)
            let restSec = Double((cfg?.restIntervalMinutes ?? 0) * 60)
            let waitSince: TimeInterval
            if let endedAt = state.lastChargeEndedAt {
                if now - endedAt < restSec { continue }
                waitSince = endedAt
            } else {
                waitSince = 0 // never charged: maximum priority
            }
            eligible.append((state, waitSince))
        }

        // 4) Allocate slots.
        let currentlyCharging = states.values.filter { $0.chargingSince != nil }.count
        let freeSlots = max(0, config.maxConcurrentOn - currentlyCharging)
        if freeSlots == 0 { return }

        // Sort by longest waiting first; tie-break by config order.
        let configIndex: [String: Int] = Dictionary(uniqueKeysWithValues: config.ports.enumerated().map { (key($1.hubId, $1.portId), $0) })
        eligible.sort { lhs, rhs in
            if lhs.waitingSince != rhs.waitingSince {
                return lhs.waitingSince < rhs.waitingSince
            }
            let li = configIndex[key(lhs.state.hubId, lhs.state.portId)] ?? Int.max
            let ri = configIndex[key(rhs.state.hubId, rhs.state.portId)] ?? Int.max
            return li < ri
        }

        // 5) Start chosen ports.
        for choice in eligible.prefix(freeSlots) {
            let k = key(choice.state.hubId, choice.state.portId)
            log("Start charging \(k)", level: .info)
            try? await UsbConnection(hubId: choice.state.hubId, portId: choice.state.portId).setPower(true)
            var s = states[k]!
            s.chargingSince = now
            states[k] = s
            didTransition = true
        }

        // 6) Persist on transition + every checkpointSeconds.
        if didTransition || now - lastCheckpointAt >= Double(config.checkpointSeconds) {
            try? await persist()
        }
    }

    // MARK: - Helpers

    private func persist() async throws {
        let now = Date.timeIntervalSinceReferenceDate
        let file = CheckpointFile(savedAt: now, ports: Array(states.values))
        try checkpoint.write(file)
        lastCheckpointAt = now
    }

    private func key(_ hubId: String, _ portId: String) -> String {
        "\(hubId)/\(portId)"
    }

    private func configFor(hubId: String, portId: String) -> ScheduledPort? {
        config.ports.first(where: { $0.hubId == hubId && $0.portId == portId })
    }

    private func durationSeconds(for hubId: String, _ portId: String) -> Int? {
        configFor(hubId: hubId, portId: portId).map { $0.chargeDurationMinutes * 60 }
    }

    /// Every port that exists on any hub the host can see right now, regardless of whether a device is enumerated.
    /// Required because turning a port off via `uhubctl` makes the connected device disappear from enumeration —
    /// if we only counted "connected" ports as eligible, we'd never re-power a port we ourselves just turned off.
    private func presentPortsLookup(topology: Topology) -> [String: UsbPort] {
        var result: [String: UsbPort] = [:]
        for hub in topology.hubs {
            for port in hub.ports {
                result[key(hub.id, port.id)] = port
            }
        }
        return result
    }
}
