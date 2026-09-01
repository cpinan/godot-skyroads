# STATUS — SkyRoads Godot port

_Last updated: 2026-09-01 · git lives in `godot/` only, branch **`main`** · `cpinan/godot-skyroads` (PRIVATE) · `tools/`, `docs/`, `analysis/`, `skyroads-port/` sit outside the repo_

## Next action

Decide whether the repo goes public — everything else in this file is either
green or an open question that needs a human. If more parity is wanted, the
arch constants below are the next measurable thing.

## State

- **`THREEWAY=1 tools/verify.sh` is green**, including an end-to-end replay of
  **23 of 30 roads** in the real scene and 60,964 ticks agreeing across C,
  Python and GDScript on every field.
- **Road parity is 0.5% to 2.0% of road pixels** (RGB, tol 16, DOS rows
  34..128) on roads 2, 5, 21 and 26. It was 2.0% to 8.4% this morning and
  9.5%+ in the published figures before that.
- **Three defects in the MEASURING PATH were found and fixed**, which is most
  of that improvement:
  - §12.16 the capture saved the frame BEFORE the one it named (`Node3D`
    transforms reach the server only after `_process`; `force_draw()` inside
    `_process` drew the previous flush). `--shot-alpha` now reaches the image
    and two runs at one alpha are byte-identical.
  - §12.17 `replay_frames.c` numbers its dumps one tick ahead, so every
    comparison was against the NEXT reference tick. **C's `c_tN` is the port's
    `t(N+1)`** — the golden dashboard test always paired them correctly, the
    parity recipes did not.
  - §12.18/§12.19 the near-field defect, attributed and corrected: the
    original's vertical projection is not one pinhole. The camera reproduces
    the DECK band edges to 0.24 px and raised surfaces are on a different
    ladder — identical for half- and full-height blocks, exactly 1:1 at the
    ship's own depth. `SkyRoadsCamera.dos_y_scale()` applies it as a vertex
    term beside the horizontal cone. The camera itself is unchanged.
- **Four more roads have a route** (10, 13, 16, 19; 19 -> 23 of 30). Three came
  from re-running existing passes at the DEFAULT beam; road 19 needed a new
  retry pass keyed on ALTITUDE, because the finish gate needs the ship inside
  the end tunnel and two airborne states at different heights shared a niche.
- **The simulation is anchored to the binary** — collision, both profile
  tables, `in_tunnel`, the swept move, surface effects, burn rates, the HUD's
  three formulas, the autopilot. Only the attract demo and the road-end fade
  still rest on the C reference alone.
- **Mobile shell** runs on an emulator, never on real hardware. A Godot port
  credit plays after the original's five plates. No store release.

## In flight

Nothing uncommitted, nothing half-written.

## Verify

```bash
tools/verify.sh                      # the gate
THREEWAY=1 tools/verify.sh           # + C vs Python vs GDScript on real levels
```

Over ten minutes — background it. **Do not edit a source file while it runs**:
each phase loads scripts fresh, and an edit mid-run wedged it for 26 minutes
looking exactly like a hang. **A windowed capture steals keyboard focus.**

### Parity, end to end

```bash
clang -O2 -o /tmp/sr_replay_frames tools/replay_frames.c \
    skyroads-port/src/core/{assets,audio,cfg,game,gfx,hud,lzs,play,render,tables,text}.c \
    skyroads-port/src/thirdparty/opl3.c -lm
SR_SURFACE_IDS=1 /tmp/sr_replay_frames <retail> <out> 21 godot/data/routes/road_21.bin 1 202
$GODOT --path godot --resolution 640x480 -- --replay 21 \
    --route-file res://data/routes/road_21.bin --shots <out> --shot-ticks 200 --surface-ids
# NOTE THE TICK: the port's t=200 is the reference's c_t0199 (BUGS 12.17)
tools/frame_compare.py <out>/c_t0199.ppm <out>/road21_t0200.png --rows 34,128
tools/sid_compare.py   <out>/c_t0199.sid <out>/road21_t0200.sid.png --rows 34,128
tools/make_compare.py  <out>/c_t0199.ppm <out>/road21_t0200.png shot.png
```

## Open questions

- **Repo public or private** is undecided, and separate from publishing
  (settled: no store release). If it goes public, the derived `data/` is the
  thing to look at — `LICENSE` carves it out as Bluemoon's.
- **§1.1 needs one live trace** and cannot close without a human: play with
  `--record`, press `R` on a moment that feels wrong, replay the dump.
- **The letterbox.** Filling it needs `aspect=expand` plus a fixed 320x240
  `SubViewport`, which moves both the capture path and the touch transform.
- **Seven roads have no route**: 12, 18, 20, 27, 28, 29, 30. Roads 12 and 18
  reach their LAST ROW (160.7/164 and 163.0/163) and never trigger the finish
  gate, so for those two it is the tunnel-mouth entry, not traversal.
- **The arch constants have not been re-derived.** `RoadMesh.ARCH_OUTER_PX` was
  measured at phase 0 / dr7, where the new ladder reads 0.868, and converted
  with `PIXEL_Y`, which is calibrated where it reads 1.000. Road 21 improved
  four-fold so it cannot be far wrong, but a re-measurement has to divide the
  ladder out first.
- **`docs/screenshots/compare_menu.png` was not regenerated** — the menus are
  unchanged and still 0 differing pixels, so it is still true. The three road
  ones were rebuilt with `tools/make_compare.py`; the port-only gallery further
  down the README was not.

## Do not redo

- **"Matches `skyroads-port/`" is not evidence.** Fourteen defects were in both,
  and §12.17 makes fifteen. Disassemble: code image at `hdrpar * 16` (u16 at
  EXE offset 8), addresses code-segment relative, data segment paragraph
  `0x66E`, `CS_MODE_16`.
- **Apply `godot/docs/reference-corrections/` before trusting any parity number.**
- **Pair the frames by §12.17.** C's `c_tN` is the port's `t(N+1)`. Comparing
  `t0200` with `c_t0200` costs a whole tick — 8 screen rows of ship on road 21.
- **Measure parity in RGB (tol 16) for "did this pixel change"; use the surface
  map, never colour, for "WHICH surface is this".** Road 21 has `[61]==[68]`
  and `[62]==[66]`, gap 0.
- **The surface map has a blind spot.** It records only what `fill_record`
  writes, and DOS paints some pixels by other routes. A `none -> X` row is a
  question, not a verdict. Pass `--rows 34,128`.
- **Do not touch the camera.** Five attempts measured worse or explained
  nothing (#29b x3, §12.13's depth ladder, §12.15's scroll quantisation). What
  finally worked, §12.19, changed NO camera constant: it added a vertex term
  read off the baked tables, and the deck still lands where the fit put it.
- **Do not re-fit the camera as a single pinhole** (#28): a vertical pinhole at
  B=2.550 AND a horizontal cone through y=32 are both required — and now a
  third term for raised surfaces (§12.18).
- **The scroll quantisation is KEPT** (`SkyRoadsCamera.dos_scroll_row`) and is
  NOT the near-field defect; §12.19 is.
- **Do not make `--sub-column` the solver's default.** Wins 6, 8, 25; loses 5,
  14, 24. Same for `--altitude`: it is a retry, and it won road 19.
- **Re-run the solver at the DEFAULT beam before calling a road unsolvable.**
  Roads 10, 13 and 16 all failed at `--beam 1024 --hold 1` and fell to
  `--beam 48 --hold 3`; a wider beam fills with airborne states.
- **Do not re-derive the tun_high from the vault.** Full-height block with a
  bore; `0x2fb0` never loads `[di+8]`.
- **Do not paint the letterbox with a CanvasLayer** — impossible with
  `aspect=keep`; not even the clear colour reaches it.
- **Do not remove the CONTROLS menu item on mobile** — it is the only route to
  the sound setting; `render_menu.gd` catches it.
- **Do not redo STAGE X draw order.** The ship never depth-tests. Tripwire:
  `godot/tests/test_occlusion.gd`.
- **Do not re-derive the tunnel arch from `TUN_INNER`/`TUN_OUTER`** — those are
  the COLLISION profile. The drawn profile is `RoadMesh.ARCH_OUTER_PX` /
  `ARCH_BORE_PX`.
- **Every texture `.import` is pinned to `detect_3d/compress_to=0`** (374).
- **The DOS framebuffer is opaque.** Palette index 0 is BLACK, not transparent.
- **A test that reaches a commit path must not write `user://skyroads.cfg`.**
- **Never time a shell fade in frames** (~1400 fps), and never write a `pgrep -f`
  wait loop whose pattern appears in its own command line.

## Retail data

Erased by every reboot. Re-download over **HTTP**:
`curl -o skyroads.zip http://www.bluemoon.ee/history/skyroads/skyroads.zip`
`SKYROADS.EXE` sha256 `c3a55223e359749555535e138ef4219bc94458639e44f70edf3cfcb2f28c26ac`.
It is the project's measuring instrument, not just provenance.
