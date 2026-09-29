# qLock — video lockscreen for Quickshell

Production `ext-session-lock` screen: shuffled video wallpaper, seamless
looping, frosted-glass PAM HUD, suspend-aware playback.

The lock is **mouse-free by design**: no cursor (invisible), nothing is
clickable — the video stays perfectly clean. Keyboard only:

- Enter → opens the password box (also while a cooldown shows)
- type password, Enter → submit • Esc → clear typed text, Esc again → close
- Caps Lock → hint appears. Box auto-hides after 10s idle when empty.

## Install (NixOS flake)

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    qlock.url = "github:salatan01/qlock";
  };
  outputs = { nixpkgs, qlock, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [
        qlock.nixosModules.default
        ({ ... }: {
          services.qlock.enable = true;
          services.qlock.settings = {
            videoDirectory = "~/Videos/lockscreen";
            mode = "random";   # or "fixed"
            volume = 20;       # 0-100 scale
          };
        })
      ];
    };
  };
}
```

Then bind a key (Niri example):

```kdl
Mod+L { spawn "qlock"; }
```

Auth uses the stock `login` PAM stack — no extra PAM config needed.
Requires a compositor with `ext-session-lock` (Niri, Hyprland, Sway).

## Try without installing

```bash
nix run github:salatan01/qlock#preview   # safe window, never locks
nix run github:salatan01/qlock#qlock     # REAL LOCK — test from a 2nd TTY first
```

## Home Manager (per-user config)

```nix
imports = [ qlock.homeManagerModules.default ];
programs.qlock = {
  enable = true;
  settings.videoDirectory = "~/Videos/lockscreen";
};
```

Writes `~/.config/qlock/config.json`, which wins over `/etc/qlock/config.json`.

## Config resolution order

1. `$QLOCK_CONFIG` (file path or `file://` URL)
2. `$XDG_CONFIG_HOME/qlock/config.json` (else `~/.config/qlock/config.json`)
3. `/etc/qlock/config.json` (NixOS `services.qlock.settings`)
4. Bundled `config/config.json` (needs `QML_XHR_ALLOW_FILE_READ=1` — set by the wrapper)

Partial JSON is merged over built-ins. `~` / `$HOME` / `${HOME}` prefixes
in `videoDirectory` are expanded; `volume` is 0-100 (`20` = 20%, legacy
`≤1` values keep 0-1 meaning).

After `nix build` / install, layer 4 lives at
`/nix/store/<hash>-qlock-<version>/share/qlock/config/config.json`
(immutable fallback — inspect with `cat $(readlink result)/share/qlock/config/config.json`).
Layer 3 (`/etc/qlock/config.json`) only exists once `services.qlock.enable = true`
is in your system config; layer 2 only once you create it.

`volume` is loudness-locked, not mixer-relative. While the lock is up,
the sink is **anchored at its lock-time level** (your pre-lock volume/mute
is saved and restored on unlock), so bg loudness is exactly what the
configured value always sounded like for you — volume buttons get snapped
back within ~0.5s. Deliberately NOT pinned to full scale: that would
redefine 20 as 20%-of-full-scale, ~13 dB hotter than a 35%-sink user's
norm. Stream gain additionally compensates the PipeWire cubic curve
(`gain = slider^3`) during transitions and in preview. Set `"pinSink":
false` for plain relative playback. Crash safety: the pre-pin state is
mirrored to `$XDG_RUNTIME_DIR/qlock-volpin` and the `qlock` supervisor
binary restores it via trap even if quickshell dies (only SIGKILL to the
supervisor itself is unrecoverable — true in any language).

```json
{
  "videoDirectory": "~/qSets/qLock/",
  "mode": "random",
  "fixedFile": "",
  "repeat": true,
  "playback": 0,
  "volume": 20,
  "pinSink": true
}
```

`playback` controls repeats per video in `random` mode before the playlist
advances — `2` is "2playback" (same video twice, then a new random video
twice, …), `3` is "3playback", `1` plays once then advances (same as
`repeat: false`), `0` loops the current video forever (the legacy
`repeat: true` default). Repeats are seamless: the backend loops the decoded
stream internally via `MediaPlayer.loops`, so there is no stop/reload black
flash between plays. `playback` is ignored when `repeat` is `false` (always
single plays) and in `fixed` mode (the single video loops forever —
advancing is meaningless). Hand-written JSON may also use `playbackCount`,
`repeatCount` or `playCount` as aliases; values are clamped to 0–100 and
invalid values fall back to infinite with a warning. Set `QLOCK_DEBUG=1` for
verbose volume/loop logging.

## Dev

```bash
nix develop
nix run .#preview
QLOCK_PREVIEW_MOUSE=0 nix run .#preview  # preview the mouse-free lock build
nix flake check
nix build .#qlock
```
