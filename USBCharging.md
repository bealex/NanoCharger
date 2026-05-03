# USB Charging — How It Works

This document describes how NanoCharger discovers USB devices and rotates charging between them, based on the current code in `Sources/`.

## The underlying mechanism: `uhubctl`

NanoCharger does not implement USB power control itself. It shells out to [`uhubctl`](https://github.com/mvp/uhubctl), a Linux CLI that toggles per-port VBUS on USB hubs that support per-port power switching (the `ppps` capability shown in `uhubctl` output). Two operations are used:

- **List topology**: `uhubctl` with no arguments. Output is parsed line by line into a `Topology`.
- **Toggle a port**: `uhubctl -a {on|off} -l <hubId> -p <portId>`, exposed as `UsbConnection.setPower(_ on: Bool)` (`Sources/UsbDevice.swift`).

On macOS the same calls are stubbed: `Topology.read()` reads `Sources/input.txt` (a captured `uhubctl` dump), and `setPower` just prints the command it would have run. This lets the scheduler and TUI be developed on macOS without real hardware.

A version >= 2.6.0 is required and enforced at startup by `Sources/Preflight.swift`. The version parser handles distro-suffixed versions like `2.6.0-1` by ignoring everything after the first non-numeric character.

## Identifying devices and ports

Three value types model the system (all in `Sources/UsbDevice.swift`):

- `UsbConnection { hubId, portId }` — a physical socket. `hubId` is the bus-path string `uhubctl` prints after `Current status for hub` (e.g. `1-1.2`, `2-2.4`); `portId` is the integer after `Port ` on the indented lines.
- `UsbDevice { deviceId, deviceName, deviceUUID }` — what is plugged in. `deviceId` is the USB VID:PID (`05ac:12a8`); `deviceUUID` is the per-device serial that `uhubctl` prints inside the brackets after the device name. Equality and hashing use `(deviceId, deviceUUID)` only.
- `UsbHub { id, descriptor, supportsPPPS, ports: [UsbPort] }` and `UsbPort { id, device: UsbDevice?, powerOn: Bool }` — the inverted view used by both the TUI and the daemon. Includes empty ports and carries the per-hub `ppps` flag.

`Topology.parse(_:)` walks `uhubctl`'s text output:

1. Lines starting with `Current status for hub` flush the previous hub and start a new one. The 4th whitespace-separated token is `hubId`. The bracketed descriptor is captured verbatim, and `supportsPPPS` is set to `true` iff the descriptor contains `ppps`.
2. Lines starting with `Port ` are parsed as ports of the current hub. The hex status word is the first token after the colon; the bracketed `[VID:PID Name UUID]` descriptor (if any) is parsed into a `UsbDevice`.
3. **Power state** comes from the textual flags in the port line: presence of an `off` token means the port is powered off; otherwise it is on. This avoids hard-coding USB-2-vs-USB-3 hex bit constants and matches what `uhubctl` itself prints based on the port-status bit.

Empty ports and sub-hubs are kept in the topology — the TUI shows them; the daemon ignores ports it isn't configured to manage.

## Daemon scheduling

The daemon (`Sources/Daemon/Scheduler.swift`) runs as a long-lived process under systemd. Its job: rotate power between configured ports such that each device gets a `chargeDurationMinutes` charge no more often than `restIntervalMinutes` apart, with at most `maxConcurrentOn` ports powered simultaneously.

### Configuration

Per-port (`Sources/Daemon/Schedule.swift`):

- `chargeDurationMinutes` — how long one charge cycle lasts.
- `restIntervalMinutes` — minimum gap between the end of one charge and the start of the next for that port.

Top-level:

- `maxConcurrentOn` — slot cap (default 2).
- `tickSeconds` — how often the scheduler re-evaluates.
- `checkpointSeconds` — periodic safety-net write to `state.json` (the daemon also writes on every charge transition).

At load time, `DaemonConfig.validate()` checks for duplicates, non-positive durations, and **duty-cycle feasibility**: if the sum of `chargeDuration / (chargeDuration + restInterval)` across all ports exceeds `maxConcurrentOn`, the schedule is over-subscribed and at least one device cannot meet its requested cadence. This is logged as a warning — the daemon still starts and does the best it can.

### Per-port state

`PortState` (`Sources/Daemon/Checkpoint.swift`) is the authoritative state per managed port:

- `chargingSince: TimeInterval?` — wall-clock start of the in-progress charge, or `nil`.
- `lastChargeEndedAt: TimeInterval?` — wall-clock end of the most recent completed charge, or `nil` if never charged.

These two fields plus the per-port config are sufficient to drive every decision the scheduler makes.

### Tick loop

Every `tickSeconds`, in `Scheduler.tick()`:

1. **Stop completed charges**: for each port with `chargingSince != nil`, if `now - chargingSince >= chargeDurationMinutes * 60`, call `setPower(false)`, set `lastChargeEndedAt = now`, clear `chargingSince`.
2. **Mismatch reconciliation**: if a port the daemon thinks isn't charging is actually powered (per a fresh `uhubctl` read), turn it off. Catches manual `uhubctl` calls and the TUI's `p` keypress race.
3. **Compute eligibility**: a port is eligible to start iff it isn't charging, the device is physically connected, and `lastChargeEndedAt == nil` or `now - lastChargeEndedAt >= restIntervalMinutes * 60`.
4. **Allocate slots**: `freeSlots = maxConcurrentOn - (currently charging count)`. Pick up to `freeSlots` eligible ports, sorted by waiting time (longest since `lastChargeEndedAt` first, never-charged getting maximum priority); ties broken by config order.
5. **Start chosen ports**: `setPower(true)`, set `chargingSince = now`.
6. **Persist** the checkpoint if any transition happened in this tick or `checkpointSeconds` has elapsed since the last write.

Stops are issued before starts within a tick, so the slot cap is never momentarily exceeded.

### Checkpoint and recovery

`Sources/Daemon/Checkpoint.swift` writes the `CheckpointFile { savedAt, ports: [PortState] }` to `<state-dir>/state.json` atomically (write to `state.json.tmp`, then `rename`).

On startup, `Scheduler.recoverOnStartup()`:

1. Seeds an empty `PortState` for every configured port.
2. If a checkpoint exists, merges in the persisted `lastChargeEndedAt`. For any port that was `chargingSince != nil` at checkpoint time, treats the charge as **interrupted at the checkpoint timestamp** — sets `lastChargeEndedAt` to the checkpoint timestamp (capped by what would be the natural end time and by `now`) and clears `chargingSince`. This is conservative: a device may have only received part of its charge, but the rest interval is counted from the interruption rather than from a hypothetical full completion. Avoids back-to-back charging right after a crash.
3. Reads the current hardware topology and turns off any port that's powered but isn't supposed to be charging according to the recovered model.

The scheduler is wall-clock driven, so a 4-hour outage leaves the daemon correct on resume — not 4 hours behind.

### Process supervision

`Packaging/nanocharger.service` is the systemd unit. `Restart=always` and `RestartSec=5s` cover crashes; auto-start on boot covers power loss; the checkpoint covers "approximately the same state". See `Installation.md`.

## TUI

`Sources/UI/HubBrowser.swift` is a separate code path that does **not** use the scheduler — it's a direct browser/toggle for the topology, intended for diagnosis (locally on the Pi or over SSH).

- Polls `Topology.read()` every 1 s, diffs against the previous snapshot, and briefly highlights any port whose `device` or `powerOn` changed (1.5 s flash plus a status-line message). Detects changes from any source: physical plug/unplug, the daemon, manual `uhubctl`, or another TUI instance.
- **Hides hub-to-hub ports.** A port whose connected device is itself a hub that appears elsewhere in the topology is filtered out before rendering, since the user can't plug anything new into it. The detection uses the Linux USB bus-path convention: hub `<parent>` connected via port `<n>` produces a child hub with id `<parent>-<n>` (top-level) or `<parent>.<n>` (nested). Hubs that have no leaf ports left after filtering are hidden entirely. Filtering is TUI-only — the daemon's parser sees the full topology.
- Up/down moves the cursor between hubs, **skipping hubs that don't support `ppps`** (these are still shown, dimmed). Left/right moves between ports of the selected hub.
- `p` calls `setPower` on the selected port and forces an immediate re-poll.
- `Esc` and `Ctrl+C` quit; `Ctrl+C` is delivered as `SIGINT` (the TUI keeps `ISIG` enabled in `termios`) and goes through the same shutdown path. There is no `q` quit.

The TUI redirects stderr to `/dev/null` while it owns the screen, so stray `log()` output during the 1 s poll loop doesn't corrupt the rendering.

## Sample data

`Sources/input.txt` is a real `uhubctl` snapshot from a Raspberry Pi (`Linux 6.12.47+rpt-rpi-v8`) with a tree of Realtek `0bda:0411`/`0bda:5411` hubs, all advertising `ppps`. Three "leaf" devices appear in the snapshot:

- `1-1.2.4` port 1 — Apple iPhone (UUID `6a49859a…`)
- `1-1.2`   port 1 — Google Pixel 8 Pro (`3A100DLJG0014M`)
- `1-1.2`   port 2 — Apple iPhone (UUID `00008020001575602E85402E`)
