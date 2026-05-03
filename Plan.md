# Plan — Terminal UI and Daemon Mode

**Status: implemented.** This was the design plan; the code now lives in `Sources/`. Use `CLAUDE.md` for the as-built code map, `USBCharging.md` for the scheduler walk-through, and `Installation.md` for deployment steps. The plan is kept here as a record of the design decisions and the rationale behind them.

The single TBD that remained at the end of design — which exact bit of the `uhubctl` hex status word represents port power — was sidestepped at implementation time: the parser uses the textual `off` flag that `uhubctl` itself prints rather than parsing the hex word, so the same code works for USB 2 and USB 3 hubs.

## Prerequisite (both features depend on this)

`UsbConnection.startCharging` / `stopCharging` are currently inverted and have the wrong inline comment (`Sources/UsbDevice.swift:32`, `Sources/UsbDevice.swift:42`). Both new features rely on a correct "power on/off this port" primitive, so the first change is a small refactor:

- Replace the two methods with one `setPower(_ on: Bool) async throws` that runs `uhubctl -a {on|off} -l hubId -p portId`.
- Rework the four call sites in `ChargingState` against the new method (and fix the queue-rotation / `chargingLoop`-not-started bugs noted in `USBCharging.md` — independent, but cheap to do at the same time).

---

## CLI restructuring

`swift-argument-parser` is already a declared dependency but unused (`Package.swift:15`). Switch `@main` from a `struct` to an `AsyncParsableCommand` with subcommands:

- `nanocharger` (no subcommand) → defaults to `ui`.
- `nanocharger ui` — interactive TUI.
- `nanocharger daemon --config <path> [--state-dir <path>]` — schedule runner.

The current one-shot `list` behavior is dropped; the TUI replaces it.

### Startup environment check (every mode)

Before any subcommand does work, the binary verifies its runtime preconditions and exits early with a clear message if any are missing. All checks are **read-only** — they never mutate hub state.

Checks:
1. **`uhubctl` present and executable** — resolve via `PATH` in Swift (walk `getenv("PATH")` and stat each candidate; do not rely on `which`/`command -v`, since those are shell built-ins and behave differently across shells). On failure, print:
   ```
   Error: required tool 'uhubctl' was not found in PATH.
     Install it on Raspberry Pi OS with: sudo apt install uhubctl
     Source: https://github.com/mvp/uhubctl
   ```
   and exit non-zero.
2. **`uhubctl` runnable and minimum version** — invoke `uhubctl --version` (read-only, no hub I/O). Parse the version string and refuse to start if older than **2.6.0**.
   - **Version parser must handle distro-suffixed versions** like `2.6.0-1` (Debian/Raspberry Pi OS package format), `2.6.0-rc1`, `v2.6.0`, and stray whitespace/newlines. Strategy: split the trimmed output on the first non-`[0-9.]` character, parse the leading dotted-numeric prefix into `[Int]`, and compare component-wise against `[2, 6, 0]`. Anything after the first non-numeric character (`-1`, `-rc1`, build metadata) is ignored for the comparison — a `2.6.0-1` package is treated as ≥ 2.6.0 and accepted. Reject only if the leading numeric prefix is strictly less than the pinned minimum or if no numeric prefix is found at all (in which case print the captured `--version` output verbatim and exit, so the user can see what `uhubctl` actually said).
3. **Platform sanity** — on Linux, after the first topology read, *warn* (not fail) if no hub advertises `ppps`; the binary still runs but power toggling will be a no-op everywhere. On macOS, print a one-line "running in dev/stub mode (uhubctl calls are faked)" notice and continue using `Sources/input.txt`.
4. **Daemon-only checks** — config file readable + parses + passes static validation; state directory writable. Performed only when starting `daemon`.

Implementation: a single `func preflight(mode: Mode) throws` called from each subcommand's `run()`. Error type `PreflightError` with a `userMessage` so we never leak raw `errno`/CLI usage on a missing tool. The TUI mode does the check **before** entering the alt screen, so error text actually reaches the terminal.

---

## Feature 1 — Terminal UI (default mode)

### Approach: raw ANSI, no TUI library

Pi 4/5 is the target; minimizing native deps matters. Pure ANSI + `termios` is enough for what's described and works identically over local console and SSH (confirmed requirement). A library like swift-tui / curses is not worth the dependency.

What this involves:
- Enter alt screen (`ESC[?1049h`) + hide cursor (`ESC[?25l`); restore on exit and on `SIGINT` / `SIGTERM` / `SIGHUP` (signal handler must run the cleanup, otherwise terminal stays broken).
- `termios`: clear `ICANON` and `ECHO`, set `VMIN=1`, `VTIME=0`. Keep `ISIG` enabled so Ctrl+C continues to raise `SIGINT` and goes through the same shutdown path as a window close. Restore original termios on exit. There is no Foundation wrapper — needs `#if canImport(Glibc)` / `Darwin` shim.
- Key reading: read stdin one byte at a time. Arrow keys arrive as `ESC [ A/B/C/D`; `p` = `0x70`. **Quit keys: Ctrl+C (handled via `SIGINT`) and Esc.** No `q`. Esc also starts arrow-key escape sequences, so the decoder uses a ~50 ms `VTIME` window after a bare ESC: if no byte follows, treat as quit; otherwise consume the rest of the CSI sequence.
- Box-drawing with U+2500-range characters. Black bg / white fg via `ESC[40;37m`. Reverse video (`ESC[7m`) for selection — easier than a second color pair. Greyed-out non-`ppps` hubs use dim (`ESC[2m`) — supported by every terminal NanoCharger will run under.
- Render strategy: full-screen redraw on each event (poll tick OR keypress). Pi terminals are fast enough; double-buffering + diffing is overkill.
- SSH: confirmed required. ANSI alt-screen, hide-cursor, dim, and reverse-video all pass through SSH unchanged. The terminal type comes from `$TERM` set by the SSH client.

### Layout

```
┌──────────────────────────────────────────────────────────┐
│ Hub 1-1.2  [0bda:5411 Generic USB2.1 Hub]  ppps          │  <- selected hub: double border
│  ╔══════╗ ┌──────┐ ┌──────┐ ┌──────┐                     │
│  ║ P1●  ║ │ P2●  │ │ P3   │ │ P4   │                     │
│  ╚══════╝ └──────┘ └──────┘ └──────┘                     │
│                                                          │
│ Hub 2-2    [0bda:0411 Generic USB3.2 Hub]  ppps          │
│  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐                     │
│  │ P1   │ │ P2   │ │ P3●  │ │ P4●  │                     │
│  └──────┘ └──────┘ └──────┘ └──────┘                     │
│                                                          │
│ Hub 1      [2109:3431 USB2.0 Hub] (no power switching)   │  <- non-ppps: dim, skipped by ↑↓
│                                                          │
│ Selected: 1-1.2 / Port 1 — 18d1:4ee7 Google Pixel 8 Pro  │
├──────────────────────────────────────────────────────────┤
│ ↑↓ hub   ←→ port   p toggle power   Esc / Ctrl+C quit    │
└──────────────────────────────────────────────────────────┘
```

- `●` marks a port with something connected; absence = empty.
- Selected hub gets a double border around its port row; selected port within that hub also gets a double border so both axes are visible at once.
- **Non-`ppps` hubs are rendered in dim and are skipped by ↑/↓ navigation** (decided). They still appear in the list so the user can see the full topology, but the selection cursor never lands on them and `p` is never a possibility.
- The "Selected: …" line shows the device name only for the currently selected port — matches the requirement and keeps each port cell narrow.

### Data flow

- `UsbDevice.connectedUsbDevices()` returns a flat `[UsbDevice: UsbConnection]` keyed by device. The TUI needs the inverse — hubs and *all* their ports including empty ones. Two changes to the parser:
  1. Capture port lines even when no `[…]` device is present (today they are silently skipped because `deviceInfoParts.count > 1` fails).
  2. Capture per-hub `ppps` flag from the bracketed hub descriptor on `Current status for hub` lines.

  New return shape: `[Hub]` where `Hub { id, descriptor, supportsPPPS, ports: [Port] }` and `Port { id, status: .empty | .connected(UsbDevice), powerOn: Bool }`. Power-on status comes from the port's hex status word.
  - **TBD** — verify the exact bit semantics of the hex status word against `uhubctl` source (`port_status_t` / `USB_PORT_STAT_POWER` for USB 2, `USB_SS_PORT_STAT_POWER` for USB 3) and the USB 2.0/3.0 spec port-status tables. Plausible candidates: bit `0x0100` for USB 2, possibly different for USB 3 SuperSpeed. Will commit to a constant only after reading the source.
- **External state changes must be reflected in the UI** — devices plugged/unplugged, ports powered on/off by the daemon or by another `uhubctl` invocation, hub disappearing entirely. Detection strategy:
  - **Polling is the primary mechanism**, because port-power toggles caused by another process produce no kernel event — only re-reading `uhubctl` output catches them. Poll interval: **~1 s**. On a Pi 4/5 a single `uhubctl` invocation is cheap (well under 50 ms); 1 s is responsive without being noisy.
  - Each poll produces a `Topology` snapshot. The renderer **diffs** against the previous snapshot:
    - if equal, skip the redraw (no flicker, no SSH bandwidth);
    - if different, redraw and **briefly highlight** changed ports for ~1.5 s (reverse-video flash on the port cell, plus a short event line in the status row, e.g. `1-1.2/3 connected: 18d1:4ee7 Pixel 8 Pro` or `2-2/4 power off`). The highlight makes external changes visible at a glance instead of just "the screen looks slightly different".
  - Selection survives change: if the currently selected hub or port disappears, the cursor moves to the nearest surviving sibling (next port on the same hub, else next hub). If a previously-absent device appears at the selection, no movement.
  - Hub-disappearance (whole bus path gone) is handled the same way as device-disappearance — drop from the list, redraw, log to the status line.
- After a local `p` toggle, force an immediate re-poll so the visible state flips without waiting for the next tick.
- **Optional later optimization (not required for v1)**: subscribe to Linux udev for USB hotplug events to drop reaction latency on connect/disconnect from ~1 s to immediate. Power-toggle changes still require polling, so udev is purely additive — not a replacement for the polling loop. Skip until polling proves insufficient in practice.

### Module split

- `Sources/UI/Terminal.swift` — termios + alt-screen + signal handling, raw key reader, paint primitives.
- `Sources/UI/HubBrowser.swift` — selection state, key dispatch, render.
- `Sources/UsbDevice.swift` — extend the parser as above. Add a richer `Topology` API alongside the existing `[UsbDevice: UsbConnection]`.

---

## Feature 2 — Daemon mode

### Scheduling model: declarative per-device, computed plan

The schedule is **not** authored as time windows. Instead, each managed port declares two intervals:

- `chargeDurationMinutes` — how long one charge cycle should last.
- `restIntervalMinutes` — minimum time between the end of one charge and the start of the next for that port.

The daemon computes when each port should actually be on. This is a per-tick decision, not a precomputed weekly plan, so the schedule self-corrects after disconnects, restarts, and config edits.

### Config file

Location: `--config` path, default `/etc/nanocharger/schedule.json` (system install per requirement). JSON to avoid pulling in a YAML/TOML dep. Schema:

```json
{
  "maxConcurrentOn": 2,
  "tickSeconds": 60,
  "checkpointSeconds": 600,
  "ports": [
    {
      "hubId": "1-1.2",
      "portId": 1,
      "label": "iPhone (kitchen)",
      "chargeDurationMinutes": 120,
      "restIntervalMinutes": 360
    },
    {
      "hubId": "1-1.2",
      "portId": 2,
      "label": "iPhone (office)",
      "chargeDurationMinutes": 90,
      "restIntervalMinutes": 300
    }
  ]
}
```

`maxConcurrentOn` is a configurable field (default 2). Ports not listed in the config are not managed by the daemon — it leaves them untouched.

### Per-port state (the authoritative checkpoint)

Each managed port carries:
- `chargingSince: TimeInterval?` — wall-clock start of the in-progress charge, or `nil` if not currently charging.
- `lastChargeEndedAt: TimeInterval?` — wall-clock end of the most recent completed charge, or `nil` if never charged.

These two fields, together with the per-port `chargeDurationMinutes` and `restIntervalMinutes`, are sufficient to drive every decision the scheduler makes. They are persisted (see Checkpoint).

### Tick loop (every `tickSeconds`, default 60)

1. **Read topology** via `uhubctl`.
2. **Stop completed charges**: for each port with `chargingSince != nil`, if `now - chargingSince >= chargeDurationMinutes * 60`, call `setPower(false)`, set `lastChargeEndedAt = now`, clear `chargingSince`. Persist immediately (transition write).
3. **Compute eligibility**: a port is *eligible to start* iff
   - `chargingSince == nil`, AND
   - device is physically connected (skip absent ports), AND
   - `lastChargeEndedAt == nil` OR `now - lastChargeEndedAt >= restIntervalMinutes * 60`.
4. **Allocate slots**: `freeSlots = maxConcurrentOn - (count of ports with chargingSince != nil)`. Pick up to `freeSlots` eligible ports, ordered by *waiting time* (longest since `lastChargeEndedAt`, with never-charged sorted oldest). Tie-break by port order in config.
5. **Start chosen ports**: call `setPower(true)`, set `chargingSince = now`. Persist immediately (transition write).
6. **Diagnostic mismatch**: if any managed port's actual `uhubctl`-reported power state disagrees with our `chargingSince` view, log a warning and reconcile (re-issue the desired `setPower`). This catches manual `uhubctl` calls and the TUI's `p` keypress race.

Stop-before-start ordering means we never momentarily exceed the slot cap.

### Checkpoint

Every-10-minute checkpoint per requirement, plus an additional write on every state transition (charge start/end). The transition writes are tiny and make recovery exact instead of "approximate"; the 10-min ticker is the safety net the user explicitly asked for.

- File: `--state-dir` (default `/var/lib/nanocharger/state.json`, system install).
- Contents: `{ savedAt, ports: [ { hubId, portId, chargingSince, lastChargeEndedAt } ] }`.
- Atomic write: write to `state.json.tmp` then `rename` — never leaves a half-written file across a power cut.

### Recovery on startup

After preflight:
1. Load `state.json` if present. If missing, all ports start with no history — every connected managed port is immediately eligible.
2. **Interrupted-charge handling**: for any port with `chargingSince != nil` in the loaded state, treat the charge as having been interrupted at the checkpoint timestamp. Set `lastChargeEndedAt = max(savedAt, chargingSince + chargeDurationMinutes * 60)` capped at `now`, clear `chargingSince`. This is conservative: the device may not have received its full charge, but the rest interval is counted from the interruption, not from when the charge would have completed. **Rationale**: avoid back-to-back charging right after a crash, and avoid silently "skipping" a charge that was actually partial.
3. Read actual `uhubctl` power state for managed ports. If the kernel/hub kept ports powered through the daemon's restart, reconcile our model to match (turn them off if our recovered state says they shouldn't be on).
4. Enter the tick loop.

This gets us to "approximately the same state" — within one tick and within the resolution of the checkpoint.

### Constraint enforcement

Two layers:
1. **Static feasibility check at config load**: for each port, the steady-state duty cycle is `chargeDurationMinutes / (chargeDurationMinutes + restIntervalMinutes)`. Sum these; if the sum exceeds `maxConcurrentOn`, the configuration is over-subscribed (some devices will not get their requested charging cadence). Log a warning and continue — do not refuse to start, since the daemon will still do the best it can.
2. **Runtime cap**: step 4 of the tick loop never allocates more than `freeSlots`, so the cap is enforced regardless of config.

### Process supervision

systemd unit (confirmed) at `Packaging/nanocharger.service`:

```
[Unit]
Description=NanoCharger scheduler
After=network.target

[Service]
ExecStart=/usr/local/bin/nanocharger daemon --config /etc/nanocharger/schedule.json
Restart=always
RestartSec=5s
User=nanocharger

[Install]
WantedBy=multi-user.target
```

`Restart=always` covers crashes; auto-start on boot covers power loss; the checkpoint covers "resume to approximately the same state". Document install steps in the README (copy unit, `systemctl enable --now nanocharger`).

### Logging

stdout/stderr only — captured by the journal. No file rotation logic.

### Module split

- `Sources/Daemon/Schedule.swift` — config types + feasibility check.
- `Sources/Daemon/Scheduler.swift` — tick loop, eligibility, slot allocation.
- `Sources/Daemon/Checkpoint.swift` — atomic JSON read/write, recovery semantics.
- `Sources/Preflight.swift` — shared startup tool/environment checks.
- `Packaging/nanocharger.service` — systemd unit.

---

## Build order (followed during implementation)

1. Fix `UsbConnection.setPower` and the `uhubctl` parser extensions (shared by both features).
2. Switch `@main` to `swift-argument-parser` with subcommands; default subcommand = `ui`.
3. Implement preflight (tool availability + version pin + read-only checks).
4. Build the TUI.
5. Build the daemon + scheduler + checkpoint + systemd unit.

All five steps are complete; see `CLAUDE.md` for the as-built file map and `USBCharging.md` for behavior.
