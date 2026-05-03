// Copyright (c) 2025 Alex Babaev. All rights reserved.

import Foundation
import ArgumentParser

@main
struct NanoCharger: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nanocharger",
        abstract: "USB charger scheduler for a Raspberry Pi running uhubctl-controlled hubs.",
        subcommands: [ UICommand.self, DaemonCommand.self ],
        defaultSubcommand: UICommand.self
    )
}

struct UICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui",
        abstract: "Interactive terminal UI to inspect and toggle USB hub power."
    )

    func run() async throws {
        do {
            try await Preflight.run(mode: .ui)
        } catch let e as PreflightError {
            FileHandle.standardError.write(Data((e.message + "\n").utf8))
            throw ExitCode(1)
        }

        let terminal = await MainActor.run { Terminal() }
        do {
            try await terminal.enterRawMode()
        } catch {
            FileHandle.standardError.write(Data("Failed to enter raw mode: \(error)\n".utf8))
            throw ExitCode(1)
        }
        await terminal.silenceStderr()
        await terminal.enterAltScreen()

        let browser = await HubBrowser(terminal: terminal)
        await browser.runUntilQuit()

        await terminal.exitAltScreen()
        await terminal.restoreStderr()
        await terminal.restoreMode()
    }
}

struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Run the charging scheduler as a long-lived background process."
    )

    @Option(name: .long, help: "Path to the JSON schedule config.")
    var config: String = "/etc/nanocharger/schedule.json"

    @Option(name: .customLong("state-dir"), help: "Directory for the persistent state file.")
    var stateDir: String = "/var/lib/nanocharger"

    func run() async throws {
        do {
            try await Preflight.run(mode: .daemon)
        } catch let e as PreflightError {
            FileHandle.standardError.write(Data((e.message + "\n").utf8))
            throw ExitCode(1)
        }

        let cfg: DaemonConfig
        do {
            cfg = try DaemonConfig.load(from: config)
        } catch {
            FileHandle.standardError.write(Data("Failed to load config '\(config)': \(error)\n".utf8))
            throw ExitCode(1)
        }

        for warning in cfg.validate() {
            log("config warning: \(warning)", level: .info)
        }

        let checkpoint = Checkpoint(stateDir: stateDir)
        let scheduler = Scheduler(config: cfg, checkpoint: checkpoint)

        log("nanocharger daemon starting; \(cfg.ports.count) port(s) managed, maxConcurrentOn=\(cfg.maxConcurrentOn)", level: .info)
        await scheduler.runForever()
    }
}
