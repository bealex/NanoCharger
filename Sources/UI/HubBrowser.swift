// Copyright (c) 2025 Alex Babaev. All rights reserved.

import Foundation
import Dispatch

@MainActor
final class HubBrowser {
    private let terminal: Terminal
    private var topology: Topology = .empty
    private var hubIndex: Int = 0
    private var portIndex: Int = 0

    private var statusLine: String = ""
    private var statusLineExpiresAt: Date = .distantPast

    private struct ChangeMark {
        var hubId: String
        var portId: String
        var expiresAt: Date
    }
    private var recentChanges: [ChangeMark] = []

    private var quitContinuation: CheckedContinuation<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var stdinReaderTask: Task<Void, Never>?
    private var stdinConsumerTask: Task<Void, Never>?
    private var didQuit: Bool = false

    init(terminal: Terminal) {
        self.terminal = terminal
    }

    func runUntilQuit() async {
        installSignalHandlers()
        await initialPoll()
        startPollingLoop()
        startStdinLoop()
        render()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.quitContinuation = cont
        }

        pollTask?.cancel()
        stdinReaderTask?.cancel()
        stdinConsumerTask?.cancel()
    }

    private func installSignalHandlers() {
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let sighupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGHUP, SIG_IGN)

        let handler: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                self?.requestQuit()
            }
        }
        sigintSource.setEventHandler(handler: handler)
        sigtermSource.setEventHandler(handler: handler)
        sighupSource.setEventHandler(handler: handler)

        sigintSource.resume()
        sigtermSource.resume()
        sighupSource.resume()
    }

    private func initialPoll() async {
        do {
            let t = try await Topology.read()
            applyTopology(t, isInitial: true)
        } catch {
            statusLine = "Failed to read topology: \(error)"
            statusLineExpiresAt = Date().addingTimeInterval(5)
        }
    }

    private func startPollingLoop() {
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                do {
                    let t = try await Topology.read()
                    applyTopology(t, isInitial: false)
                } catch {
                    setStatus("Topology read failed: \(error)", durationSeconds: 3)
                }
                render()
            }
        }
    }

    private func startStdinLoop() {
        let term = self.terminal
        let (stream, continuation) = AsyncStream.makeStream(of: Key.self)

        stdinReaderTask = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                guard let key = term.readKeyBlocking() else { break }
                continuation.yield(key)
            }
            continuation.finish()
        }

        stdinConsumerTask = Task { @MainActor [weak self] in
            for await key in stream {
                self?.handle(key: key)
            }
        }
    }

    private func requestQuit() {
        guard !didQuit else { return }
        didQuit = true
        if let cont = quitContinuation {
            quitContinuation = nil
            cont.resume()
        }
    }

    // MARK: - Input

    private func handle(key: Key) {
        switch key {
            case .escape:
                requestQuit()
                return
            case .char(let c):
                if c == "\u{03}" {
                    requestQuit()
                    return
                }
                if c == "p" || c == "P" {
                    Task { @MainActor in await togglePower() }
                }
            case .up:
                moveHub(by: -1)
            case .down:
                moveHub(by: 1)
            case .left:
                movePort(by: -1)
            case .right:
                movePort(by: 1)
            case .other:
                break
        }
        render()
    }

    private func moveHub(by delta: Int) {
        let controllable = controllableHubIndices()
        guard !controllable.isEmpty else { return }
        let pos = controllable.firstIndex(of: hubIndex) ?? 0
        let nextPos = max(0, min(controllable.count - 1, pos + delta))
        hubIndex = controllable[nextPos]
        let portCount = topology.hubs[hubIndex].ports.count
        if portCount == 0 {
            portIndex = 0
        } else if portIndex >= portCount {
            portIndex = portCount - 1
        }
    }

    private func movePort(by delta: Int) {
        guard hubIndex < topology.hubs.count else { return }
        let portCount = topology.hubs[hubIndex].ports.count
        guard portCount > 0 else { return }
        portIndex = max(0, min(portCount - 1, portIndex + delta))
    }

    private func controllableHubIndices() -> [Int] {
        var result: [Int] = []
        for (i, hub) in topology.hubs.enumerated() where hub.supportsPPPS {
            result.append(i)
        }
        return result
    }

    // MARK: - Power toggle

    private func togglePower() async {
        guard hubIndex < topology.hubs.count else { return }
        let hub = topology.hubs[hubIndex]
        guard hub.supportsPPPS else {
            setStatus("Hub \(hub.id) does not support per-port power switching", durationSeconds: 3)
            return
        }
        guard portIndex < hub.ports.count else { return }
        let port = hub.ports[portIndex]
        let connection = UsbConnection(hubId: hub.id, portId: port.id)
        let target = !port.powerOn
        do {
            try await connection.setPower(target)
            setStatus("\(hub.id)/\(port.id) -> power \(target ? "on" : "off")", durationSeconds: 2)
            // Force an immediate re-poll so the display reflects the change.
            do {
                let t = try await Topology.read()
                applyTopology(t, isInitial: false)
            } catch {
                // ignore — next tick will pick it up
            }
            render()
        } catch {
            setStatus("Power toggle failed: \(error)", durationSeconds: 4)
            render()
        }
    }

    // MARK: - Topology + change detection

    private func applyTopology(_ next: Topology, isInitial: Bool) {
        if isInitial {
            topology = next
            recenterSelectionIfNeeded()
            return
        }
        // Diff against current
        var changes: [ChangeMark] = []
        var statusBits: [String] = []

        let oldByHub: [String: UsbHub] = Dictionary(uniqueKeysWithValues: topology.hubs.map { ($0.id, $0) })
        let newByHub: [String: UsbHub] = Dictionary(uniqueKeysWithValues: next.hubs.map { ($0.id, $0) })

        for (hubId, oldHub) in oldByHub where newByHub[hubId] == nil {
            statusBits.append("hub \(hubId) gone")
            _ = oldHub
        }
        for (hubId, newHub) in newByHub {
            let oldHub = oldByHub[hubId]
            if oldHub == nil {
                statusBits.append("hub \(hubId) new")
            }
            let oldPortsById: [String: UsbPort] = Dictionary(uniqueKeysWithValues: (oldHub?.ports ?? []).map { ($0.id, $0) })
            for newPort in newHub.ports {
                if let oldPort = oldPortsById[newPort.id] {
                    if oldPort.device != newPort.device {
                        if newPort.device != nil {
                            statusBits.append("\(hubId)/\(newPort.id) connected: \(newPort.device!.deviceId) \(newPort.device!.deviceName)")
                        } else {
                            statusBits.append("\(hubId)/\(newPort.id) disconnected")
                        }
                        changes.append(.init(hubId: hubId, portId: newPort.id, expiresAt: Date().addingTimeInterval(1.5)))
                    } else if oldPort.powerOn != newPort.powerOn {
                        statusBits.append("\(hubId)/\(newPort.id) power \(newPort.powerOn ? "on" : "off")")
                        changes.append(.init(hubId: hubId, portId: newPort.id, expiresAt: Date().addingTimeInterval(1.5)))
                    }
                }
            }
        }

        topology = next
        recenterSelectionIfNeeded()
        if !changes.isEmpty {
            recentChanges.append(contentsOf: changes)
        }
        if !statusBits.isEmpty {
            setStatus(statusBits.joined(separator: ", "), durationSeconds: 3)
        }
    }

    private func recenterSelectionIfNeeded() {
        let controllable = controllableHubIndices()
        if controllable.isEmpty {
            hubIndex = 0
            portIndex = 0
            return
        }
        if !controllable.contains(hubIndex) {
            // pick nearest controllable hub
            hubIndex = controllable.min(by: { abs($0 - hubIndex) < abs($1 - hubIndex) }) ?? controllable[0]
        }
        let portCount = topology.hubs[hubIndex].ports.count
        if portCount == 0 {
            portIndex = 0
        } else if portIndex >= portCount {
            portIndex = portCount - 1
        }
    }

    // MARK: - Status line

    private func setStatus(_ text: String, durationSeconds: TimeInterval) {
        statusLine = text
        statusLineExpiresAt = Date().addingTimeInterval(durationSeconds)
    }

    // MARK: - Render

    private func render() {
        // expire timed bits
        let now = Date()
        recentChanges.removeAll(where: { $0.expiresAt < now })
        if statusLineExpiresAt < now {
            statusLine = ""
        }

        let (_, cols) = terminal.size()
        var out = ""
        out += ANSI.baseColors
        out += ANSI.clearScreen

        var row = 1
        for (idx, hub) in topology.hubs.enumerated() {
            let isSelectedHub = (idx == hubIndex)
            let canControl = hub.supportsPPPS
            let prefix = canControl ? "" : ANSI.dim
            let suffix = canControl ? "" : ANSI.reset + ANSI.baseColors

            let pppsTag = hub.supportsPPPS ? "ppps" : "(no power switching)"
            let header = "\(prefix)Hub \(hub.id)  [\(hub.descriptor)]  \(pppsTag)\(suffix)"
            out += ANSI.moveTo(row: row, col: 1) + truncated(header, cols: cols)
            row += 1

            // ports row
            out += ANSI.moveTo(row: row, col: 1)
            var x = 3
            for (pIdx, port) in hub.ports.enumerated() {
                let isSelectedPort = isSelectedHub && pIdx == portIndex && canControl
                let isHighlighted = recentChanges.contains(where: { $0.hubId == hub.id && $0.portId == port.id })
                let cell = renderPortCell(
                    port: port,
                    selected: isSelectedPort,
                    highlighted: isHighlighted,
                    dimHub: !canControl
                )
                out += ANSI.moveTo(row: row, col: x) + cell.top
                out += ANSI.moveTo(row: row + 1, col: x) + cell.mid
                out += ANSI.moveTo(row: row + 2, col: x) + cell.bot
                x += cell.width + 1
            }
            row += 4
        }

        // selected info
        let selInfo = selectedInfo()
        out += ANSI.moveTo(row: row, col: 1) + truncated("Selected: " + selInfo, cols: cols)
        row += 1
        if !statusLine.isEmpty {
            out += ANSI.moveTo(row: row, col: 1) + truncated(statusLine, cols: cols)
            row += 1
        }

        // help line, last row
        let help = "↑↓ hub   ←→ port   p toggle power   Esc / Ctrl+C quit"
        let (rows, _) = terminal.size()
        out += ANSI.moveTo(row: max(rows, row + 1), col: 1)
        out += ANSI.reverse + truncated(help, cols: cols) + ANSI.reset + ANSI.baseColors

        terminal.writeRaw(out)
    }

    private struct PortCell {
        var top: String
        var mid: String
        var bot: String
        var width: Int
    }

    private func renderPortCell(port: UsbPort, selected: Bool, highlighted: Bool, dimHub: Bool) -> PortCell {
        let label = "P\(port.id)\(port.isConnected ? "●" : " ")\(port.powerOn ? "+" : " ")"
        let inner = " \(label) "
        let width = inner.count

        let top: String
        let mid: String
        let bot: String

        var attrPrefix = ""
        var attrSuffix = ""
        if dimHub {
            attrPrefix += ANSI.dim
            attrSuffix = ANSI.reset + ANSI.baseColors
        }
        if highlighted {
            attrPrefix += ANSI.reverse
            attrSuffix = ANSI.reset + ANSI.baseColors
        }
        if selected {
            attrPrefix += ANSI.bold
            attrSuffix = ANSI.reset + ANSI.baseColors
            top = "\(attrPrefix)╔" + String(repeating: "═", count: width) + "╗\(attrSuffix)"
            mid = "\(attrPrefix)║\(inner)║\(attrSuffix)"
            bot = "\(attrPrefix)╚" + String(repeating: "═", count: width) + "╝\(attrSuffix)"
        } else {
            top = "\(attrPrefix)┌" + String(repeating: "─", count: width) + "┐\(attrSuffix)"
            mid = "\(attrPrefix)│\(inner)│\(attrSuffix)"
            bot = "\(attrPrefix)└" + String(repeating: "─", count: width) + "┘\(attrSuffix)"
        }
        return .init(top: top, mid: mid, bot: bot, width: width + 2)
    }

    private func selectedInfo() -> String {
        guard hubIndex < topology.hubs.count else { return "—" }
        let hub = topology.hubs[hubIndex]
        guard portIndex < hub.ports.count else { return "\(hub.id) / —" }
        let port = hub.ports[portIndex]
        if let device = port.device {
            return "\(hub.id) / Port \(port.id) — \(device.deviceId) \(device.deviceName)"
        } else {
            return "\(hub.id) / Port \(port.id) — (empty), power \(port.powerOn ? "on" : "off")"
        }
    }

    private func truncated(_ s: String, cols: Int) -> String {
        // Don't truncate strings carrying ANSI escapes; rely on the visual length being approximately ok.
        // Best-effort: just return as-is; terminals will wrap. For safety in narrow terminals, trim plain text only.
        if s.contains("\u{1b}") {
            return s
        }
        if s.count <= cols { return s }
        return String(s.prefix(cols))
    }
}
