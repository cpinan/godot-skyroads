# STATUS — SkyRoads Godot port

_Last updated: 2026-09-01 · git lives in `godot/` only, branch **`main`** · `cpinan/godot-skyroads` (PRIVATE) · `tools/`, `docs/`, `analysis/`, `skyroads-port/` sit outside the repo_

## Next action

Decide whether the repo goes public — the screenshots it would be judged on
are now current, which was the condition for asking. Every engineering item on
this list has been closed — three of them (§12.22, §12.24, §12.25) closed as
"measured, nothing to fix", which is a result and not a deferral. What is left
needs a human: §1.1's live trace, mobile on real hardware, and that decision.
The seven unrouted roads are the only open engineering work, and they are
coverage rather than defects.

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
  - §12.21 the SECTOR GEOMETRY, recovered — #31's missing piece. The six
    kind-4 arch records are separated by fixed RADIAL LINES through the
    lane cone's vanishing point, the same to ±0.002 across all eight
    scroll phases. The old model picked the band from the slice index,
    which is a position in the LANE, and a raised surface does not
    project into its own lane's wedge.
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
- **Mobile has never run on real hardware** — emulator only.
- **The letterbox is CLOSED, not open** (§12.25). A 4:3 picture cannot fill a
  2.23:1 screen at any scale, so the bars are geometry rather than a defect.
  Decided 2026-09-01: keep integer scaling and the exact field of view.
- **Seven roads have no route**: 12, 18, 20, 27, 28, 29, 30 — and §12.26 says
  why, which is not what this file used to say. Four of them (12, 18, 28, 29)
  are FUEL-short: the tank buys exactly `fuel_rows` rows however the road is
  driven, and those four roads are longer than their tank. Three carry exactly
  one supply tile each and the beam collected it **zero** times in a full
  search. Road 28 has no tile at all and is still finishable, because the burn
  truncates to zero below speed 493. It is not beam width — the niche keeps the
  state furthest along, which is always the fastest, so the thrifty line dies
  at every width. Fuel in the key, a speed bucket in the niche and a waypoint
  decomposition were all tried; none routed a road and the finer niches made 28
  and 29 worse. It needs a solver whose objective is not progress.
- **The attract demo and the road-end fade are anchored to the binary now**
  (§12.23): both were correct, and the C reference is no longer the reason to
  believe them.
- **The one-row offset is NOT a defect** (§12.22): mean signed boundary error
  is -0.09 to -0.35 rows with no depth trend, the ship's box matches exactly,
  and 100% of paired boundaries on clean frames agree within one row. Do not
  fit a constant to it.
- **The second rim record is deliberately not emitted** (§12.24): `k4.6` and
  `k4.7` are the same palette entry, so the split moves no pixel, and dropping
  the port's rim quad measures WORSE (6.4% -> 9.9%).
- **The tunnel interior is still the worst frame**, but at 6.4% rather than
  14.3% (road 2 t=741). What is left is the second rim record, which the port
  does not emit because the `k4.6`/`k4.7` split is NOT radial (±0.3 to ±0.5,
  against ±0.03 for the vault boundaries), and the same one-row offset that
  shows everywhere else. §12.21.
- **The arch was NOT double-corrected by §12.19** — checked before §12.21 was
  built: the warp alone improved the mouth 7.7% -> 1.7% and the interior
  14.3% -> 10.2%.
- **The screenshots are all current as of 2026-09-01.** The three road
  comparisons were rebuilt with `tools/make_compare.py` and the port-only
  gallery with `--menu-shot` / `--shot-ticks`. `compare_menu.png` and
  `menu_main.png` were regenerated and came out byte-identical, which is its
  own small proof that the menus did not move. `intro_credits.png` is the one
  left alone — the credits have not changed and there is no capture flag for
  the intro.

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
