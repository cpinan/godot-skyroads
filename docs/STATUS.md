# STATUS — SkyRoads Godot port

_Last updated: 2026-09-01 · branch `main`, pushed, 0 uncommitted · **the repo is PUBLIC** at `cpinan/godot-skyroads` · `tools/`, `docs/`, `analysis/`, `skyroads-port/` sit outside this repo_

## Next action

Pick an item from `docs/PLAN.md` — nothing is broken and nothing is half-done.
Item 1 (joystick/gamepad polish) is the only one that risks no measured result.

## State

- **Shipped: `v1.0.0` is public**, with Windows, macOS and Android builds
  attached. https://github.com/cpinan/godot-skyroads/releases/tag/v1.0.0
- **`THREEWAY=1 tools/verify.sh` is green: 475 checks, 0 failures**, 23 of 30
  roads replayed end to end, 60,964 ticks agreeing across C, Python and
  GDScript, dashboard and all seven menu screens at 0 differing pixels.
- **Road parity is 0.5% – 2.0%** (RGB tol 16, DOS rows 34..128) on roads 2, 5,
  21 and 26. Worst frame in the game is inside a tunnel at 6.4%.
- **The whole simulation is anchored to the retail binary.** As of §12.23 the
  attract demo and the road-end fade are too, so nothing is left citing the C
  reference alone.
- **Mobile is validated on real hardware** (Pixel 10 Pro XL, 2026-09-01):
  intro, menus, a road, the pause menu, the stick. iOS has never been built or
  run — no device, no team id.
- **`docs/PLAN.md` holds the four post-parity features**, none started.

## In flight

Nothing in flight.

## Verify

```bash
tools/verify.sh                      # the gate
THREEWAY=1 tools/verify.sh           # + C vs Python vs GDScript on real levels
```

Twenty minutes — background it. **Do not edit a source file while it runs**:
each phase loads scripts fresh, and an edit mid-run wedged one run for 26
minutes looking exactly like a hang. A windowed capture steals keyboard focus.

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
tools/sid_compare.py   <out>/c_t0199.sid <out>/road21_t0200.sid.png --rows 34,128
tools/make_compare.py  <out>/c_t0199.ppm <out>/road21_t0200.png shot.png
```

## Open questions

- **The Windows build in `v1.0.0` has never been run** — no Windows machine.
  Exported and unverified, and the release notes say so.
- **Seven roads have no route**: 12, 18, 20, 27, 28, 29, 30. Diagnosed in
  §12.26 as a FUEL problem, not beam width. Needs a solver whose objective is
  not progress; treat it as its own project.
- **§1.1 is NOT REPRODUCIBLE** as of 2026-09-01 — the reporter played the
  current build and could not make it happen. Five recordings (2,486 ticks) are
  kept as `tests/fixtures/traces/`. Not closed: cannot reproduce is not cannot
  happen.
- **iOS is unbuilt.** Preset exists, no device, no team id.
- **Release binaries are unsigned** (no Windows cert, no Apple team id) and the
  APK carries the public Android debug key. Fine for sideloading, stated in the
  notes; a real signing story is a decision, not a task.

## Do not redo

- **"Matches `skyroads-port/`" is not evidence.** Fifteen defects were in both.
  Disassemble: code image at `hdrpar * 16` (u16 at EXE offset 8), addresses
  code-segment relative, data segment paragraph `0x66E`, `CS_MODE_16`. A
  working disassembler recipe is in §12.23.
- **Apply `godot/docs/reference-corrections/` before trusting any parity number.**
- **Pair the frames by §12.17.** C's `c_tN` is the port's `t(N+1)`.
- **Measure parity in RGB (tol 16) for "did this pixel change"; use the surface
  map, never colour, for "WHICH surface is this".** Road 21 has `[61]==[68]`
  and `[62]==[66]`, gap 0. Pass `--rows 34,128` — the map's `none` band is a
  blind spot, not a defect.
- **Do not touch the camera.** Five attempts measured worse or explained
  nothing. What worked (§12.19, §12.21) changed NO camera constant: both are
  vertex terms read off the baked tables.
- **The DOS projection is FOUR measured rules, not one camera**: vertical
  pinhole B=2.550, horizontal cone through y=32, the raised-surface height
  ladder (§12.18), and the arch band fan (§12.21).
- **The one-row offset is not a defect** (§12.22). Mean signed boundary error
  is −0.09 to −0.35 rows with no depth trend. Do not fit a constant to it.
- **The letterbox is geometry** (§12.25), decided 2026-09-01 to keep. 4:3
  cannot fill 2.23:1 at any scale.
- **The second rim record is deliberately not emitted** (§12.24) — same palette
  entry, and dropping the port's rim quad measures worse.
- **On mobile a tap that hits no item does NOTHING** (`Menu._keys_for_tap`).
  It used to mean "go back", which made the road select unusable with a thumb.
  The X is the way out, on all three screens.
- **Do not make `--sub-column` or `--altitude` the solver's default** — both are
  retries. Re-run at the DEFAULT beam before calling a road unsolvable: roads
  10, 13 and 16 failed at `--beam 1024` and fell to `--beam 48`.
- **Do not re-derive the tun_high from the vault**; `0x2fb0` never loads `[di+8]`.
- **Do not paint the letterbox with a CanvasLayer** — impossible with `aspect=keep`.
- **Do not remove the CONTROLS menu item on mobile** — only route to the sound setting.
- **Do not redo STAGE X draw order.** The ship never depth-tests. Tripwire:
  `tests/test_occlusion.gd`.
- **Do not re-derive the tunnel arch from `TUN_INNER`/`TUN_OUTER`** — those are
  the COLLISION profile.
- **Every texture `.import` under `data/` is pinned to `detect_3d/compress_to=0`**
  (374). `--import` is safe; an editor scan is the hazard.
- **The DOS framebuffer is opaque.** Palette index 0 is BLACK.
- **A test that reaches a commit path must not write `user://skyroads.cfg`.**
- **Never time a shell fade in frames** (~1400 fps), and never write a `pgrep -f`
  wait loop whose pattern appears in its own command line.
- **`adb shell input tap` does not reach Godot** — use `input touchscreen tap`.
- **Never full-screen `screencapture`** to look at the game; it catches whatever
  else is on the desktop. Use `adb exec-out screencap` or a window-targeted grab.

## Retail data

Erased by every reboot. Re-download over **HTTP**:
`curl -o skyroads.zip http://www.bluemoon.ee/history/skyroads/skyroads.zip`
`SKYROADS.EXE` sha256 `c3a55223e359749555535e138ef4219bc94458639e44f70edf3cfcb2f28c26ac`.
It is the project's measuring instrument, not just provenance.

Godot export templates are installed for all platforms (4.7.1.stable). If a
reinstall wipes them, `gh release download 4.7.1-stable --repo godotengine/godot
--pattern "*export_templates.tpz"` works where plain `curl` does not.
