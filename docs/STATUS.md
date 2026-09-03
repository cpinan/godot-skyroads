# STATUS — SkyRoads Godot port

_Last updated: 2026-09-02 · branch **`main`**, pushed and level with `origin` · 0 uncommitted · **the repo is PUBLIC** at `cpinan/godot-skyroads` · `tools/`, `docs/`, `analysis/`, `skyroads-port/` sit outside this repo_

## Next action

Nothing is pending in the repo: ten commits merged to `main` and pushed, the
full gate green (613 checks, 92 ok, 0 failures, 23 roads replayed). Pick from
**Open questions** — the largest is the seven unrouted roads, and that wants
`analysis/` under git first, because the work would live there.

The three things in **In flight** are finished in code and need hardware, not
a session: a controller, a thumb on the Pixel, and somebody authoring a road
by hand.

`editor-and-perf` is merged and can be deleted (`git branch -d editor-and-perf`).

## State

- **Shipped: `v1.0.0` is public.** Everything since — the editor, the perf
  pass, the shell split, the gate split — is on `main` but in **no release**.
- **The gate is green: 613 checks, 92 ok, 0 failures.** `QUICK=1` makes every
  one of those assertions in 78 s; the 23 end-to-end replays it skips are 90%
  of the runtime and prove the whole stack still finishes a road.
- **A road editor exists** — `--editor NAME`, off-menu by design. Grid, two
  brushes, fill with a mark, row insert/delete, 60-step undo, live validation,
  and a solver button that reports the row a failed search died at.
  `examples/vaults.json` is a road built with it; its route replays to
  completion in 484 ticks.
- **The port costs ~0.7 ms of CPU per frame** (uncapped, road 21, M1 Max), 17
  draw calls, and a road restart now costs the driver zero new shader
  compiles. `docs/PERF.md` has the numbers and the method.
- **Mobile runs on real hardware** (Pixel 10 Pro XL, 2026-09-01) but nothing
  since has been measured there. iOS has never been built.
- **Not built**: PLAN items 2 (mobile full-screen) and 3 (first-person).

## In flight

Nothing half-written. Three things are finished in code and unproven by a
person:

- `scripts/app/InputDevices.gd:57` — the gamepad pass. **No controller has ever
  been plugged in;** the thresholds were reasoned from a resting stick's noise.
- `scripts/TouchControls.gd:65` — `fixed_origin`, reached by `--fixed-stick`.
  Which stick mode should be the DEFAULT needs a thumb on the Pixel.
- `scripts/RoadEditor.gd` — nobody has authored a road by hand with it.
  `examples/vaults.json` was built through its brushes by a script.

## Verify

```bash
QUICK=1 tools/verify.sh              # 613 checks in 78 s — use this while editing
tools/verify.sh                      # + the 23 end-to-end replays, ~13 min
THREEWAY=1 tools/verify.sh           # + C vs Python vs GDScript on real levels
```

`QUICK=1` makes every assertion the full gate does and prints `QUICK OK`, never
`VERIFY OK`, so a grep cannot mistake one for the other. Measured phases:
`parse 8s  rendering 62s  suites 8s  end-to-end 687s`.

**Do not edit a source file while the full gate runs**, and never `verify.sh`
itself — bash reads a script as it executes. A windowed capture steals keyboard
focus. Background it and let the harness notify; **never** write a `pgrep -f`
wait loop whose pattern appears in its own command line.

### Parity, end to end

```bash
clang -O2 -o /tmp/sr_replay_frames tools/replay_frames.c \
    skyroads-port/src/core/{assets,audio,cfg,game,gfx,hud,lzs,play,render,tables,text}.c \
    skyroads-port/src/thirdparty/opl3.c -lm
SR_SURFACE_IDS=1 /tmp/sr_replay_frames <retail> <out> 21 godot/data/routes/road_21.bin 1 202
$GODOT --path godot --resolution 640x480 -- --replay 21 \
    --route-file res://data/routes/road_21.bin --shots <out> --shot-ticks 200 --surface-ids
# NOTE THE TICK: the port's t=200 is the reference's c_t0199 (BUGS §12.17)
tools/frame_compare.py <out>/c_t0199.ppm <out>/road21_t0200.png --rows 34,128
```

## Open questions

- **`analysis/` is not a git repo and carries two changes made 2026-09-02** —
  `sra solve --road-json` (the editor's solve button) and the fix stopping
  `export-godot` overwriting `data/SkyRoadsCamera.gd`. Both exist on one disk,
  unbacked-up. `git init` was offered and declined that day; the offer stands.
- **Seven roads have no route**, and the editor's budget maths says they are
  four different problems, not one: **12, 18, 28, 29** have a negative fuel
  margin and must collect supplies; **27** is the only road in the game with a
  negative OXYGEN margin (-27.1 s at maximum speed); **20** is gravity 20, so
  `can_jump` is false and the ship cannot leave the deck at all; **30** has 74
  gap rows. 4 of the 7 have a negative fuel margin against 4 of the 23 routed —
  suggestive on n=7, not proof. Fixing them is a solver project in `analysis/`.
- **The Windows build in `v1.0.0` has never been run** — no Windows machine.
- **§1.1 is NOT REPRODUCIBLE** as of 2026-09-01, five recordings kept in
  `tests/fixtures/traces/`. Closed by decision: do not reopen without a report.
- **One file-naming convention.** `skyroads_constants.gd` sits next to
  `SkyRoadsCamera.gd`; `gd_audit` GDBP-101 flags every new file for it and six
  now carry a suppression comment. Rename the outliers or turn the rule off.
- **iOS is unbuilt**; releases are unsigned and the APK carries the public
  Android debug key.

## Do not redo

- **"Matches `skyroads-port/`" is not evidence.** Fifteen defects were in both.
  Disassemble: code image at `hdrpar * 16` (u16 at EXE offset 8), data segment
  paragraph `0x66E`, `CS_MODE_16`. Recipe in §12.23.
- **Apply `docs/reference-corrections/` before trusting any parity number.**
- **Pair the frames by §12.17.** C's `c_tN` is the port's `t(N+1)`.
- **Measure parity in RGB (tol 16) for "did this pixel change"; use the surface
  map, never colour, for "WHICH surface is this".**
- **Do not touch the camera.** Five attempts measured worse or explained
  nothing. The DOS projection is FOUR measured rules, not one camera.
- **`data/SkyRoadsCamera.gd` is hand-maintained.** The exporter used to
  overwrite it with the refuted fit (`focal 279.7` against the measured
  `282.7632`); fixed 2026-09-02 to write a `.generated` sidecar instead.
  `tests/test_geometry.gd` fails by name if that regresses, and it can:
  `analysis/` has no git history, so an older toolkit can reappear.
- **The letterbox is geometry** (§12.25), decided 2026-09-01 to keep.
- **Do not redo STAGE X draw order.** The ship never depth-tests. Tripwire:
  `tests/test_occlusion.gd`.
- **Do not put the editor on a menu.** Seven screens compare at 0 differing
  pixels; an eighth item fails `render_menu.gd`.
- **Fuel and oxygen are WARNINGS in the editor, never errors.** Roads 14 and 28
  are longer than their tank with no supply tile and road 14 completes in the
  gate every run. `tests/test_editor.gd` runs every rule against all 31 shipped
  roads and forced that demotion once already.
- **New scripts avoid `class_name`** — it needs the global class cache, which
  only an editor scan or `--import` writes, and an editor scan un-pins the 374
  texture `.import` files from `detect_3d/compress_to=0`.
- **Do not re-derive the tun_high from the vault**; `0x2fb0` never loads `[di+8]`.
- **Do not paint the letterbox with a CanvasLayer** — impossible with `aspect=keep`.
- **Do not remove the CONTROLS menu item on mobile** — only route to the sound setting.
- **The DOS framebuffer is opaque.** Palette index 0 is BLACK.
- **A test that reaches a commit path must not write `user://skyroads.cfg`.**
- **`adb shell input tap` does not reach Godot** — use `input touchscreen tap`.
- **Never full-screen `screencapture`** to look at the game.

## Retail data

Erased by every reboot. Re-download over **HTTP**:
`curl -o skyroads.zip http://www.bluemoon.ee/history/skyroads/skyroads.zip`
`SKYROADS.EXE` sha256 `c3a55223e359749555535e138ef4219bc94458639e44f70edf3cfcb2f28c26ac`.

Godot export templates are installed for all platforms (4.7.1.stable).
