# Installation

## Target platform

Raspberry Pi 4 / 5 running Raspberry Pi OS (Bookworm or newer). The daemon is the production deployment target; the TUI is useful both for diagnosis on the Pi itself and over SSH from another machine.

macOS is a development-only target — real `uhubctl` calls are stubbed and topology is read from `Sources/input.txt`.

## Prerequisites on the Pi

```sh
sudo apt update
sudo apt install uhubctl swift  # uhubctl >= 2.6.0; Swift toolchain to build
uhubctl --version               # confirm the version
```

If your distro packages an older `uhubctl`, build from source: <https://github.com/mvp/uhubctl>.

The hubs you intend to control must support per-port power switching (`ppps`) — `uhubctl` lists this in the bracketed descriptor for each hub. Hubs without `ppps` show up in the TUI but are dimmed and skipped, and the daemon cannot toggle their power.

## Quick install (recommended)

The repo ships an `install.sh` script that does everything below in one shot — build the release binary as your user, then `sudo` to install it, set up `/etc/nanocharger/`, `/var/lib/nanocharger/`, the system user, and the systemd unit, and start the daemon. Safe to re-run for upgrades; it preserves any existing `schedule.json`.

```sh
./install.sh
```

If a default config gets created (i.e. `/etc/nanocharger/schedule.json` didn't exist), the script pauses and offers to open it in `nano` before starting the daemon — discover the real hub/port ids with `nanocharger ui` (or `uhubctl`) in another terminal first.

The rest of this document walks through the same steps manually.

## Build

From a checkout on the Pi:

```sh
swift build -c release
```

The release binary lands at `.build/release/nanocharger`.

## Install the binary and runtime layout

```sh
sudo install -m 0755 .build/release/nanocharger /usr/local/bin/nanocharger
sudo install -d -m 0755 /etc/nanocharger /var/lib/nanocharger
```

The shipped systemd unit runs as **root** by default. Two reasons:

- `uhubctl` requires root (or per-hub udev rules) to toggle VBUS — running unprivileged isn't free anyway.
- A per-user Swift toolchain (e.g. installed via `swiftly` under `$HOME`) is unreadable by a system user, so `User=nanocharger` would leave the daemon unable to load `libswiftCore.so`.

If you want privilege isolation: add `User=<your-user>` to the unit, set up `uhubctl` udev rules for that user, and make sure the Swift runtime libs are readable by that user (mirror them under `/usr/local/lib/swift/linux/` if your toolchain is per-user).

## Swift runtime libraries

Swift binaries on Linux dynamically link to `libswiftCore.so`, `libFoundation.so`, and friends, which are installed under the toolchain prefix and not on the loader's default search path. Register the path once:

```sh
swift -print-target-info | grep -A1 runtimeLibraryPaths
# copy the path it prints, then:
echo /that/path | sudo tee /etc/ld.so.conf.d/swift.conf
sudo ldconfig
```

`./install.sh` does this step automatically.

## Schedule config

A ready-to-edit example lives in the repo root at `schedule.sample.json` — copy it and adjust hub/port ids and durations:

```sh
sudo cp schedule.sample.json /etc/nanocharger/schedule.json
sudoedit /etc/nanocharger/schedule.json
```

The schema:

```json
{
  "maxConcurrentOn": 2,
  "tickSeconds": 60,
  "checkpointSeconds": 600,
  "ports": [
    {
      "hubId": "1-1.2",
      "portId": "1",
      "label": "iPhone (kitchen)",
      "chargeDurationMinutes": 120,
      "restIntervalMinutes": 360
    },
    {
      "hubId": "1-1.2",
      "portId": "2",
      "label": "Pixel 8 Pro",
      "chargeDurationMinutes": 90,
      "restIntervalMinutes": 300
    }
  ]
}
```

Fields:

- `maxConcurrentOn` — never have more than this many ports powered at the same instant.
- `tickSeconds` — how often the scheduler re-evaluates state (60 is a sensible default).
- `checkpointSeconds` — periodic safety-net write to `state.json`. The daemon also writes on every charge start/stop.
- `ports[].hubId` / `portId` — match what `uhubctl` prints (run `nanocharger ui` or `uhubctl` to discover).
- `ports[].chargeDurationMinutes` — how long one charge cycle should run.
- `ports[].restIntervalMinutes` — minimum gap between the *end* of one charge and the *start* of the next for that port.

The daemon validates the config at load time and warns (does not fail) if the sum of duty cycles `chargeDuration / (chargeDuration + restInterval)` across all ports exceeds `maxConcurrentOn` — that means the schedule is over-subscribed and some devices will not get their requested cadence.

## systemd unit

```sh
sudo install -m 0644 Packaging/nanocharger.service /etc/systemd/system/nanocharger.service
sudo systemctl daemon-reload
sudo systemctl enable --now nanocharger
sudo systemctl status nanocharger
```

The unit sets `Restart=always` and `RestartSec=5s`, so power outages and crashes are handled by systemd; on restart the daemon reads `state.json` and reconciles its model with what the hardware actually shows.

Logs are captured by the journal:

```sh
journalctl -u nanocharger -f
```

## Running the TUI

The TUI runs locally or over SSH and does not require the daemon:

```sh
nanocharger        # default subcommand
nanocharger ui     # explicit
```

Key bindings:

- ↑ / ↓ — move between hubs (skips hubs without `ppps`)
- ← / → — move between ports of the selected hub
- `p` — toggle power for the selected port
- `Esc` or `Ctrl+C` — quit

The TUI polls `uhubctl` once per second and highlights changed ports briefly when something is plugged, unplugged, or toggled (including changes made by the daemon while the TUI is watching).

## Development on macOS

```sh
swift build
swift run nanocharger ui      # reads the static fixture from Sources/input.txt
swift run nanocharger daemon --config ./local-schedule.json --state-dir ./local-state
```

In dev mode, every `uhubctl` invocation is faked — `setPower` just logs the command it would have run, and topology is read from `Sources/input.txt` (a captured `uhubctl` snapshot). This is enough to exercise the scheduler logic, the parser, and most of the TUI rendering, but it cannot validate real hardware behavior. For that, deploy to a Pi.

## Verification checklist

After install, verify on the Pi:

1. `nanocharger ui` — every hub you expect appears, `ppps` hubs are bright, others are dim.
2. Press `p` on a port — `journalctl` (or another `uhubctl` invocation in a different shell) confirms the port toggled.
3. `sudo systemctl restart nanocharger; journalctl -u nanocharger -n 20` — recovery logs the prior checkpoint timestamp and reconciles hardware state to match the model.
4. `cat /var/lib/nanocharger/state.json` — entries appear, `chargingSince` is set on whichever port the daemon picked first.
