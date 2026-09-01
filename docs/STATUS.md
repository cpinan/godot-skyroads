# STATUS — SkyRoads Godot port

_Last updated: 2026-09-01 · git lives in `godot/` only, branch **`main`** (pushed) · `cpinan/godot-skyroads` (PRIVATE) · `tools/`, `docs/`, `analysis/`, `skyroads-port/` sit outside the repo_

## Next action

Fix the parity capture path in `scripts/Main.gd:491` `_capture_pending()` — the
PNG it saves is the frame drawn BEFORE its `override_alpha` + `_present()`, so
no parity number is of the frame it claims. Everything else here waits on it.

## State

- **`THREEWAY=1 tools/verify.sh` is green: 484 checks, 0 failures**, including
  60,964 ticks agreeing across C, Python and GDScript on every field, and an
  end-to-end replay of 19 of 30 roads.
- **The surface-ID buffer exists and has been run** — §12.14's prerequisite is
  cleared. `SR_SID_*` from `fill_record` on the C side, the same ids in `UV2.x`
  on the port side, `tools/sid_compare.py` between them. It answers "which
  surface" where the palette cannot.
- **Fourteen defects were found by reading `SKYROADS.EXE`**, every one also in
  `skyroads-port/`, which is why no test could see them.
- **The simulation is anchored to the binary** — collision, both profile tables,
  `in_tunnel`, the swept move, surface effects, burn rates, the HUD's three
  formulas, the autopilot. Only the attract demo and the road-end fade still
  rest on the C reference alone.
- **Mobile shell** runs on an emulator, never on real hardware. A Godot port
  credit plays after the original's five plates. No store release.

## In flight

Seven uncommitted files (the surface-ID work + §12.15). Three measured, unfixed:

- `scripts/Main.gd:491` `_capture_pending()` — **`--shot-alpha` never reaches the
  saved image.** Captures at 0.0/0.25/0.5/0.75/3.0 are byte-identical
  (md5 `2ceda940c3310195774ff2ad1ee11861`), yet a print after the override shows
  `view_y` moving 602 game units (4.7 rows). `force_draw()` +
  `get_texture().get_image()` returns the previous frame. Fix this first.
- `scripts/RoadMesh.gd` — the near-field block top sits ~10 rows too low at road
  21 t=200. NOT a wrong surface (both engines say `tunhigh.k5.0`) and NOT a
  wrong size (27 DOS rows vs 26). Wrong place, by an amount that varies with x
  (+16 at x=100, +10 at x=140..200, 0 at x=240) and inverts sign with depth.
  Contaminated by the capture bug — re-measure after it is fixed.
- `scripts/ShipSprite.gd` — the ship reads 8 rows high at t=200, but that is a
  TICK ALIGNMENT, not an altitude scale: the sprite falls 8 rows per tick there,
  and against `c_t0199.sid` it lands within one row. Both engines use the
  identical expression (`top = 0x9D - alt`). Do not "fix" the scale.

## Verify

```bash
tools/verify.sh                      # 484 checks
THREEWAY=1 tools/verify.sh           # + C vs Python vs GDScript on real levels
```

Over ten minutes — background it. **Do not edit a source file while it runs**:
each phase loads scripts fresh, and an edit mid-run wedged it for 26 minutes
looking exactly like a hang. **A windowed capture steals keyboard focus.**

### The surface map

```bash
clang -O2 -o /tmp/sr_replay_frames tools/replay_frames.c \
    skyroads-port/src/core/{assets,audio,cfg,game,gfx,hud,lzs,play,render,tables,text}.c \
    skyroads-port/src/thirdparty/opl3.c -lm
SR_SURFACE_IDS=1 /tmp/sr_replay_frames <retail> <out> 21 godot/data/routes/road_21.bin 200 400
$GODOT --path godot --resolution 640x480 -- --replay 21 \
    --route-file res://data/routes/road_21.bin --shots <out> --shot-ticks 200 --surface-ids
tools/sid_compare.py <out>/c_t0200.sid <out>/road21_t0200.sid.png [--column X] [--rows 34,128]
```

## Open questions

- **Repo public or private** is undecided, and separate from publishing (settled:
  no store release). If it goes public, the derived `data/` is the thing to look
  at — `LICENSE` carves it out as Bluemoon's.
- **§1.1 needs one live trace** and cannot close without a human: play with
  `--record`, press `R` on a moment that feels wrong, replay the dump.
- **The letterbox.** Filling it needs `aspect=expand` plus a fixed 320x240
  `SubViewport`, which moves both the capture path and the touch transform.
- **Eleven roads have no route**: 10, 12, 13, 16, 18, 19, 20, 27, 28, 29, 30.
  Coverage, not defects — collision is clean, so none is unwinnable.
- **The four README comparison screenshots** predate the tun_high and ship-clip
  fixes and should be regenerated.

## Do not redo

- **"Matches `skyroads-port/`" is not evidence.** Fourteen defects were in both.
  Disassemble: code image at `hdrpar * 16` (u16 at EXE offset 8), addresses
  code-segment relative, data segment paragraph `0x66E`, `CS_MODE_16`.
- **Apply `godot/docs/reference-corrections/` before trusting any parity number.**
- **Measure parity in RGB (tol 16) for "did this pixel change"; use the surface
  map, never colour, for "WHICH surface is this".** Road 21 has `[61]==[68]` and
  `[62]==[66]`, gap 0 — a block face and an arch band are byte-identical.
  Road 2 is the EASIEST road at 9.5%; median over eight roads is 16.4%.
- **The surface map has a blind spot.** It records only what `fill_record`
  writes, and DOS paints some pixels by other routes: below the nearest span
  record it reads `none` while the screen is painted (lane centre stops at
  y=128, yet rows 129..137 agree with the port in RGB to 14 px in 2880). A
  `none -> X` row is a question, not a verdict — 2643 of one run's 4546
  "differences" were this. Pass `--rows 34,128`.
- **Do not touch the camera on a hypothesis.** Five attempts have now measured
  worse or explained nothing — three in #29b, §12.13's depth ladder (road 26
  t=1000: 7.3% -> 76.0%), and §12.15's scroll quantisation.
- **The scroll quantisation is KEPT** (`SkyRoadsCamera.dos_scroll_row`): it wins
  on both metrics (sid 14.1 -> 13.7%, RGB 9.0 -> 8.6%) and is read off the eight
  baked band tables. It is simply not the near-field defect. Do not remove it,
  and do not re-file it as the cause.
- **Do not make `--sub-column` the solver's default.** Wins 6, 8, 25; loses 5,
  14, 24. That is why it is a retry pass.
- **Do not re-derive the tun_high from the vault.** Full-height block with a
  bore; `0x2fb0` never loads `[di+8]`.
- **Do not paint the letterbox with a CanvasLayer** — impossible with
  `aspect=keep`; not even the clear colour reaches it.
- **Do not remove the CONTROLS menu item on mobile** — it is the only route to
  the sound setting; `render_menu.gd` catches it.
- **Do not re-fit the camera as a single pinhole** (#28): a vertical pinhole at
  B=2.550 AND a horizontal cone through y=32 are both required.
- **Do not redo STAGE X draw order.** The ship never depth-tests. Tripwire:
  `godot/tests/test_occlusion.gd`.
- **Do not re-derive the tunnel arch from `TUN_INNER`/`TUN_OUTER`** — those are
  the COLLISION profile. The drawn profile is `RoadMesh.ARCH_OUTER_PX` /
  `ARCH_BORE_PX`.
- **Every texture `.import` is pinned to `detect_3d/compress_to=0`** (374). An
  editor scan can undo that — which is why new scripts avoid `class_name`.
- **The DOS framebuffer is opaque.** Palette index 0 is BLACK, not transparent.
- **A test that reaches a commit path must not write `user://skyroads.cfg`.**
- **Never time a shell fade in frames** (~1400 fps), and never write a `pgrep -f`
  wait loop whose pattern appears in its own command line.

## Retail data

Erased by every reboot. Re-download over **HTTP**:
`curl -o skyroads.zip http://www.bluemoon.ee/history/skyroads/skyroads.zip`
`SKYROADS.EXE` sha256 `c3a55223e359749555535e138ef4219bc94458639e44f70edf3cfcb2f28c26ac`.
It is the project's measuring instrument, not just provenance.
