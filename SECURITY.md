# Safety & review

Battery Anchor runs a root background service that changes how your Mac charges. This page sets out what it does,
where to look if you want to check the code yourself, and how it has been reviewed and tested, including the limits of
that review.

**In short:** small codebase, no network access, no third-party dependencies, automated build/test/security checks on
every change, and two AI-assisted code reviews with every finding fixed. It has **not** had an independent human
security audit. Read the [disclaimer](README.md) and use it at your own risk.

## What it changes on your Mac

| | |
| --- | --- |
| **Background service** | `battery-anchord`, running as root under the LaunchDaemon `dev.batteryanchor.daemon` (`/Library/LaunchDaemons/`, binary in `/Library/PrivilegedHelperTools/`) |
| **Hardware settings** | Only these SMC keys: `CHTE` (older firmware: `CH0B`/`CH0C`) to pause charging, and `CHIE` (older firmware: `CH0I`) to run on battery while plugged in. Nothing else is written. |
| **Files** | CLI `/usr/local/bin/battery-anchor`, app `/Applications/Battery Anchor.app`, settings and status in `/Library/Application Support/BatteryAnchor/`, log `/Library/Logs/BatteryAnchor.log` |
| **Network** | None. The code contains no networking APIs. |
| **Data** | Nothing is collected or sent anywhere. |
| **Who can change settings** | Admin users (the settings folder is admin-writable). Only root can modify the status file, daemon or LaunchDaemon. |
| **Login item** | Only if you tick "Open at login" in the menu bar app. |

**To undo everything:** `make uninstall` restores normal charging and removes the service, CLI, app, settings and login
item (the log is kept). To restore charging on its own: `sudo /Library/PrivilegedHelperTools/dev.batteryanchor.daemon --restore`.

## Where to look

About 1,700 of the project's ~2,400 source lines run as root or touch hardware:

| File | Lines | What it does |
| --- | ---: | --- |
| [`Sources/battery-anchord/main.swift`](Sources/battery-anchord/main.swift) | 404 | Daemon entry point: sleep/wake and power notifications, config watching, logging |
| [`Sources/AnchorCore/Engine.swift`](Sources/AnchorCore/Engine.swift) | 285 | Control loop and fail-safe rules |
| [`Sources/AnchorCore/ChargeController.swift`](Sources/AnchorCore/ChargeController.swift) | 279 | Which SMC keys are written, with verification and retries |
| [`Sources/AnchorCore/Store.swift`](Sources/AnchorCore/Store.swift) | 216 | Settings and status files (symlink-safe reads and writes) |
| [`Sources/AnchorCore/Policy.swift`](Sources/AnchorCore/Policy.swift) | 123 | When to charge, hold or discharge |
| [`Sources/CSMC/smc.c`](Sources/CSMC/smc.c), [`smc.h`](Sources/CSMC/include/smc.h) | 143 | Low-level SMC access via IOKit |
| [`Sources/AnchorCore/SMC.swift`](Sources/AnchorCore/SMC.swift) | 67 | Swift wrapper for SMC reads and writes |
| [`Sources/AnchorCore/SystemState.swift`](Sources/AnchorCore/SystemState.swift) | 29 | Lid and dark-wake detection |
| [`scripts/install.sh`](scripts/install.sh), [`uninstall.sh`](scripts/uninstall.sh) | 166 | Run with `sudo` |

**Dependencies:** none beyond Apple's system frameworks (Foundation, IOKit, AppKit, SwiftUI, ServiceManagement).
`Package.swift` declares no package dependencies.

## Testing

- **Unit tests (53):**
  - charging policy
  - the daemon's fail-safe behaviour, against a fake charge controller
  - SMC write failures and verification, against a fake SMC
  - settings and status file safety (symlinks, invalid config, read-modify-write)
- **CI on every push and pull request** ([workflow](.github/workflows/ci.yml)):
  - build, unit tests and app bundle on macOS
  - [ShellCheck](https://www.shellcheck.net/) on the install and uninstall scripts
- **CodeQL** ([workflow](.github/workflows/codeql.yml)): GitHub's security-and-quality scanning of the Swift and C code, on every push and weekly. Results appear under the repository's Security tab.
- **Dry-run scenarios** (author's machine, daemon running without SMC writes): off/on, turning off, clean stop, crash and restart, invalid config at startup.
- **Real hardware:** long-term testing on a MacBook is not yet recorded here.

## AI-assisted review log

These are static code reviews by an AI model. They are useful for catching bugs, but they are **not** an independent
security audit and can miss things; the second review found issues the first didn't. Findings about macOS behaviour
(sleep, dark wake, clamshell mode) were reasoned from Apple's APIs, not reproduced on hardware.

| Date | Code reviewed | Reviewer | Focus | Findings | Result |
| --- | --- | --- | --- | ---: | --- |
| 2026-09-15 | Pre-release, before the initial commit (then named "Keel") | Claude Opus 5 via Claude Code `/code-review` (xhigh) | Correctness, security, efficiency | 15 | All fixed |
| 2026-09-15 | Pre-release Battery Anchor, before the initial commit | Claude Opus 5 via Claude Code `/code-review` (xhigh) | Defensive programming and interaction with macOS | 15 | All fixed |

### Review 1: correctness, security, efficiency

- Running on battery while plugged in could stay on through sleep and drain the battery. **Fixed:** never while asleep.
- An unreadable config file could be silently replaced with defaults. **Fixed:** read-modify-write; invalid files are refused, not overwritten.
- A daemon restart lost an in-progress charge. **Fixed:** the phase is persisted.
- **Security:** the root daemon set file permissions by path in an admin-writable folder, a symlink race that could lead to root. **Fixed:**
  - status moved to a root-only folder
  - temp files created with `O_EXCL | O_NOFOLLOW`
  - permissions set on the open file
  - reads refuse symlinks and FIFOs
- Reinstalling could leave the daemon unloaded. **Fixed:** wait for bootout, enable, retry bootstrap.
- Smaller items, all fixed:
  - older-firmware key checks
  - unsupported-hardware reporting and crash loops
  - documentation mismatches
  - polling and duplicated code

### Review 2: defensive programming and macOS interaction

- **Could drain the battery while plugged in:**
  - An unreadable battery reading left the charger bypassed. **Fixed:** normal charging restored.
  - A full disk crashed the daemon via logging. **Fixed:** crash-proof, size-capped logging.
  - A failed write could let the Mac sleep with the charger bypassed. **Fixed:** the charger is always re-attached before sleep.
  - Restoring stopped at the first failed write. **Fixed:** every key is attempted and verified.
- **Sleep and lid:**
  - Power Nap and maintenance wakes were treated as full wakes. **Fixed:** system capabilities are checked.
  - Running on battery with the lid closed could send the Mac to sleep. **Fixed:** it never discharges in clamshell mode.
- **Could leave charging limited:**
  - A one-off hardware setup failure was permanent. **Fixed:** retried every 30 s.
  - Uninstall could report success falsely and leave a login item. **Fixed:** verified restore; login item removed.
  - A status could claim "restored" when it wasn't. **Fixed:** the status is now honest.
  - An invalid config at startup turned the limit off. **Fixed:** last applied settings kept; writes flushed to disk.
- **Coexistence:**
  - "Off" kept overriding macOS charging features. **Fixed:** it releases control.
  - A reading bouncing at the max flipped the charger on and off. **Fixed:** hysteresis.
  - Another tool fighting over the keys grew the log without bound. **Fixed:** log cap, notification coalescing and an interference warning.
  - Writes weren't verified. **Fixed:** read back after writing.
  - The config watcher wasn't re-armed. **Fixed.**

### Fixes found in use

| Date | Issue | Fix |
| --- | --- | --- |
| 2026-09-23 | With "Pause charging during sleep" on, an overnight charge stopped at the recharge level instead of near the maximum (reported at 61% with a 70% maximum and a 10-point buffer). | The sleep pause now follows the maximum, stopping 2 points below it and finishing on wake, so the buffer no longer affects sleep charging. |

## Reporting a problem

- **Security issues:** please report privately via
  [GitHub private vulnerability reporting](https://github.com/vivian-farrell/battery-anchor/security/advisories/new)
  rather than a public issue.
- **Other bugs**, including anything that affects charging: [open an issue](https://github.com/vivian-farrell/battery-anchor/issues).
  Include `battery-anchor status` output and the relevant part of `/Library/Logs/BatteryAnchor.log`.

The software is provided under the [MIT License](LICENSE), without warranty of any kind.
