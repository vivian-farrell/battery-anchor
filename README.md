# Battery Anchor

Holds an Apple Silicon MacBook's battery at a maximum charge level. It runs the Mac from the charger instead of
topping the battery up.

> **Use at your own risk.** Battery Anchor runs a root daemon that changes how your Mac charges by writing to
> undocumented SMC keys. It's for Apple Silicon MacBooks only and isn't affiliated with or endorsed by Apple, and a
> macOS or firmware update could change how those keys behave. See [Failing safe](#failing-safe) and
> [Limitations](#limitations), and run `make uninstall` if anything looks wrong.

- **On:** charges to the maximum (default 80%), then stops charging. The Mac runs from the charger, and the battery
  neither charges nor drains. Small drifts below the max (80 → 79 → 78) never trigger a top-up. Charging starts again
  only once the battery falls to the **recharge level**, 5 points below the max by default (75% for an 80% max).
  You can change that gap.
- **Above the max:** if the battery is above the max (say you turn it on at 95%), the Mac runs on battery while
  plugged in until it's down to the max, then holds. Once it has reached the max, it only starts discharging again at
  2 points above, so a reading that wobbles between 80% and 81% doesn't flip the charger on and off.
- **Max at or near the current level:** if the battery is already within the window (between the recharge level and the max), it holds immediately.
- **Off:** macOS charges normally. Battery Anchor restores normal charging once, then leaves the charge settings
  alone, so macOS features such as Optimized Battery Charging keep working.
- **Pause charging during sleep (on by default):** if charging is under way and the battery is already within the window when the Mac sleeps, charging stops, so a closed lid can't carry it past the max. Below the window it keeps charging, and can overshoot until the next wake.

## Install

Requires macOS 13+ on Apple Silicon and the Xcode Command Line Tools.

```sh
make install        # builds, then asks for sudo to install the daemon, CLI and app
open "/Applications/Battery Anchor.app"
```

This installs:

| Component | Location | Role |
| --- | --- | --- |
| `battery-anchord` daemon | `/Library/PrivilegedHelperTools/dev.batteryanchor.daemon` + LaunchDaemon `dev.batteryanchor.daemon` | Runs as root. Watches battery level, sleep/wake and config changes, and writes the SMC keys. |
| `battery-anchor` CLI | `/usr/local/bin/battery-anchor` | Command-line control |
| Battery Anchor.app | `/Applications/Battery Anchor.app` | Menu bar UI (use "Open at login" in its panel) |
| Status | `/Library/Application Support/BatteryAnchor/status.json` | Written by the daemon (directory is root-only) |
| Settings | `/Library/Application Support/BatteryAnchor/settings/config.json` | Written by the CLI and app (directory is admin-writable) |
| Log | `/Library/Logs/BatteryAnchor.log` | Rotated at 1 MB (one previous file kept as `.log.1`) |

**Other charge limiters conflict with Battery Anchor.** AlDente, `battery` (actuallymentor) and similar tools write
the same SMC keys, and whichever writes last wins. Uninstall them first. Also turn off *System Settings → Battery →
Battery Health → Optimized Battery Charging*. If something keeps changing the settings back, the status shows a
warning and the log stops recording each change.

Uninstall with `make uninstall`. It restores normal charging and removes the login item. If restoring fails, it
says so, exits with an error, and keeps the daemon binary so you can retry with `sudo battery-anchord --restore`.

## CLI

```sh
battery-anchor                  # status
battery-anchor on               # hold at the configured max
battery-anchor on 80            # hold at 80%
battery-anchor off              # charge normally
battery-anchor max 70           # change the max
battery-anchor buffer 10        # charge again once 10 points below the max
battery-anchor sleep-pause on|off
battery-anchor smc              # show the SMC keys in use
battery-anchor status --json
```

If `config.json` becomes invalid, the daemon keeps the last good settings, including across restarts. The CLI and app
refuse to save over it with defaults. Fix or delete the file to continue.

## How it works

A MacBook's charger chip can power the system without charging the battery. Battery Anchor controls it through SMC keys:

| Purpose | Current firmware | Older firmware |
| --- | --- | --- |
| Stop charging (Mac runs from the charger) | `CHTE` = `01000000` | `CH0B`/`CH0C` = `02` |
| Bypass the charger (run on battery while plugged in, to get down to the max) | `CHIE` = `08` | `CH0I` = `01` |

The daemon re-checks its decision whenever:

- the power source changes (each 1% step, plug/unplug; bursts are coalesced),
- the config file changes,
- the Mac is about to sleep or wakes,
- or 60 seconds pass.

The charging logic is in `Sources/AnchorCore` (`Policy.swift`, `Engine.swift`) and has unit tests.

### Failing safe

Anything uncertain goes back to normal charging.

- **Battery can't be read:** normal charging is restored until readings come back.
- **Sleep:** the charger is never left bypassed. Before sleep it is re-attached, even if the rest of the update failed.
- **Brief background wakes** (Power Nap and maintenance wakes, with the lid possibly closed) are treated as asleep. They don't start discharging or resume a paused charge.
- **Lid closed:** it never runs on battery. Clamshell mode needs AC, so the Mac would go to sleep.
- **Failed writes:** every key is attempted, and each change is read back to confirm it took. The charger is only bypassed if everything else succeeded, and any failure re-attaches it.
- **Daemon stopping** (uninstall, `launchctl bootout`, shutdown): it restores normal charging if it had changed anything. If that fails, the status says so instead of claiming success.
- **Daemon crash:** the next run finds that the previous one didn't restore normal charging, and restores or re-applies the settings.
- **Restarts mid-charge:** whether it's charging up, holding or discharging is saved, so a restart carries on.
- **Hardware not ready at startup:** the daemon keeps reporting the error and retries every 30 seconds instead of restarting in a loop.
- **Critical battery:** at 5% or below, it always allows charging.
- **Logging:** logging can't crash the daemon (a full disk just loses log lines), and the log file is size-capped.

## Limitations

- While the Mac is shut down, the SMC resets and charges normally. The limit applies again once macOS boots.
- Apple Silicon only. Intel Macs use different keys (`BCLM`).
- The SMC keys are undocumented, so a future firmware could change them. Run `battery-anchor smc` to see what's detected.
- While it runs on battery to get down to the max, macOS treats the Mac as unplugged. Battery-only settings apply:
  Low Power Mode if it's set to "Only on Battery", battery display and sleep timers, and "Prevent automatic sleeping
  on power adapter" stops applying.
- If the Mac draws more power than the charger supplies (e.g. a small USB-C charger under heavy load), the battery
  covers the shortfall and will drain slowly even while holding.

## Development

```sh
make test       # unit tests
make run-dry    # run the daemon loop against ./.dev without touching the SMC
BATTERY_ANCHOR_SUPPORT_DIR=$PWD/.dev swift run battery-anchor on 80   # drive it from another terminal
```

## License

MIT — see [LICENSE](LICENSE).
