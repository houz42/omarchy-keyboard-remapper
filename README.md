# omarchy-keyboard-remapper

An [Omarchy](https://omarchy.org/) shell plugin that manages one `keyd`
rule: a standalone tap of the physical Alt key emits `F13`, while holding
Alt still passes through as a normal modifier for every existing
Hyprland/app Alt-chord.

## Why

Terminal multiplexers and multiplexer-like tools — tmux, screen,
[herdr](https://herdr.dev), and others — all work the same way: you press a
*prefix* key, release it, then press a command key (`prefix` then `c` for a
new window/tab, `prefix` then `?` for help, and so on). That prefix has to
be a single, dedicated key so the tool can tell "you're issuing a command"
apart from "you're typing normally" — which is why these tools default to
an *unused* chord like `ctrl+b` or `ctrl+space` rather than a bare modifier:
software generally can't distinguish "Ctrl held alone, then released" from
"Ctrl held as part of some other shortcut" using keyboard events alone.

A single physical key dedicated to nothing else solves this more naturally
than a chord — but most keyboards don't have a spare one, and a key you
already rely on for other shortcuts (like Alt, used constantly for window
switching and app shortcuts) can't be reassigned to a tool's prefix without
losing it everywhere else.

`keyd`'s `overload(layer, key)` primitive solves exactly this: it makes one
physical key do both jobs, based on *how* it's pressed. A tap (press and
release with nothing else in between) emits a different, otherwise-idle
key — an unused function key like `F13` — while holding it down and
pressing something else still acts as the original modifier. This plugin
wires `leftalt = overload(alt, f13)`, so:

- Tap Alt alone → `F13`, which you point a multiplexer's prefix binding at
  (e.g. herdr's `prefix = "f13"` in `~/.config/herdr/config.toml`).
- Hold Alt + anything else → completely unchanged Alt-chord behavior.

This happens at the `keyd`/evdev level, below Hyprland's XKB layer, so it
works regardless of any XKB-level remaps (e.g. a Win↔Alt swap) already in
place.

![Keyboard Remapper panel](screenshots/panel.png)

## Install

```sh
omarchy plugin add https://github.com/houz42/omarchy-keyboard-remapper.git --enable
```

## Manual use

Toggle the rule and see live status from the bar icon's popup — there's no
separate CLI. The two bundled scripts are used internally by the plugin:

```sh
bin/check-keyd-status <true|false>       # read-only status/drift JSON, non-privileged
bin/apply-keyd-config <pending-conf-path> # privileged (via pkexec): installs keyd if missing,
                                           # writes /etc/keyd/houz42-keyboard-remapper.conf, enables the service
```

## How it works

The popup writes the desired `keyd` config to a file under
`~/.local/state/omarchy/houz42.keyboard-remapper/`, then runs
`bin/apply-keyd-config` through a single fixed-argv `pkexec` call — never a
`pkexec bash -c "..."`/`pkexec python3 -c "..."` string, and never
triggered automatically, only from an explicit button press. That script
installs `keyd` via `pacman` if it's missing, atomically writes
`/etc/keyd/houz42-keyboard-remapper.conf`, and enables/reloads the `keyd`
service. A separate read-only script polls status and reports drift if the
live config doesn't match what the current toggle state should produce.

## Known limitations

- Manages exactly one rule (Alt tap → F13). The renderer is generic enough
  to extend, but no UI exists yet for adding arbitrary rules.
- `keyd` merges every `*.conf` file under `/etc/keyd/`. If you run another
  keyd-based remap tool alongside this plugin, make sure neither binds the
  same source key (`leftalt` here) — conflicting lines across files produce
  ambiguous, load-order-dependent behavior.
- Uses Omarchy's internal shell components (`qs.Ui` / `qs.Commons`), which
  aren't a documented stable plugin API and could change without notice.

## Uninstall

Disabling or removing the plugin (`omarchy plugin disable houz42.keyboard-remapper`
/ `omarchy plugin remove houz42.keyboard-remapper`) does **not** touch
anything outside the plugin directory — it leaves `keyd` installed, its
service enabled, and `/etc/keyd/houz42-keyboard-remapper.conf` in place, so
the Alt→F13 remap keeps working even after the plugin itself is gone. To
fully remove it:

```sh
sudo rm /etc/keyd/houz42-keyboard-remapper.conf
sudo systemctl reload keyd || sudo systemctl restart keyd
# optionally, if nothing else on your system uses keyd:
sudo systemctl disable --now keyd
sudo pacman -R keyd
```

## License

MIT
