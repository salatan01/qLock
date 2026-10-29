# qLock — video lockscreen for Quickshell

Production `ext-session-lock` screen: shuffled video wallpaper, seamless
looping, frosted-glass PAM HUD, suspend-aware playback, anchored loudness
lock, and a now-playing title pill.

- **Video wallpaper** — random (long-memory shuffle, no repeats until every
  video has played once, per-folder history in `$XDG_STATE_HOME/qlock/history.json`)
  or one fixed file, seamless in-player looping with no black flash between
  plays or repeats. Reset with `qlock clear-cache`.
- **Mouse-free by design** — no cursor, nothing clickable; keyboard only.
- **Frosted-glass auth card** — clock, user pill, password box, Caps Lock
  hint, throttle + lockout, shake/success animations.
- **Loudness-locked audio** — background volume sounds exactly as configured,
  immune to volume buttons; pre-lock mixer state restored on unlock,
  crash-safe.
- **Suspend-aware** — playback pauses across sleep/resume via logind hook,
  with a wall-clock watchdog and playback-progress recovery for missed
  edges and frozen decoders.
- **Now-playing pill** — bottom-center title of the current video, toggleable.

## Requirements

- A compositor with `ext-session-lock` (Niri, Hyprland, Sway).
- Auth uses the stock `login` PAM stack — no extra PAM config needed.
- `wpctl` (WirePlumber) for the loudness lock; without it volume gracefully
  degrades to plain mixer-relative playback with a warning.

## Install on NixOS (flake)

Prerequisites: flakes enabled (see Requirements above), plus a folder of
videos.

**1. Add the input** to your system flake:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    qlock.url = "github:salatan01/qlock";
  };
}
```

**2. Wire the overlay** (required). The module defaults to `pkgs.qlock`,
which only exists once the overlay is applied — without this the build
fails with "package qlock not found":

```nix
outputs = { nixpkgs, qlock, ... }: {
  nixosConfigurations.host = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      qlock.nixosModules.default
      ({ pkgs, ... }: {
        nixpkgs.overlays = [ qlock.overlays.default ];
        # ... your config ...
      })
    ];
  };
};
```

Alternative without overlay: keep the module import and point at the
package explicitly —
`services.qlock.package = qlock.packages.x86_64-linux.qlock;`
(requires passing `qlock` into scope via `specialArgs` or a `let`-binding).

**3. Enable + configure:**

```nix
({ ... }: {
  services.qlock.enable = true;
  services.qlock.settings = {
    videoDirectory = "~/Videos/lockscreen";
    mode = "random";   # or "fixed" (+ fixedFile)
    playback = 0;      # 0 = loop forever, 2 = 2playback, …
    volume = 20;       # 0-100, absolute % of full scale
    pinSink = true;
    showTitle = true;
  };
})
```

Every key is optional (see Settings reference). This writes
`/etc/qlock/config.json` (mode `0444`); set
`services.qlock.writeConfig = false` if you manage that file out-of-band.

**4. Rebuild and verify:**

```bash
sudo nixos-rebuild switch --flake .#host
cat /etc/qlock/config.json        # your settings, byte-stable JSON
which qlock qlock-preview         # both on PATH
qlock-preview                     # safe window test, never locks
```

**5. Bind a lock key** (compositor-specific):

```kdl
// Niri (config.kdl)
Mod+L { spawn "qlock"; }
```

```ini
# Hyprland (hyprland.conf)
bind = SUPER, L, exec, qlock
```

```
# Sway (config)
bindsym $mod+l exec qlock
```

**6. First lock — be careful.** Test from a second TTY (or SSH) first:
switch TTY, log in, run `qlock`, switch back, type password + Enter.

Updating: `nix flake update qlock && sudo nixos-rebuild switch`.
Uninstall: remove the module + overlay, rebuild; `/etc/qlock/config.json`
disappears once `services.qlock` is gone (it only exists while enabled).

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
Like the system module, the default package is `pkgs.qlock` — apply
`qlock.overlays.default` to your `pkgs` (or set `programs.qlock.package`
explicitly), otherwise the build fails with "package qlock not found".

## Controls (keyboard only)

The lock shows no cursor and nothing is clickable — the video stays clean.

| Key | Action |
|---|---|
| Enter | Open the password box (works even while a cooldown is showing) |
| type + Enter | Submit password |
| Esc | Clear typed text; press again on an empty box to close it |
| Caps Lock | A `Caps Lock?` hint appears automatically (best-effort heuristic) |

The box auto-hides after 10s idle when empty. Wrong passwords trigger a 2s
cooldown; 5 consecutive failures trigger a 30s lockout with countdown —
during these the box visibly refuses input (`Wait…` / `Locked — try again
in Ns`) instead of silently swallowing keys.

## Settings reference

Full default config (every key below is optional — partial JSON is merged
over these built-ins):

```json
{
  "videoDirectory": "~/qSets/qLock/",
  "mode": "random",
  "fixedFile": "",
  "repeat": true,
  "playback": 0,
  "volume": 20,
  "pinSink": true,
  "showTitle": true
}
```

### `videoDirectory` (string, default `"~/qSets/qLock/"`)

Folder scanned for `*.mp4` / `*.mkv` / `*.webm`. Leading `~`, `$HOME/` and
`${HOME}/` prefixes are expanded automatically. If the folder is missing or
holds no playable files, the lock shows a "No videos found" card (with the
resolved path) instead of a bare black screen — and a "Loading videos…"
pill while the first scan is still in flight.

### `mode` (string, default `"random"`)

- `"random"` — long-memory shuffled playlist: every video plays once in
  random order before anything repeats, remembered across locks/restarts
  per-folder (even 10 days later a played video stays excluded). When all
  have played, a fresh cycle auto-starts (boundary repeat avoided when
  possible). This is the mode `playback` counts against. Reset with
  `qlock clear-cache`. Preview (`qlock-preview`) never touches history.
- `"fixed"` — one single video, looped forever (see `fixedFile`).

### `fixedFile` (string, default `""`)

Only read when `mode` is `"fixed"`: the exact file **name** (not a path),
e.g. `"cantarella.mp4"`. Empty falls back to the first video found.
Completely ignored in `"random"` mode.

### `repeat` (bool, default `true`)

Master loop switch. `true` = loop seamlessly in-player (the backend replays
the decoded stream internally — no stop/reload, no black flash).
`false` = play each video exactly once, then advance (`playback` is ignored).

### `playback` (number 0–100, default `0`)

Repeats **per video** before the playlist advances. Only read when `repeat`
is `true` and `mode` is `"random"`:

| Value | Behaviour |
|---|---|
| `0` | Loop the current video forever (legacy `repeat: true` default) |
| `1` | Play once, then advance (same as `repeat: false`) |
| `2` | "2playback" — same video twice, then a new random video twice, … |
| `3` | "3playback" — same cycle with three plays |

Repeats are seamless (see `repeat`); only the advance reloads. Aliases
`playbackCount`, `repeatCount`, `playCount` are accepted from hand-written
JSON. Out-of-range values clamp to 0–100; invalid values (text, negatives)
fall back to infinite loop with a warning.

### `volume` (number 0–100, default `20`)

Background audio loudness as an **absolute** fraction of full scale:
`20` = 20% linear output, in both the real lock and the preview. Values `≤ 1`
keep the legacy 0–1 fraction meaning so old configs don't go silent. Qt applies
the stream gain before the PipeWire sink's cubic curve, so qLock divides the
sink gain (`sink³`) back out; this is why `5` is quiet-but-audible rather than
muted, and why the lock sounds exactly like the preview at the same setting.
If the sink is very low, Qt's per-stream `1.0` cap can make the result quieter
than requested (the lock and preview still match; raise the sink for more).
This is **loudness-locked against later mixer changes** (see `pinSink`): volume
buttons cannot change what you hear while locked. Set `QLOCK_DEBUG=1` for
per-change volume logging.

### `pinSink` (bool, default `true`)

While locked, the default sink is **anchored at its lock-time level** — your
pre-lock volume/mute is saved, held for the session, and restored on unlock,
so volume buttons get snapped back within ~0.5s. The anchor is **mixer-only**:
it does not scale the configured `volume` (that would make a 50% sink lock
~18 dB quieter than the preview, which is the old muted-at-5 bug). The sink
can only ever be returned to the anchor, never raised above it, so blasting is
structurally impossible; a lock taken while muted stays silent.

Crash safety: the pre-pin state is mirrored to
`$XDG_RUNTIME_DIR/qlock-volpin`, and the `qlock` supervisor binary restores
it via trap even if quickshell dies (only SIGKILL to the supervisor itself
is unrecoverable — true in any language; stale leftovers are deleted, never
restored over your live mixer). Stream gain additionally compensates the
PipeWire cubic curve (`gain = slider³`) in both lock and preview.
Set `false` for plain sink-relative playback. The preview never pins.

### `showTitle` (bool, default `true`)

Bottom-center now-playing pill with the current video's file name,
humanized (`cantarella_rover.mp4` → "cantarella rover": extension stripped,
underscores decoded to spaces, long names middle-elided). Persists across
repeats, pulses softly on track change. Set `false` for a fully clean screen.

## Config resolution order

First hit wins; each layer is merged over the built-ins, so partial files work:

1. `$QLOCK_CONFIG` (file path or `file://` URL — also handy for testing)
2. `$XDG_CONFIG_HOME/qlock/config.json` (else `~/.config/qlock/config.json`)
3. `/etc/qlock/config.json` (NixOS `services.qlock.settings`)
4. Bundled `config/config.json` (needs `QML_XHR_ALLOW_FILE_READ=1` — set by the wrapper)

After install, layer 4 lives at
`/nix/store/<hash>-qlock-<version>/share/qlock/config/config.json`
(immutable fallback — inspect with
`cat $(readlink result)/share/qlock/config/config.json`). Layer 3 only
exists once `services.qlock.enable = true` is in your system config; layer 2
only once you create it.

## Security notes

- One shared auth context for all monitors: multi-screen setups run a single
  PAM session and a single fail counter, never competing logins.
- One lock supervisor per user: an advisory `flock` guard in the `qlock`
  wrapper refuses a second instance (concurrent lock surfaces would both keep
  fighting over the session lock and the mixer).
- Correct PAM sequencing (respond only on prompt), 12s hang safety net,
  2s cooldown / 30s lockout throttling, no Caps Lock surprises.
- Unlock commits to the compositor before the process exits; mixer restore
  lands first, covered by the success fade.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "No videos found" card | `videoDirectory` wrong or empty — the card shows the resolved path; check it |
| Box ignores typing + shows `Wait…` / countdown | Throttle cooldown/lockout — by design, wait it out |
| Box ignores typing, no message | Window lost keyboard focus — click the preview window (or wait ≤2s: the focus guard re-grabs when nothing is focused) |
| Preview shows nothing after `nix run` | It opens a GUI window — check your workspaces; terminal staying silent is normal |
| `ignoring invalid playback` warning | A non-numeric/negative `playback` value — fix the JSON (0–100) |
| `wpctl unavailable` warning | WirePlumber missing — volume stays mixer-relative; install wireplumber for the loudness lock |
| `VDPAU` / `VK_KHR_video_decode_queue` lines | Hardware-decode fallback to software — harmless, video still plays |
| `dbus-monitor exited` warning | Suspend hook restarting in 3s — harmless unless suspend-pause stops working |
| Same video never replays / want repeats again | Long-memory shuffle is doing its job — run `qlock clear-cache` to reset history |
| `history corrupt, starting fresh` warning | History JSON was hand-edited or truncated — deleted entry ignored, fresh cycle started |
| `qlock: already running` on launch | Another qLock supervisor holds the single-instance lock — exit normally; wait for the existing lock to unlock |

## Environment knobs

| Variable | Effect |
|---|---|
| `QLOCK_CONFIG` | Override config file (path or `file://` URL) |
| `QLOCK_DEBUG=1` | Verbose volume/loop logging |
| `QLOCK_PREVIEW_MOUSE=0` | Preview the mouse-free lock build (keyboard only; quit via real password+Enter) |

## Dev

```bash
nix develop
nix run .#preview
QLOCK_PREVIEW_MOUSE=0 nix run .#preview  # mouse-free rehearsal
nix flake check
nix build .#qlock

# Tests
QT_QPA_PLATFORM=offscreen qmltestrunner -input tests/tst_video.qml
timeout 15 quickshell --path tests/harness.qml   # expect "qLock tests: ALL PASS"
```

`tests/harness.qml` runs under Quickshell (not `qmltestrunner`) because
`AuthContext`/`SuspendWatcher`/`AuthOverlay` import statically linked
Quickshell plugins. It covers the PAM state machine, the overlay's error
visibility, and the suspend/resume watchdog.

Layout: `shell.qml` (production lock) · `test.qml` (safe preview) ·
`components/` (`AuthOverlay`, `AuthContext`, `PlaylistEngine`,
`VideoBackground`, `VideoTitle`, `SuspendWatcher`, `SystemVolumeWatcher`,
`ConfigLoader`) · `config/config.json` · `nix/` (package, NixOS + Home
Manager modules).
