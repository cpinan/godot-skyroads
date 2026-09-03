# STATUS — SkyRoads Godot port

_Last updated: 2026-09-02 · branch **`editor-and-perf`** (3 ahead of `main`, NOT pushed), 0 uncommitted · **the repo is PUBLIC** at `cpinan/godot-skyroads` · `tools/`, `docs/`, `analysis/`, `skyroads-port/` sit outside this repo_

## Next action

Merge `editor-and-perf` into `main` and push — the gate is green on it
(574 checks, 89 ok, 0 failures) and `main` is still at `1393c5a`.

## State

- **Shipped: `v1.0.0` is public**, with Windows, macOS and Android builds.
  Nothing since then has been released.
- **`tools/verify.sh` is green: 574 checks, 89 ok, 0 failures**, 23 of 30 roads
  replayed end to end, dashboard and all seven menu screens at 0 differing
  pixels. Road parity 0.5% – 2.0% (RGB tol 16, DOS rows 34..128).
- **A road editor exists** — `--editor NAME`, `scripts/RoadEditor.gd`. It is
  reachable by that flag and nothing else, because `render_menu.gd` compares
  the seven menu screens at 0 differing pixels. `examples/vaults.json` is a
  road built with it and `examples/vaults_route.bin` a solved route the port
  replays to completion in 484 ticks.
- **The port costs ~0.7 ms of CPU per frame** (uncapped, road 21, M1 Max) and
  17 draw calls. `docs/PERF.md` has the numbers and the method.
- **Mobile is validated on real hardware** (Pixel 10 Pro XL, 2026-09-01).
  iOS has never been built or run — no device, no team id.
- **Not built**: PLAN items 2 (mobile full-screen) and 3 (first-person). The
  editor has no undo, no copy/paste and no palette editor.

## In flight

Nothing in flight. Two things are finished in code but unproven by a person:

- `scripts/app/InputDevices.gd:57` — the gamepad pass (noise floor, d-pad over
  stick, six buttons and both triggers jumping). **No controller has ever been
  plugged in.**
- `scripts/TouchControls.gd:65` — `fixed_origin`, reached by `--fixed-stick`.
  Which of the two stick modes should be the DEFAULT is the open question, and
  it needs a thumb on the Pixel, not another test.

## Verify

```bash
QUICK=1 tools/verify.sh              # 605 checks in ~80 s — use this while editing
tools/verify.sh                      # + the 23 end-to-end replays, ~20 min
THREEWAY=1 tools/verify.sh           # + C vs Python vs GDScript on real levels
```

**`QUICK=1` runs every assertion the full gate does** and skips only the road
replays. Measured on one full run: `parse 8s  rendering 62s  suites 8s
end-to-end 687s` — the replays are 90% of it, and QUICK finishes in 78 s. It
prints `QUICK OK`, never `VERIFY OK`, so a grep cannot mistake one for the
other. Run the full gate before committing.

The full run is twenty minutes — background it. **Do not edit a source file
while it runs**, and never edit `verify.sh` itself mid-run: bash reads a script
as it executes. A windowed capture steals keyboard focus.

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

- **Nobody has authored a real level in the editor by hand.** `examples/vaults.json`
  was built through its brushes by a script; the missing undo and copy/paste
  will only be felt by someone typing.
- **`analysis/` is not a git repo, and now carries two changes made on
  2026-09-02** — `sra solve --road-json` (what the editor's solve button
  calls) and the fix that stops `export-godot` overwriting
  `data/SkyRoadsCamera.gd`. Both exist on disk only. The second one matters
  most: if an older copy of the toolkit reappears, an export silently reverts
  the camera to the refuted fit, and the only thing that would catch it is
  `tests/test_geometry.gd`. Putting `analysis/` under git is the real fix.
- **The Windows build in `v1.0.0` has never been run** — no Windows machine.
- **Seven roads have no route**: 12, 18, 20, 27, 28, 29, 30. Diagnosed in
  §12.26 as a FUEL problem, not beam width. Its own project.
- **§1.1 is NOT REPRODUCIBLE** as of 2026-09-01. Five recordings (2,486 ticks)
  kept as `tests/fixtures/traces/`. Cannot reproduce is not cannot happen.
- **iOS is unbuilt**; release binaries are unsigned and the APK carries the
  public Android debug key.

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
- **The letterbox is geometry** (§12.25), decided 2026-09-01 to keep.
- **Do not redo STAGE X draw order.** The ship never depth-tests. Tripwire:
  `tests/test_occlusion.gd`.
- **Do not put the editor on a menu.** Seven screens are compared at 0
  differing pixels; an eighth item fails `render_menu.gd`.
- **Fuel and oxygen are WARNINGS in the editor, never errors.** The arithmetic
  says roads 14 and 28 are longer than their tank with no supply tile, and road
  14 completes in the gate on every run. `tests/test_editor.gd` runs every rule
  against all 31 shipped roads and fails if one is called broken — that test
  forced the demotion and will force it again.
- **New scripts avoid `class_name`.** Resolving one needs the global class
  cache, which only an editor scan or `--import` writes, and an editor scan is
  what un-pins the 374 texture `.import` files from `detect_3d/compress_to=0`.
- **Do not re-derive the tun_high from the vault**; `0x2fb0` never loads `[di+8]`.
- **Do not paint the letterbox with a CanvasLayer** — impossible with `aspect=keep`.
- **Do not remove the CONTROLS menu item on mobile** — only route to the sound setting.
- **The DOS framebuffer is opaque.** Palette index 0 is BLACK.
- **A test that reaches a commit path must not write `user://skyroads.cfg`.**
- **Never write a `pgrep -f` wait loop whose pattern appears in its own command
  line** — it matches itself and waits for ever. Cost several turns on
  2026-09-02. Background the gate and let the harness notify instead.
- **`adb shell input tap` does not reach Godot** — use `input touchscreen tap`.
- **Never full-screen `screencapture`** to look at the game.

## Retail data

Erased by every reboot. Re-download over **HTTP**:
`curl -o skyroads.zip http://www.bluemoon.ee/history/skyroads/skyroads.zip`
`SKYROADS.EXE` sha256 `c3a55223e359749555535e138ef4219bc94458639e44f70edf3cfcb2f28c26ac`.

Godot export templates are installed for all platforms (4.7.1.stable).
