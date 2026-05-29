# Nano Mac Throttle

Minimal no-root macOS load watcher.

`nano-mac-throttle` watches thermal throttling and memory pressure in one
background LaunchAgent. It sends notifications on meaningful transitions and
keeps the menu bar clean until there is an active thermal or memory issue.

## Why it's lightweight

The design goal is to cost as close to zero as possible while idle:

- **Event-driven, no polling.** Thermal and memory state arrive as kernel
  notifications (`ProcessInfo.thermalStateDidChangeNotification`,
  Darwin `com.apple.system.thermalpressurelevel`, and `DispatchSource` memory
  pressure events). There is no timer waking the process up every few seconds,
  so the CPU stays at 0% until the system itself reports a change.
- **Lazy monitoring.** The fine-grained Darwin thermal-pressure feed is only
  registered once the coarse thermal state leaves `nominal`, and torn down again
  on recovery. Nothing extra runs while the Mac is cool.
- **No background sampling.** `ps`/`top` are only ever invoked on demand — when
  you open the menu or when a notification is being composed — and that work runs
  off the main thread so the menu never blocks.
- **No root, no helper daemon.** A single user LaunchAgent, no privileged helper,
  no kernel extension.
- **Full thermal granularity.** Reading the Darwin pressure level directly
  distinguishes `moderate`, `heavy`, `trapping`, and `sleeping` — actual
  throttling is `heavy` and above, which the coarse `ProcessInfo.thermalState`
  ("fair") cannot tell apart on its own.

The result is a watcher you can leave running permanently with no measurable
battery or CPU impact, that still warns you the moment real throttling or memory
pressure starts.

## What it does

- Watches `ProcessInfo.thermalStateDidChangeNotification`.
- Starts Darwin `com.apple.system.thermalpressurelevel` monitoring when thermal
  state is non-nominal.
- Sends thermal alerts for Darwin `heavy`, `trapping`, or `sleeping`, with
  thermal-state fallback at `serious` or `critical`.
- Watches `DispatchSource` memory pressure events.
- Sends memory alerts at `medium` or `high`.
- Shows one menu bar icon while thermal throttling or memory pressure is active.
- Shows thermal state, memory pressure with free percentage, and line-broken
  top CPU and Activity Monitor-like top memory users.
- Displays thermal state as `nominal` when normal, Darwin pressure wording
  (`moderate`, `heavy`, `trapping`, `sleeping`) when Darwin pressure is
  available, and `thermalState` wording when Darwin pressure is unavailable.

No root access is required. There is no idle polling loop.

## Notifications & snooze

The menu bar icon's **Notifications ▸** submenu controls popups (the icon itself
always appears on an active issue, regardless of these settings):

- **All alerts** — notify on every transition (the default).
- **Important only** — notify only on real problems: CPU throttling, serious or
  critical thermal alerts, and high memory pressure. Heads-ups, recoveries, and
  level changes stay silent.
- **Off** — no popups at all.

The chosen mode is remembered across launches.

You can also **Snooze** all popups for 30 minutes, 1 hour, or 3 hours — a total
mute, including important alerts. While snoozed, the menu shows `🔕 Snoozed
until …` and a **Resume notifications** item. Snooze clears on its own when the
timer ends (and on app relaunch); picking a new duration resets the timer.

## Install

```zsh
cd ~/bin/nano-mac-throttle
./install.sh
```

macOS may ask for notification permission for Script Editor because
`nano-mac-throttle` uses `osascript` for simple notifications. If macOS activates
`nano-mac-throttle` from a notification click, the app opens the icon menu.


## Commands

```zsh
./nano-mac-throttle --status          # print thermal and memory status
./nano-mac-throttle --cpu             # print top CPU users
./nano-mac-throttle --memory          # print top memory users
./nano-mac-throttle --test            # send a test notification
./nano-mac-throttle --test-top-CPU    # send sample top CPU notification formatting
./nano-mac-throttle --test-top-memory # send sample top memory notification formatting
./nano-mac-throttle --show-icon-test  # show the menu bar icon for 15 seconds
./nano-mac-throttle --self-test       # run parser self-tests
```

## Check status

```zsh
launchctl print gui/$(id -u)/io.github.nano-mac-throttle
```

## Uninstall

```zsh
./uninstall.sh
```

## Notes

- The menu bar icon is intentionally absent during normal state.
- The icon uses thermal, memory, or warning symbols depending on active issues.
- Top memory users come from `top` with a small `ps` lookup for readable app
  names, so Docker VM and WindowServer match Activity Monitor more closely than
  raw RSS.

## Want a richer thermal app?

This tool is deliberately minimal. If you want live temperature and fan-speed
readouts, a thermal-pressure history chart,
and a polished SwiftUI menu bar app, take a look at
[MacThrottle](https://github.com/angristan/MacThrottle) — it reads the same
Darwin thermal-pressure level and adds the charting and configuration on top.
