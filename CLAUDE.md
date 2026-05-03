# NanoCharger

Swift command-line tool that schedules USB charging across many devices plugged into the same host. Designed to run on a Raspberry Pi acting as a powered-USB-hub controller; target platform requires `uhubctl` (>= 2.6.0) to toggle per-port VBUS power. Intended use case: a charging station where N phones are plugged in and at most `maxConcurrentOn` (default 2) actually draw power at any moment, rotating per-device based on configured charge duration and rest interval.

The project is a SwiftPM executable (`nanocharger`), Swift 6.2 / language mode v6, minimum macOS 14 for the dev build. macOS is a development target only — real `uhubctl` calls are gated behind `#if os(macOS)` and replaced with print stubs and a fixture file (`Sources/input.txt`).

## Subcommands

- `nanocharger` (no subcommand) → defaults to `ui`.
- `nanocharger ui` — interactive TUI: shows all hubs and ports, navigate with arrows, toggle port power with `p`, quit with Esc or Ctrl+C. Polls every 1 s and highlights changed ports.
- `nanocharger daemon --config <path> --state-dir <path>` — long-lived scheduler driven by a JSON config. Defaults: `/etc/nanocharger/schedule.json`, `/var/lib/nanocharger/`.

Both modes run a preflight check at startup that verifies `uhubctl` is on `PATH` and is at least version 2.6.0 (handles distro-suffixed versions like `2.6.0-1`). On macOS preflight prints a one-line dev/stub-mode notice and continues.

## Layout

- `Package.swift` — SwiftPM manifest. Dependencies: `swift-argument-parser` (CLI parsing) and `swift-subprocess` (shells out to `uhubctl`). `input.txt` is excluded from the build.
- `Sources/NanoCharger.swift` — `@main`, `AsyncParsableCommand` root, `UICommand`, `DaemonCommand`. Default subcommand is `ui`.
- `Sources/UsbDevice.swift` — `UsbDevice` (VID:PID + name + UUID/serial), `UsbConnection { hubId, portId }` with `setPower(_ on: Bool)`, and `Topology` / `UsbHub` / `UsbPort` plus the `uhubctl` output parser. The parser captures empty ports and the `ppps` flag per hub.
- `Sources/Preflight.swift` — `PATH` walk for `uhubctl` and version-string parsing (handles `2.6.0`, `2.6.0-1`, `v2.6.0`, etc.). Pure read-only checks.
- `Sources/UI/Terminal.swift` — `@MainActor` termios raw-mode wrapper, alt-screen, ANSI primitives (`reverse`, `dim`, `bold`, box-drawing), key reader with 50 ms Esc-vs-CSI disambiguation. Keeps `ISIG` so Ctrl+C still raises `SIGINT`.
- `Sources/UI/HubBrowser.swift` — `@MainActor` selection state + render + 1 s polling diff. Up/down skips non-`ppps` hubs; left/right walks ports within the selected hub. Diffs against the previous Topology and briefly highlights changed ports + writes a one-line status message. `filterLeafPorts(_:)` hides ports that lead to a child hub already in the topology (and hubs left with zero leaf ports), so users only see ports they can actually plug devices into.
- `Sources/Daemon/Schedule.swift` — `DaemonConfig` (JSON Codable) and validation including duty-cycle feasibility warning.
- `Sources/Daemon/Checkpoint.swift` — atomic `state.json` writer (tmp + rename) holding `PortState { chargingSince, lastChargeEndedAt }` per managed port.
- `Sources/Daemon/Scheduler.swift` — actor running the tick loop: stop completed charges, reconcile mismatches, compute eligibility, allocate up to `maxConcurrentOn` slots ordered by longest-waiting, start chosen ports. Persists on every transition + every `checkpointSeconds`.
- `Sources/Configuration.swift`, `Sources/Logging.swift` — small log helpers (route to stderr; the TUI redirects stderr to `/dev/null` while running so stray writes don't corrupt the screen).
- `Sources/input.txt` — captured `uhubctl` snapshot used as the macOS dev fixture (excluded from the build).
- `Packaging/nanocharger.service` — systemd unit (`Restart=always`, `RestartSec=5s`).

See `USBCharging.md` for the scheduler algorithm in detail and `Installation.md` for deployment steps.

## Build / run

```
swift build
swift run nanocharger              # opens the TUI in dev/stub mode
swift run nanocharger daemon --config ./schedule.json --state-dir ./state
```

On macOS, `Topology.read()` reads `Sources/input.txt` instead of executing `uhubctl`, and `UsbConnection.setPower` only prints the command it would have run. On Linux it actually invokes `uhubctl` via `Subprocess.run`.

## Coding rules

- **Primary platform is Linux on Raspberry Pi 4 and Raspberry Pi 5.** All real functionality must work there; macOS is only a development convenience target. When adding code, the Linux/`uhubctl` path is the source of truth — macOS branches behind `#if os(macOS)` exist purely to let development happen on a Mac and must never become the only working path.
- Follow `/Users/alex/Programming/_Scripts/Instructions/CLAUDE.CodeStyle.md` (4-space indent, K&R braces, `case` indented inside `switch`, 120-col limit, straight quotes only, no `@unchecked Sendable`, no `nonisolated(unsafe)`, prefer `@Observable` over `ObservableObject`, use `Mutex` from `Synchronization`).
- Swift 6 language mode is on, so respect strict concurrency. The TUI is `@MainActor`-isolated; the daemon's scheduler is an actor; `Topology`, `DaemonConfig`, `PortState`, etc. are `Sendable` value types.
- Platform-specific behavior is split with `#if os(macOS)` for dev-on-Mac vs. real-on-Linux; preserve that split when adding code that calls `uhubctl`.

## Notes for future edits

- Real device control is `uhubctl -a {on|off} -l <hubId> -p <portId>`. `uhubctl` ports must support `ppps` — the parser captures this flag from each hub's bracketed descriptor.
- Port-power state is detected from the textual flags in `uhubctl`'s port lines (presence of the `off` token means the port is powered off; otherwise it is on). The exact hex bit semantics differ between USB 2 and USB 3, so we rely on `uhubctl`'s own rendering rather than parsing the hex word.
- Adding a new subcommand: declare a new `AsyncParsableCommand` and add it to `NanoCharger.configuration.subcommands`. Both existing subcommands call `Preflight.run(mode:)` first.
