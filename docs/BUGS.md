> **Note for readers of the published repository.** This is the working audit
> trail kept while porting SkyRoads, copied here because the README cites it.
> It refers to a C reference implementation of the DOS engine (`skyroads-port/`)
> and to measurement tools (`tools/`) that live in the wider working tree
> rather than in this repository; the entries are kept verbatim because the
> reasoning, including the diagnoses that turned out to be wrong, is the
> useful part.

# SkyRoads Godot port — defect report and review brief

Prepared for an independent review. Written by the person (well, model) who
wrote the bugs, so treat the "ruled out" claims as claims, not facts — the
evidence for each is cited so it can be re-run.

> **2026-08-30: a four-way audit against the reference was completed and its
> results, plus an ordered fix plan, are in §8 and §9 at the bottom. §8
> supersedes §1.1's candidate list — read it first.**

**Headline: the reporter still sees wrong behaviour around empty spaces
(holes) and block collisions after every fix below.** That is the open
question. Everything else here is context for whoever picks it up.

---

## 0. Orientation

| | |
|---|---|
| `skyroads-port/` | reverse-engineered C port + `re/notes/` — **the ground truth** |
| `analysis/` | Python toolkit (`./sra.py`), 6.6k lines |
| `godot/` | the Godot 4.7 port, 3.2k lines |
| `godot/verify.sh` | 117 checks across 7 suites — currently all green |

Ground truth hierarchy, most authoritative first:

1. `skyroads-port/re/notes/gameloop.md` — physics, disassembly-verified, with
   an EXE instruction address for every constant. **Trust this over
   everything, including `renderer.md`.**
2. `skyroads-port/src/core/*.c` — a working implementation of those notes.
3. `re/notes/renderer.md` — rendering. Contains at least two errors found so
   far (§3 below).
4. `docs/FORMATS.md` — contains at least three errors (§3).

Retail data is present and every parser validates against it.

### Reproducing anything

```sh
cd analysis
./sra.py validate 1 --pilots 60          # road 1 through C, Python, GDScript
./sra.py threeway --trials 250           # randomised roads, all three engines
./sra.py difftest --trials 300           # C vs Python only
cd ../godot && ./verify.sh               # Godot suites incl. windowed render
THREEWAY=1 ./verify.sh                   # + the cross-engine gates
```

In-game: **L** object IDs, **C** collision overlay, **R** dump input script.
Recordings land in
`~/Library/Application Support/Godot/app_userdata/SkyRoads/recordings/`
and replay with `--replay <road> --route-file <path>`.

---

## 1. OPEN — the reported problem

> **2026-08-30, STAGE X classification (FIXPLAN X1/X2): the report "the
> player does not collide properly with the objects and obstacles" is the
> RENDERER, not the simulation.** Evidence, in order:
> 1. Three-way run (C / Python / GDScript, 121 runs, 25,512 ticks over the
>    shipped roads 1 and 30, 60 random pilots each, including 7 wall
>    crashes): **every field of every tick identical.** The simulation
>    cannot be the bug.
> 2. The under-occlusion band of §8.2 #1 was reproduced deterministically in
>    `test_occlusion.gd` (wall in the row behind the ship → 152 sprite px
>    drawn over it at the shipped DEPTH_BIAS) — the ship drawn inside a wall
>    it has already hit, which is exactly what "did not collide" looks like.
> 3. **Fixed structurally** (FIXPLAN X3, absorbing T14 + T18): per-row road
>    meshes reproducing the DOS band order — floor never over the sprite,
>    rows nearer than the ship's painted after it — plus the 10-row draw
>    window. All three occlusion scenarios now measure correct (0 / 152 / 0
>    px). The DOS order itself was confirmed by rendering frames from the C
>    engine (`sr_render_test`): the grounded sprite sits wholly inside the
>    screen strips of the rows behind it, so no depth constant could ever
>    work.
> No live user trace existed for this pass (user AFK); if the report recurs,
> capture it with `--record` + `R` and replay — the overlay (§1.2, now
> depth-ordered) can judge it directly.

> **2026-08-30, LATER — the user reported "still a lot of collision issues,
> they are offset" and asked for a full collision validation. Found and
> fixed: §8.2 #28, the camera projection itself.** A frame-parity harness
> (`tools/replay_frames.c` — replays the port's own route files through the
> C engine and dumps frames on the same tick grid) showed the ship blit
> pixel-identical to DOS but the WORLD drawn wrong at every depth except
> one anchor. Decoding the actual TREKDAT band tables (`tools/dump_bands.c`)
> gave the truth: vertical mapping is a pinhole with camera **2.550** rows
> behind the ship (shipped constant: 3.535 — a full row off), F=235.64,
> P=9.57 in 200-line space, rms 0.24 px; horizontal lane edges are straight
> lines through a vanishing point at **y=32** with lane width (2/3)(y−32) px
> — 46 px/lane exactly at the ship's deckline, and deliberately inconsistent
> with the vertical pinhole. No physical camera can do both, which is why
> every refit "almost" worked. Fix: true vertical pinhole in
> `SkyRoadsCamera` + the horizontal cone as a vertex-shader warp on all road
> materials (`make_dos_material`). After the fix the parity harness measures
> the ship AND the world aligned with the C reference frame-for-frame
> (crash-run ship delta 0,0 at rest and at the wall; ruler-road bands,
> block sizes and convergence match).

### 1.1 Holes and block collisions still feel wrong · UNRESOLVED

The reporter has said this after each of the fixes in §2. It is the reason
this document exists.

**What has been ruled out, with evidence:**

- The physics is not wrong. The reporter's own 10 recorded sessions replay
  **bit-identically** in the C engine, the Python model and GDScript — 9,063
  ticks × 24 state fields, including two wall crashes and five falls.
  ~200k further ticks agree over randomised roads and all 7 outcomes.
- The drawn road matches the collision grid cell-for-cell
  (`test_geometry.gd`): road 1 has 174 of 385 cells without floor and every
  one is a real gap; verified visually by rendering with a magenta backdrop.
- Lanes line up laterally: a lane draws exactly 46 px at the ship's depth and
  every lane's sprite position lands inside its drawn lane.

**What has NOT been ruled out — candidates for the reviewer:**

1. **The reporter may have been playing with no controls bound.** See §2.1.
   That bug was live for part of the reporting window and would make the ship
   do only what gravity does. Several reports may collapse into it. *This
   should be re-tested first, before anything else here is trusted.*
2. **Ship sprite vs. its collision volume, vertically.** The sprite is placed
   by the original's screen formula (`top = 0x9d - y/0x80`), which is linear
   in altitude. The road is placed by a fitted perspective camera. These agree
   at the deck (verified: canvas y 91.3 vs the original's 91.2) but diverge as
   the ship climbs — roughly 20% by full block height. Nobody has measured the
   discrepancy at altitude. **This is my best guess at the remaining issue.**
3. **The "edge support" rule looks like a bug and is not.** `fn_1685` treats
   the deck as solid if *either* probe at `x ± 0x700` is over floor, so the
   ship hovers over a gap with 1 px of support. Meanwhile `over_hole` (which
   blocks jumping) uses the **centre tile only**. In the same spot you float
   but cannot jump. Authentic; reads as broken.
4. **The neighbour-lane block probe.** `fn_1685` probes the adjacent column at
   profile distance `0x2f - t`, and `solid_block` bails when `t > 0x25`, so it
   bites once `t >= 10` — the ship's centre 10 px toward the next lane, about
   4 px before the drawn hulls touch. Authentic; reads as "collides too early
   with big blocks".

Candidates 3 and 4 are authentic behaviour. If the reviewer confirms the port
matches the original there, the remaining work is to make the *drawing* show
the player what the simulation is doing — not to change the physics.

### 1.2 The debug overlay is misleading about draw order

`CollisionDebug` uses `no_depth_test = true`, so with **C** on everything is
drawn over the world. Draw-order problems must be judged with it **off**.

**FIXED 2026-08-30 (FIXPLAN X4):** the overlay now uses the renderer's own
10-row window and band order — rows at or beyond the ship's draw under the
sprite, rows nearer draw over it, and the yellow ship-extent marker draws
last. "Red where the ship is" now means the ship is genuinely inside solid,
so the overlay can judge the next collision report directly.

---

## 2. FIXED — with root causes

Every one of these was found from a reporter complaint plus a rendered frame
or a recording. None was found by the test suite before the fact.

### 2.1 Controls entirely unbound · CRITICAL

Added the key map by appending an `[input]` block to `project.godot`. **Godot
dropped it on import.** All nine actions existed with **zero** key events, so
`Input.is_action_pressed()` was always false — the game had no gameplay
controls at all.

The test that should have caught this checked `InputMap.has_action()`, which
returns true for an action bound to nothing. 23 green checks over a game with
no controls.

*Fix:* map built in code (`scripts/Controls.gd`); the test now asserts each
action has ≥1 key event.
*Lesson for the reviewer:* be suspicious of any assertion that checks a thing
exists rather than that it works.

### 2.2 Only half the original's key map

`gameloop.md` §10 lists eleven keys. Five were implemented. Home/PgUp/End/PgDn
are each a **single key meaning a diagonal**, so steer+throttle+jump needs two
keys instead of three — and many keyboards silently refuse three. Mac laptops
have none of those keys, so Q/E/Z/X aliases were added.

Plausibly the cause of "cannot jump while pressing the arrows".

### 2.3 Road drawn 1.58× too narrow · CRITICAL

Lateral scale was derived from `renderer.md`'s column extents, which are
quoted at the **top scanline of the ship's row band** — the far edge of that
row, where a lane is 29 px. The ship is placed by a formula that puts lanes
**46 px** apart at the ship's own depth.

```
column_width  0.3683 -> 0.5814      road width  2.58 -> 4.07
```

The ship was drawn up to ~40 px from the lane it was in: sometimes over a hole
it wasn't in ("no collision"), sometimes short of a block it had hit ("too
early"). Error scales with distance from centre, so middle lanes looked fine
and outer lanes were badly wrong — hence "intermittent".

### 2.4 Blocks drawn 1.2× too short

Same root cause: mixing original pixels and canvas pixels. Mode 13h is 320×200
shown at 4:3, so one original pixel is 1.2 canvas pixels.

```
WORLD_PER_GAME_Y  9.8735e-05 -> 1.1848e-04
half block  20.0 -> 24.0 canvas px
```

### 2.5 Tunnels drawn as a striped wall

The tunnel front face was emitted for all 46 profile slices of **every**
tunnel cell, so consecutive tunnel rows stacked into a solid wall hiding the
road, the gaps and the ship. The original draws that face only at the mouth
(`renderer.md`: *"if nearer row's shape < 1: tunnel front wall"*).

### 2.6 Ship sprite exported transposed

`render.c draw_ship` reads `cell[j*24 + i]` with `j` the screen **column**, so
the on-screen sprite is the **transpose** of the stored 24×30 cell: 29×24,
with PICT row 29 never read. Exporting the raw cell gave rotated sprites.

### 2.7 Ship not depth-sorted, then invisible, then fixed

Three iterations, worth reading as a cautionary tale:

1. Sprite lived in a `CanvasLayer` → always drew over blocks.
2. Moved to 3D → **rendered nothing**. Cause: `ALPHA_CUT_DISCARD` on
   `Sprite3D` renders nothing here; `ALPHA_CUT_OPAQUE_PREPASS` renders *and*
   writes depth.
3. The first occlusion test put the wall **ahead** of the ship (farther), where
   drawing over it is correct. The test was wrong, not the renderer.

`test_occlusion.gd` now asserts **both** directions — 0 px behind a wall,
152 px on open road — because "0 pixels" is also what a ship that fails to
render looks like.

### 2.8 Floor depth-write vs. ship, unresolved trade-off

To stop the floor swallowing the sprite, floor depth-writing was disabled —
which left the depth buffer empty over the road so later geometry could paint
over nearer road. Now: floor writes depth, and the sprite is depth-tested
`DEPTH_BIAS = 0.95` rows nearer, since floor between ~2.59 and ~3.54 units
overlaps it on screen.

**This is a compromise, not a correct solution.** The original draws the
ship's row in two passes with the sprite between them (`renderer.md` §3,
directory rows 11/12). The port does not implement that. A reviewer may find
the bias interacts badly with something.

### 2.9 Camera judder

`GameLoop.interpolation()` was written and **never called**. Camera and ship
moved at 36 Hz while the screen redrew at 60–120. Presentation now
interpolates every frame; the simulation never reads it back.

### 2.10 Frustum sign, twice

Godot *adds* the frustum offset to both edges, so the off-centre principal
point needs a **negative** offset. Got it wrong, "fixed" it in the wrong
direction to compensate for the backdrop bug (§2.11), then settled it by
measurement: `unproject_position` puts the road under the ship at canvas
y 91.3 against the original's 91.2.

Also: `project_position` is **not** consistent with this off-axis frustum — it
returned a vertical extent ~10× too small. All screen↔world conversion goes
through `SkyRoadsCamera.screen_to_world`, which uses the fitted pinhole model.

### 2.11 Backdrop hid the entire road

The world backdrop was a `CanvasLayer`, which always draws over 3D. It has to
live in the 3D frustum.

### 2.12 Dashboard was a static image

Speedometer, fuel, oxygen, progress bar, GRAV-O-METER and jump-o-master lamp
were exported and never drawn. Now live, using `fn_124b`'s arithmetic —
including that the speedometer shows speed **minus** the autopilot delta so
the landing assist stays invisible.

### 2.13 Toolkit defects (analysis side)

- `PICT` has **no** dummy word — `docs/FORMATS.md` §2 is wrong. A parser that
  skips one misreads every image.
- `ANIM.LZS` cannot be parsed by scanning for tags; per-frame record counts
  are bare `u16`s.
- `SPEED.DAT` is not "format TBD": `u16 offsets[34]` then records at byte 68.
- `min_time_secs` used max speed where it needed acceleration — a 3.78 s
  discontinuity.
- `code.index` keyed functions by bare name, losing 9 same-named statics.
- `verify` was a substring grep: `0x8` had 10 substring hits and **zero** real
  literals, so constants could "verify" by coincidence.
- Pillow vanished from the machine mid-project and `export-godot` crashed
  outright rather than degrading; PNG writing is now dependency-free.
- Design heuristic condemned retail roads 27 and 29 as unplayable — both open
  with 3 empty rows, but the ship spawns at row 3.

---

## 3. Errors found in the reverse-engineering notes

Relevant because a reviewer will otherwise trust them.

| source | claim | reality |
|---|---|---|
| `FORMATS.md` §2 | `PICT u16 dummy, ofs, h, w` | no dummy word |
| `FORMATS.md` §6 | `SPEED.DAT` format TBD | gauge layout, 34 entries, base 68 |
| `FORMATS.md` §8 | OPL ch 7-8 are a speed-following engine hum | retracted in `audio_misc.md` §2.4 — no engine sound exists |
| `renderer.md` §9.4/§13 | `end_state` only ever 0/1/2, so the empty-tank lamps are dead | `play.c` assigns 3/4/5; `gameloop.md` §5.19 cites the writes |
| `renderer.md` §2.3/§13 | ship frames 14..74, 75/76 unused | 7 tilts × 3 pitches × 3 flames = 63, so 14..76 |
| `renderer.md` §4.4 | column extents (used for lateral scale) | measured at the row band's far edge — see §2.3 |

---

## 4. MISSING — not implemented

| | notes |
|---|---|
| **All audio** | 5 SFX + 14 OPL2 songs exported, none wired. Includes the empty-tank warning beep (sfx 3), which is the only unreachable sound in the C port too |
| **Intro / ANIM sequence** | 221 delta frames exported, never played |
| **Same-row post-ship occlusion** | `renderer.md` §4.3 directory rows 11/12; empty at most scroll phases |
| **Tunnel arch art** | extruded from the collision profile with the correct 68..73 gradient, but not the baked span art |
| **Settings screen persistence** | draws correct state; control-scheme choice does not actually change input handling |
| **Road 30 route** | the beam solver cannot finish the real road 30 (200 rows of stepping stones, 2-row gaps, 1-row runways). Covered by a deterministic probe trace instead |

---

## 5. Test coverage, and where it is weak

`godot/verify.sh` — 117 checks, 7 suites, currently green:

| suite | what it covers |
|---|---|
| parse pass | every script, referenced or not |
| `test_occlusion` | windowed; ship hidden behind a wall AND drawn on open road |
| `test_data` | level shape, tile helpers, camera credibility |
| `test_geometry` | drawn road vs collision cell-for-cell; lane width 46 px; block heights |
| `test_hud` | gauge arithmetic incl. the hidden autopilot delta |
| `test_input` | full key truth table; actions have keys bound |
| `test_physics` | 23-field golden traces vs the reference model |
| `test_timing` | same elapsed time at 15/30/60/144 fps |
| end-to-end | replays a solved route through the real scene |

**Known weaknesses:**

- Almost nothing asserts on **pixels**. `test_occlusion` is the only rendering
  test, and rendering is where every recent bug has been.
- Golden traces replay routes that **succeed**, so they never exercise a
  crash, a fall or an empty tank. The three-way differential covers those, but
  it is opt-in (`THREEWAY=1`).
- No test compares against the **original binary** — only against the C port.
  If `play.c` diverges from DOS, the whole stack reproduces it faithfully.
  `DEMO.REC` is the one real check and it passes: 1775 ticks, matching the
  figure `gameloop.md` records from instrumented-original telemetry.

---

## 6. Suggested review order

1. **Re-test with controls actually bound** (§2.1). Several reports may
   collapse into that single bug.
2. **Measure the ship sprite against its collision volume at altitude** (§1.1
   candidate 2). This is the most likely remaining real defect and nobody has
   measured it.
3. Decide whether §1.1 candidates 3 and 4 (edge support, neighbour-lane probe)
   are worth *showing* the player, given they are authentic but read as bugs.
4. Replace the `DEPTH_BIAS` compromise (§2.8) with the original's two-pass
   ship-row split.
5. Wire audio — the largest missing surface.

## 7. Standing invitation to be skeptical

Recurring failure mode in this work: **trusting a documented number instead of
checking it against the thing it must agree with.** §2.3, §2.4 and §2.10 are
all the same mistake. If a constant here has no test tying it to an observable,
assume it is wrong.

Second failure mode: **tests that assert existence rather than behaviour**
(§2.1), and **tests that pass for the wrong reason** (§2.7). Where a test
looks green, check what it would take for it to fail.

---

## 8. 2026-08-30 audit — four subsystems vs the reference, verified findings

Four independent read-only audits (physics, renderer, game flow/HUD, assets)
compared `godot/` line-by-line against `skyroads-port/src/core/*` and
`re/notes/`. Every finding below carries both sides' line numbers so it can be
re-checked. Baseline: `tools/verify.sh` all 117 checks green before and after.

### 8.1 Closed questions

- **§1.1 candidate 2 (sprite vs camera at altitude) is STALE — measured at
  ~0.0001 px, not 20%.** The sprite slope is −1.2/0x80 = −0.009375 px/unit;
  the fitted camera slope is −WORLD_PER_GAME_Y·FOCAL_PX/BEHIND_ROWS =
  −0.00937497. They were calibrated to agree (§2.4 recalibration). At jump
  apex (y = 0x3E85 on g=8) the gap is 0.047 canvas px, all of it the
  original's own y/0x80 integer truncation. Stop investigating this.
- **Physics is confirmed faithful, including death paths.** A full re-audit of
  `SkyRoadsPlay.gd` vs `play.c`/`gameloop.md` — all five tile effects with
  errata gating, all outcomes 0..5 with the fell→fuel→oxy overwrite order,
  jump/bounce/autopilot/collision constants, u16 wrap semantics — found zero
  divergences. Do not touch `SkyRoadsPlay.gd`.
- **The remaining "wrong around holes/blocks" suspect is the CRIT finding
  below** (§8.2 #1), not physics and not sprite placement.

### 8.2 Open defects, ranked

> **STATUS LEDGER, 2026-08-30 (end of STAGE Z — T1-T21, STAGE X, STAGE Y and
> STAGE Z1-Z7 all complete).** The bodies below are kept as the audit record;
> this table is the truth.
>
> Closing gate for the stage: `THREEWAY=1 tools/verify.sh` green — 46,502
> ticks compared across 24 fields and three engines (C, Python, GDScript),
> agreeing on every field of every tick, over the 30 shipped levels and 80
> randomised roads. `tools/verify.sh` alone: 308 checks, 12 suites.
>
> Three of STAGE Z's seven tasks turned out to describe defects that did not
> exist as written (#29 near-row darkening, #30a "stars", #39 explosion
> framing). In each case the visible symptom was real and had already been
> fixed by an earlier task, or had a different cause entirely. The entries
> record what was actually wrong, because the wrong diagnosis is the part
> that costs a session.
>
> | item | state |
> |---|---|
> | 1 | **FIXED, STAGE X3** — per-row meshes reproduce the DOS band order (floor never over the sprite, nearer rows after it), ship at true depth, no depth test, no bias. `test_occlusion.gd` now has all three scenarios green: 0 px behind a wall, 152 px open road, 0 px against a just-hit wall. See §1 header. |
> | 2, 3 | FIXED, T15 — front/top/side colours and both per-half variants. Centre column approximated as left half (a per-cell colour cannot split mid-column). |
> | 4 | **FIXED, X3/T18** — 10-row window via `RoadMesh.update_window`, driven from `Main._process`. |
> | 5 | **FIXED, T17** — real TUN_INNER bore profile, entrance interior colour 65 at the mouth (shape(nearer) < 2), full-height sides. Split-top records still not modelled (top face stays one quad). |
> | 6 | **FIXED, T17** — mouth wall 67 above a one-step colour-66 inner-rim band; arch gradient per half from T15. Body/exterior arch records beyond the top face remain approximated. |
> | 7-11 | FIXED, T1-T8 (pause, catch-up, fades, menu returns, demo any-key, audio, intro). |
> | 12 | **FIXED 2026-08-30 (user decision at STAGE Z7: implement both)** — the original's `control` word (0 keyboard, 1 joystick, 2 mouse) now selects a device that actually does something. All three collapse to the same three values the simulation takes, so the mapping is one pure class, `scripts/model/PlayerInput.gd`, and `Main._read_device` only reads hardware. Joystick: left stick or d-pad, A/B to jump. Mouse: offset from the centre of the view, normalised, left button to jump — the DOS driver read an absolute position in a calibrated box, and this is the same idea without inventing a sensitivity constant. One deliberate deviation from the original, documented in the class: a config naming a joystick that is not plugged in falls back to the keyboard instead of leaving the player unable to steer. Covered by 14 checks in `test_input.gd`, mutation-tested (inverting the throttle sign and dropping the fallback both fail). |
> | 13-20 | FIXED, T2-T13 (fades, menu persistence, GOMENU brighten, SETMENU single overlay, lamp pixel swap + beep, progress art probe, RoadEnd palette colour, catch-up budget). |
> | 21 | **FIXED, T19** — tilt passed into `_index` from the interpolated x. |
> | 22, 23 | FIXED, T16 — floor-nibble edge tests, centre-only side edges, shapes 6..15 draw nothing. |
> | 24 | **FIXED 2026-08-30 (STAGE Z1)** — this was never a "tier": the tile's colour nibble patches the block's TOP face, not its front. Decoding the records settles it (`tools/dump_bands.c kindlines`): at dr7 ci1 kind 2's first record spans y[64,81], the band ABOVE the deck strip, and kind 3's spans y[82,101], the deck strip itself — and `blockcolor()` patches kind 2. render.c's own comments name the two the other way round. The port painted them swapped, which made every block read inside-out and put the patched colour on the lower band. Evidence: `docs/parity/z2_block_faces.png` (synthetic road, nibble A over floor 3 — reference and port now agree face for face). The 0.08 lip remains the one accepted non-authentic touch. |
> | 25 | **FIXED, T20** — shadow skipped when either support probe lands on a block top; priority under the ship so the MUL never darkens it. Per-pixel palette masking (only colours 1..15/0x3D darken) is still approximated by the stencil multiply. |
> | 26 | OPEN — routes are compute, not code. |
> | 41 | **OPEN, user-reported 2026-08-30 ("the gravity in the player HUD does not show anything, just 0 and something else").** Confirmed, with the mechanism. The VALUE is right: `HudModel.gravity_value(8)` is 500 and `gravity_digits` returns [0,0,5], so three digits are drawn. The problem is contrast. `draw_digit` paints stencil value 1 in palette 0x61 and value 2 in 0x62 — and **palette 97 (0x61) is (207,174,121), exactly the tan of the GRAV-O-METER panel**. The glyph is therefore formed by the UNPAINTED cells letting the dashboard art's black readout window show through, which only works where that window exists. Decoded from the art: the window covers the two RIGHTMOST digit slots (screen x 106-114). The hundreds digit sits at x 101-104, on plain panel, so it paints tan-on-tan and is invisible — you see "00" and nothing else, which is exactly what was reported. Note the port matches the C reference here at **0 differing pixels**, so either the reference has this wrong or the DOS original genuinely does; that is unresolved and needs a comparison against the real game under DOSBox. Prime suspects, in order: the digit colour indices (0x61/0x62 may be misread), `GRAVITY_POS` x (96 = 0x60), and the (g-3)*100 formula producing three digits for a two-digit window. |
> | 42 | **OPEN, user-reported 2026-08-30 ("jump-o-master does not show anything").** Partly a real gap, partly expected. The lamp DOES work: its two states differ in 49 of 130 cells, and `ap_light` is set on 28 of road 1's 462 ticks — but only while the landing assist is actively correcting a jump, i.e. 6% of the time and never for long, so a player will rarely catch it. The "IDLE" text beside it is part of the dashboard ART and never changes in this port. Unresolved: whether the original swaps that text (to something like "ON") when the assist engages, or whether the small lamp is the whole indicator. Same resolution path as #41 — compare against the real game. |
> | 40 | **DONE 2026-08-30 (user decision at STAGE Z7)** — the music was shipping as 125 MB of 44.1 kHz mono wav, in a 283 MB tree. Re-encoded to Ogg Vorbis q4: **17 MB, 7.4x smaller, 108 MB saved**, every file verified to decode to the same duration at 85-107 kbps. 44.1 kHz was kept deliberately — only 1.9% of the OPL renders' energy sits above 11 kHz, but it is real (the rhythm channels), and this is a port that measures things rather than assuming them inaudible. `AudioStreamOggVorbis` loops itself from `loop_offset`, so `AudioMgr._on_song_finished` and its end-of-stream seam are gone; `music_meta.json` still supplies the loop point. Verified still audible after the change: CoreAudio, master bus -3.2 dB. |
> | 27 | orphan `dbg_*.gd.uid` deleted (T21). The listed dead data files remain on disk, deliberately unwired; delete freely if the repo needs the space. |
> | 28 | **FOUND + FIXED 2026-08-30 (STAGE Y)** — the generated camera constants were wrong: BEHIND_ROWS a full row too big (3.535 vs the true 2.550), and DOS's horizontal mapping is a separate straight-line cone through y=32 that no pinhole reproduces. This was "the collisions are offset": world drawn misaligned against the DOS-exact ship blit at every depth. Fixed in `SkyRoadsCamera.gd` (new constants + `make_dos_material` vertex-shader warp on every road/overlay material, `dos_x_scale` for CPU-side label anchors). Derivation in the file header; measurement tools `tools/dump_bands.c`, `tools/replay_frames.c`; evidence in §1. The old §1.1 candidate #2 ("sprite vs collision vertically, diverges ~20% at altitude") was this same defect. |
> | 29 | **CLOSED 2026-08-30 (STAGE Z3) — the premise was wrong, and the symptom is fixed.** There is no per-row or near-field darkening anywhere in the DOS renderer. Proven directly: drive the C engine over a synthetic road whose every tile is the same code (0x0003) and read the palette index down the middle of the screen — it is index 3 at every distance from the horizon to the deck line, with no remap. Nothing in render.c or tables.c applies one either; `fill_record` resolves a colour through `sr_quad[k][half]` and half is the screen SIDE, not the depth. What the evidence composite actually showed was the block top/front colour swap (#24): road 26's near geometry is a big block, and the port was painting its front with the top's colour. Fixed in STAGE Z2; road 26's shading now tracks the reference at every sampled tick. Evidence `docs/parity/z3_road26_before_after.png`. |
> | 29b | OPEN, small, found while closing #29: road 26 still differs on ~17% of its solid road pixels, and the confusion is dominated by C index 3 -> port index 1 — two dark greys ONE PALETTE STEP APART, i.e. the port painting an adjacent ROW's colour. Road 26 is the one level that makes this visible, because its consecutive rows are a colour ramp (rows 31-40 run 15,15,3 / 15,3,4 / 15,4,5 / …), so a sub-tick difference in presented depth repaints whole bands from the neighbouring row. It is the residue of comparing an interpolating renderer against a tick-exact one, not a drawing fault. **Three fixes were tried and all measured WORSE — do not repeat them:** presenting the capture at alpha=0 (road 2: 6.5% -> 8.0%), stopping the catch-up loop on the scheduled tick so the shot is of that tick rather than tick N+k (-> 8.5%), and both together. The reference's frame for a tick corresponds to a moment this engine reaches PART-WAY through its own, so the interpolated, end-of-frame state is the closer match. Recorded in `Main._capture_pending`. |
> | 29c | OPEN, small, found while closing #29: on a tun_high cell (geometry nibble 5) the masonry tier's front stops flat at half-block height while the reference's runs down onto the arch, leaving a sliver of the vault's outer surface showing — measured on an isolated tile as the tier ending 5 screen rows early at the bore's centre. Recipe: a synthetic road of 0x0003 with 0x053f at rows 20-23 column 3, driven with a held-accelerate route, compared at t=170/178. A per-slice fix bounding the tier front by ARCH_OUTER_PX closed it on the isolated tile but REGRESSED road 2 (t=640: 9.9% -> 16.7%), so it was reverted; the tier's true lower bound is not ARCH_OUTER_PX and has not been derived. |
> | 29-old | OPEN, cosmetic, found during #28's parity sweep: road 26's nearest rows render much darker in the C reference than in the port (some per-row/near-field darkening the port does not model). Alignment is correct; colour only. See `scratchpad parity out_road26_t0240` composite. |
> | 34 | **FIXED 2026-08-30 (user report: "UI bugs in the player speed and UI")** — one root cause behind four symptoms. The DOS screen is a single opaque framebuffer: the world picture fills rows 0..137, the dashboard is STAMPED over rows 129..199 skipping its index-0 pixels, and the road is composed into rows 32..137 ONLY, so every transparent dashboard pixel below row 137 shows palette index 0, i.e. black. In the port the 3D viewport covers the whole window, so the live road bled through the dashboard art's transparent pixels — through the GRAV-O-METER digits, the JUMP-O-MASTER panel, the unlit side of the SPEEDOMETER and the bottom corners — and changed hue as the player drove between worlds. Fixed with an opaque black band behind the dashboard from row 138 down. Dashboard parity vs the C engine on the user's road-2 recording went from ~800 differing pixels per frame to **0 across every frame sampled**. This subsumes #30b, which was recorded as "corner speckle" but was the whole band. Tripwire: `tests/render_dashboard.gd` compares the band against C reference frames. |
> | 35 | **FIXED 2026-08-30 (user report: "also in game menu")** — same family. Every DOS menu begins with `sr_fb_clear(fb, 0)`, so index 0 is BLACK; the exports carry it as alpha 0 (INTRO.LZS alone has 15109 such pixels) and Godot's own grey clear colour showed through, mottling the main menu's night sky. Fixed with an opaque black ground behind every menu screen. |
> | 36 | **FIXED 2026-08-30** — the road-select completion pips drew as solid WHITE blocks instead of the original's small amber marks. Not a palette or export fault: `Menu._draw_overlay` called `load()` on the pip texture from INSIDE a `draw` handler, and a texture first loaded there renders as a plain white rectangle. Reproduced in isolation (the same texture preloaded draws correctly). Fixed by caching textures outside the draw pass. Road-select now matches the C engine **pixel for pixel**. |
> | 37 | **FIXED 2026-08-30, found by its own new test** — `LaunchOptions` (extracted from `Main._ready`): a flag needing a value treated the NEXT FLAG as its value, so `--shot-ticks --labels` parsed "--labels" as a tick list of one zero and silently dropped `--labels`. Every automated check in the repo reaches the game through these flags, so this broke harnesses rather than the game, and did it quietly. |
> | 39 | **CLOSED 2026-08-30 (STAGE Z6) — the framing defect is gone; the explosion pipeline is correct.** The task described the C engine drawing the road-16 mouth crash "small and framed INSIDE the ring" while the port drew the whole sprite over it. Both halves of that were the block-face colour swap (#24, fixed in Z2) plus the pre/post-ship draw order (#32, fixed in Z1): the "ring" is a block front, and with its colours swapped it read as a different shape entirely. Both engines now draw the same sprite in the same place, framed the same way. Three independent checks back it: the exported explosion art is BYTE-IDENTICAL to the reference's own CARS cells for all 14 frames (dumped straight from `sr_assets`); the sprite-index rule is the same expression (`expl_ctr / 3`, blank past 13); and `expl_ctr` traced tick by tick is identical in both engines (C reaches ctr=1 at its tick 57, the port at its tick 58, and the port's `play.tick` runs one ahead of the C loop index — same state, different label). Evidence `docs/parity/z6_explosion_framing.png`. |
> | 39b | OPEN, harness only, found while closing #39: a parity screenshot occasionally samples one ANIMATION frame stale. Measured on the road-16 crash by counting the blast's own pixels against the known sprite sizes — the port's frames came out at 231/115/67/272 px, i.e. sprites 1/2/3/5, where `expl_ctr` at capture time called for 1/2/**4**/5. Three of the four sampled ticks match the rule exactly and one is one frame behind, which makes it a property of WHEN the screenshot is taken relative to the tick loop, not of the game: `_capture_pending` runs after the frame's catch-up loop, so a frame that owes several ticks presents one of them and captures another. Same family as #29b, and the two fixes tried there (capture at alpha=0, break the loop on the scheduled tick) both made still-frame parity worse — so this is recorded rather than papered over. It does not affect gameplay; it affects the measuring instrument. |
> | 30a | **FIXED 2026-08-30 (STAGE Z4)** — the "chunky blue rectangles" were not stars and not a scaling fault: the star pixels were always correct. WORLDn.LZS has no transparency (the DOS engine memcpy's the whole picture into the framebuffer, so index 0 is opaque BLACK), but the export carries index 0 as alpha 0 — 27190 such pixels in world 8 alone — and Godot's importer then runs `fix_alpha_border`, which replaces the RGB of every fully transparent pixel with a bleed of its opaque neighbours. The backdrop material ignores alpha, so what reached the screen was that bleed: the night sky's black came out as blue-grey blocks. The exported art itself was verified BYTE-IDENTICAL to the C engine's pristine framebuffer, so nothing needed re-exporting. Fixed by flattening the picture onto black in `Backdrop.flattened()`. Affects five of the ten worlds (1, 2, 3, 5 and 8 carry transparent pixels), i.e. half the game's roads. Evidence `docs/parity/z4_backdrop_stars.png`; tripwire `tests/render_backdrop.gd`, which asserts the backdrop renders its own source art exactly. |
> | 38 | **FIXED 2026-08-30 (STAGE Z4, user report: "things appear from nowhere")** — two causes, both found by asking the reference where its road is allowed to be. (a) `RoadMesh.update_window` was driven by the INTERPOLATED row. render.c:356-363 takes `baserow = (z / 0x2000) >> 3`, which is `z >> 16` — the integer row the SIMULATION is on — and draws baserow+7 down to baserow-2 from it. Carrying the row forward let `floori()` cross into the next row up to a whole tick early, so a row of geometry appeared, and the near-row cover materials flipped, before the original does either. The camera still follows the interpolated row; only the discrete window decision moved. (b) The port drew road above the reference's horizon bound. The DOS viewport starts at row 32, but no band record ever reaches above row 34 — checked across a run, rows 32 and 33 are the world picture and nothing else at every tick, while rows 34+ carry road. This engine's camera has no such limit, so a tall block a few rows ahead projected its top into the sky and read as arriving out of nowhere. `SkyRoads.VIEW_TOP` is 34, and the world picture's own top rows are redrawn over the 3D. Evidence `docs/parity/z4_horizon_bound.png`. |
> | 30 | **BOTH HALVES FIXED 2026-08-30** — this entry described two symptoms and both had the same underlying cause, an opaque DOS framebuffer the port was letting things show through. 30a (the "chunky blue rectangles", which were not stars) is closed in the #30a row above; 30b (the dashboard speckle, which was not confined to the corners) is closed in #34. Kept for the audit trail: the original wording is what a wrong diagnosis looks like. |
> | 32 | **FIXED 2026-08-30 (STAGE Z1, user report: "when going into the tunnel, the player is being rendered over the tunnel")** — render.c:361-396 composes the ship's OWN grid row in two passes, "pre-ship" (dirbase 0x210) and "post-ship" (0x240), with the sprite between them. Phase 0's post-ship directory is empty, which is why it looked like a duplicate of dr7 and was never modelled; phases 1-7 are NOT empty, and the cut between the two is the fixed screen line y200 = 102, i.e. 235.636 / (102 - 9.569) = 2.550 = the ship's own depth. So geometry NEARER than the ship paints over it even inside the ship's own row. The port drew that row wholly before the sprite, so the arch of a tunnel the ship had just entered never covered it. Fixed by drawing the ship's row twice through `SkyRoadsCamera.CLIP_FAR` / `CLIP_NEAR` materials (a fragment discard either side of `SHIP_SPLIT_DEPTH`) — the sprite still never depth-tests, so §8.2 #1 and STAGE X are untouched. Tripwires: `test_occlusion.gd` now asserts the ship survives mid-row on open road but is fully covered half a row into a mouth. Evidence `docs/parity/z1_tunnel_entry.png`. |
> | 33 | **FIXED 2026-08-30 (STAGE Z1, user report: "the depth rendering is not enough")** — two separate causes. (a) Geometry nibble 5 (`compose_tun_high`) is not a bored block: it seeks kind 4 and paints the same six arch records a plain tunnel does, then puts a block tier on top through kind 5. The port drew a solid full block, so road 2's roadside tunnels at rows 80-83 read as grey walls; and its lower SIDE face, which the reference emits but then paints the arch over, won on depth and buried the arch. (b) `GameLoop.view_row/x/y` interpolated from the PREVIOUS tick toward the current one, so the presented world was a whole tick old whenever the accumulator had just fired — measured on the user's road-2 recording, the road's near edge sat 11 screen rows too high and the strip of backdrop under it was twice as deep as the reference's. Both fixed; frame-vs-frame geometry mismatch on road 2 across eleven ticks fell from 8.2% to 6.5%, with the rest thin one-pixel edges. Evidence `docs/parity/z1_tunhigh_arch.png`, `docs/parity/z1_road2_after.png`. |
> | 31 | **PARTIALLY FIXED 2026-08-30 (user report: "tunnel not properly rendered, ship visible through it")** — `_tunnel` rewritten to the DOS optics: nested ring FACES per row (no roof surface, no bore tube — the camera sits above the arch and a roof hid the road beyond; a tube showed as grey box tops), arch gradient re-anchored to the measured radial records (k70..73 → palette 69/68/69/70 L, +1 R), mouth = arch arc + wall 67 + rim 66. Ship-inside-tunnel occlusion comes from the cover pass painting nearer rings over the sprite. RESIDUE for the next pass: the rings still read stepped/tiered vs the C engine's smooth cone on road 2 (`scratchpad parity/u2c_t0260.png`), and there is no automated inside-a-tunnel occlusion scenario yet. See FIXPLAN STAGE Z1. **COMPLETED 2026-08-30 (STAGE Z1).** The stepped look was the PROFILE, not the ring structure: `_tunnel` was extruding SkyRoads.TUN_INNER/TUN_OUTER, which are the COLLISION tables and are nearly flat-topped right across the lane, so every ring came out a rectangle and rectangles stack into a ziggurat. The arch the original DRAWS is a separate, softer shape — a 47x19 px vault over a 41x16 px bore — decoded from the mouth's rim records with `tools/dump_bands.c archlines` and re-confirmed by a coordinate descent that re-fits both curves against the decoded mask and lands back on the same numbers. It is emitted as swept surfaces (outer vault, bore interior, mouth ring), because each DOS record covers its whole band from the row's far edge to its near one: emitting flat rings at the near edge alone makes an off-centre column's rings drift toward the vanishing point and render as separate arches with gaps (parity IoU 0.41 vs 0.91 for the swept surfaces). Residue: the four quarter bands are area-matched to the records rather than derived, so the shading is a shade cooler than the reference's. |

CRIT
1. **Ship under-occlusion band.** Sprite is depth-tested `DEPTH_BIAS = 0.95`
   rows nearer than the ship (`ShipSprite.gd:40,138`), so any block front
   between 2.585 and 3.535 rows from the camera — the final ~half-row of every
   approach — draws BEHIND the sprite. DOS draws that content over the ship
   (`render.c:365-395`, renderer.md §3 step 4). Reads as "I'm inside the
   wall / it didn't collide". Likely THE reported bug.

   **STILL OPEN — FIXPLAN T14 attempted 2026-08-30, measured, reverted.**
   `DEPTH_BIAS = 0.0` does not work, and no constant does. Measured with
   `test_occlusion.gd` (640x480, wall rows 9..10, ship row 11):

   | DEPTH_BIAS | ship px behind a wall | ship px on open road |
   |---|---|---|
   | 0.00 | 0 | **0** |
   | 0.05 … 0.70 | 0 | **0** |
   | 0.90 | 0 | 136 |
   | 0.95 (shipped) | 0 | 152 |
   | 1.10 | 0 | 152 |

   The ship renders NOTHING below 0.90: its own row's nearer neighbour, grid
   row `baserow-1`, spans 2.535..3.535 from the camera and covers every
   below-deck-line pixel of the sprite. So the "true depth reproduces the DOS
   order" argument is wrong for a single depth-tested quad — DOS gets both
   behaviours because it draws row `baserow-1` in band `dr=8`, i.e. AFTER the
   ship, and one depth value cannot be both nearer and farther than the same
   floor slab.

   T14 also prescribed a third test scenario (ship row 10.9, wall rows
   11..12) asserting 0 ship pixels. That scenario is not a defect: the wall
   is AHEAD of the ship, 3.635..5.635 from the camera — always farther than
   the sprite, so it cannot occlude by depth at any bias — and
   `render.c:365-368` draws the row ahead in band `dr=6`, BEFORE the ship at
   `dr=7`, so the original draws the ship over it too. Measured, that check's
   number is identical to the open-road number at every bias (0/0, 136/136,
   152/152): it is the same measurement, not a second one. The check was
   dropped; the parameterised `_count_ship_pixels` helper it needed was kept.

   **The real fix is structural, not a constant.** The ship must be drawn
   between its own row's geometry and the geometry of the rows nearer than
   it, which is what `render.c:361-396` does. That needs the per-row mesh
   split of FIXPLAN T18 (one mesh pair per grid row) plus an explicit draw
   order with the ship injected at row `baserow`. Do T18 first, then revisit
   this — at that point `DEPTH_BIAS` can go to 0.0 and the split floor/solid
   materials and their `render_priority = -10` can go away with it.

MAJ
2. Block face colours swapped: port paints top=nibble/62, front=63; DOS
   patches the nibble (default 61) into the FRONT, top is always 62, side
   63 left / 64 right. `RoadMesh.gd:132-145` vs `render.c:154-171`.
3. Right-half colour variants lost: side edges 31..45 left / 46..60 right,
   block side 63/64, arch gradient order mirrored. `RoadMesh.gd:18,102,
   110-115,153-155` vs `render.c` sr_quad (≈:90), renderer.md §5.1.
4. No 10-row draw window: DOS composes rows pos>>3+7 … pos>>3−2 only (road
   pops in at the horizon, never above y=32); port shows the whole road
   converging at the principal point. `RoadMesh.gd:41-60` vs
   `render.c:361-374`.
5. Bored blocks (shapes 3/5) faked as two flanks + rectangular gap: no arch,
   no entrance-interior colour 65, no split-top records.
   `RoadMesh.gd:139-143` vs `render.c:173-190,229-251`.
6. Tunnel (shape 1): inner-rim colour 66 records and body/exterior arch
   records omitted; gradient only approximated on the top face.
   `RoadMesh.gd:170-200` vs `render.c:213-227`.
7. Pause (P) missing entirely — key 11 of the original map.
   `game.c:298-311`; port has no binding (`Controls.gd:20-30`).
8. No audio at all: `pending_sfx` produced (`SkyRoadsPlay.gd:299-305`, id+1,
   0=none) but zero consumers; no music; sound_off setting inert.
   Full wiring table in §8.4.
9. Intro/ANIM sequence missing though fully exported. `game.c:17-29,170-194`.
10. Wrong menu on return: road-complete dismissal and in-game ESC both land
    on MAIN; DOS goes to GOMENU (road select), MAIN only after "The End" or
    the demo. `Main.gd:331-334,461` vs `game.c:312-315,359-364`.
11. Attract demo exits only on ESC; DOS exits on any key. `Main.gd:330-334`
    vs `game.c:293-296`.
12. Control-scheme radio (kbd/joy/mouse) saved but never read; joystick and
    mouse input don't exist. Diverges from the EXE (the C port is also
    keyboard-only). `Menu.gd:244-247`, `gameloop.md §10` fn_074c.

MIN
13. No 36-tick palette fades on any transition, including death→restart
    (instant cut). `game.c:86-92,417-432`, `FADE_TICKS` exported and unused.
14. Menu node recreated per open, so main_sel/go_sel/set_sel/help_page reset;
    DOS keeps them all session. `Main.gd:109-119`.
15. GOMENU selection is a white 35%-alpha rect; DOS brightens name-cell
    pixels ≥0x63 by remapping to 240+(p&7). `Menu.gd:166-170` vs
    `game.c:147-155`.
16. SETMENU draws all 10 overlays + invented white cursor; DOS blits exactly
    ONE overlay, picts[1+sel]. `Menu.gd:128-137,171-183` vs `game.c:256-262`.
17. Warning lamps: solid colour-100 fill; EXE colour-swaps lamp pixels
    0x63↔0x64. And the EXE fires warning beep sfx 3 once per on-phase —
    absent (hud.c lacks it too; EXE cite `gameloop.md §11 0x13eb`).
    `Dashboard.gd:133-144`.
18. Progress bar columns fixed 5 px; hud.c probes the pristine art per column
    (y=143 up while colour equal, floor y=138), paints 0x60.
    `Dashboard.gd:97-109` vs `hud.c:98-107`.
19. RoadEnd text colour hardcoded (0.86,0.86,0.86); palette entry 99 is
    (219,227,227). `RoadEnd.gd:23`.
20. GameLoop: MAX_CATCHUP_TICKS=8 + accumulator clamp cause time dilation
    under load (DOS catches up unbounded), and `_alpha` can reach 8.0,
    extrapolating the ship visually. `GameLoop.gd:17,84-103`.
21. Ship tilt frame uses simulated `play.x` while position uses interpolated
    `view_x` — frame/position can disagree one tilt class for a frame.
    `ShipSprite.gd:125` vs `:166-168`.
22. Floor edge conditions test whole tile code ==0 instead of floor nibble
    ==0, and port draws outer side faces DOS never emits.
    `RoadMesh.gd:107-115` vs `render.c:139-152`.
23. Shapes 6..15: port draws a floor slab if the surface nibble is set; DOS
    dispatches them to ret — draws nothing. `RoadMesh.gd:91-115` vs
    `render.c:253-264`.
24. Invented 0.08-unit floor front lip; high blocks lack the lower/upper tier
    seam. `RoadMesh.gd:109,148-155` vs `render.c:192-211`.
25. Shadow is a 0.586× multiply of everything beneath (DOS remaps floor
    1..15→46..60 and block-side 0x3D→0x40 only — block tops/backdrop never
    darken), and can darken the ship's own lower rows at clearance<8.
    `ShipSprite.gd:59-69,100-109` vs `render.c:292-311`.
26. Solved routes exist only for road 1 (road 30 = probe); `--replay` for
    2..29 warns and exits to menu.
27. Dead data staleness: `levels/roads.json`, `tile_semantics.json`,
    `palettes/*.png` (31), `sprites/atlas.json`, `gfx/intro_1..9.png`,
    `gfx/anim/*` (221+json), `music/*` (15 json), `audio/*` (6 wav),
    `routes/routes.json` all unreferenced; orphan `godot/tests/dbg_*.gd.uid`
    files whose scripts don't exist.

### 8.3 Confirmed authentic / correct (do not "fix")

Menu tree + navigation rules exact; cfg 66-byte file byte-compatible with DOS
saves incl. checksum; no progress gating, no scoring, no road-name/time HUD in
the original; dashboard gauge arithmetic exact incl. hidden autopilot delta;
demo attract wiring (10 s idle, z/0x666 indexing) exact; ship frame math
14+9·tilt+3·pitch+flame with all clamps exact; deck line 91.27 vs 91.2;
edge-support and neighbour-lane probes authentic (§1.1 #3/#4). The renderer.md
errors listed in §3 were correctly NOT propagated into the port.

### 8.4 Audio wiring table (trigger → id → where)

Producer already in place: `SkyRoadsPlay.gd:299-305` sets `pending_sfx = id+1`
(0 = none); consume and clear it from the shell each tick like
`game.c:320-323`. Single voice; a new effect replaces the current
(`audio.c:260-272`).

| trigger | id | port trigger site | C ref |
|---|---|---|---|
| burning tile / wall hit ≥0xe38 | 0 explosion | SkyRoadsPlay.gd:332,452 | play.c:299-302,456-462 |
| hard landing bounce | 1 bounce_thud | SkyRoadsPlay.gd:390-391 | play.c:370-373 |
| corner nudge / slow wall bump | 2 bump_scrape | SkyRoadsPlay.gd:442,446,456 | play.c:444,448,464-467 |
| empty-tank lamp on-phase (once per phase) | 3 warning_beep | Dashboard blink, Dashboard.gd:133-141 | EXE only: gameloop.md §11 0x13eb |
| supplies tile refill | 4 supplies_refill | SkyRoadsPlay.gd:320-321 | play.c:284-288 |
| intro tick 24 | INTRO.SND voice | (Intro.gd, new) | game.c:179-180 |
| main menu / intro | song 0 | menu screen enter | game.c:74 |
| road select | song 1 | GO screen enter | game.c:78 |
| road start (not demo) | song 2+rand%12, no repeat | _begin() | game.c:52-58 |
| sound_off | gates all + stops current song | settings commit | audio_misc.md §0/§5 |

Songs are OPL2 event streams (`data/music/song_NN.json`, 180 Hz ticks), NOT
audio — they need an offline render (§9 stage B). SFX wavs + intro_voice.wav
exist and are already Godot-imported.

---

## 9. Fix plan (ordered, for whoever picks this up)

> **Expanded into exact, executable edits in `docs/FIXPLAN.md` (2026-08-30). Work from that file; this section is the condensed rationale.**

State when this plan was written: `AudioMgr.gd` and `Intro.gd` are **written
and parse but are wired to nothing** — no other file references them yet.
Two data-generation tasks died with their session and must be redone (stage
B). Everything else is untouched.

### Stage A — shell flow (Main.gd, Menu.gd, GameLoop.gd, Controls.gd)

1. `Controls.gd`: add `"sr_pause": [KEY_P]` to MAP.
2. `GameLoop.gd`: add `var paused := false`, first line of `_process`:
   `if not running or paused: return`. Raise MAX_CATCHUP_TICKS to 36; after
   the loop clamp `_acc = mini(_acc, per_tick)` so `_alpha` ≤ 1.0 (fixes
   both #20 defects).
3. `Main.gd` pause: in the `_in_game` input branch — if paused: ESC →
   unpause + fade to GO menu, any other key → unpause; else KEY_P (not in
   demo/replay) → `_paused = true; _loop.paused = true`. DOS resumes on ANY
   key, including P (game.c:299-310).
4. Destinations: ESC in game → GOMENU; RoadEnd dismissed → GOMENU, or MAIN
   when final; demo exit (any key, not just ESC) and demo natural end → MAIN.
   Give `_open_menu(screen := -1)` an override, keep a `_menu_state` dict in
   Main captured at `_teardown` and restored on open (fixes #10/#11/#14).
   `_next_road` logic stays and forces screen GO.
5. Fades: one `CanvasLayer` (layer 100) holding a black full-screen
   ColorRect. `_fade_transition(cb)`: 1.0 s alpha→1, cb.call(), 1.0 s
   alpha→0 (36 ticks each way, game.c:86-92). Block `_unhandled_input`
   while fading; set `_loop.paused = true` during fade-out. Route every
   transition through it: menu screen changes (Menu needs a `fader`
   callback for its `screen =` assignments — help page flips do NOT fade,
   game.c:267-271), road start, death restart, ESC out, roadend dismiss,
   intro→menu. Cmdline starts (`--road/--replay/--shots/--menu-shot`) must
   BYPASS fades or every automated test slows and menu captures break.
6. Audio wiring: Main creates `AudioMgr`, sets `.cfg`. In `_on_tick`:
   `if play.pending_sfx: _audio.sfx(play.pending_sfx - 1);
   play.pending_sfx = 0` and `_audio.warn_tick(play)`. Song hooks: poll
   `_menu.screen` changes in `_process` — on MAIN enter `want_song(0)`, on
   GO enter `want_song(1)`, SETTINGS/HELP no change; in `_begin` when not
   `_replaying`: `gameplay_song(index)`. Demo keeps the current song
   (game.c start_road skips the RNG for demo).
7. Intro wiring: boot with no cmdline args → `Intro` (give it `.audio`),
   `done` → fade to MAIN menu; route keys to `_intro.handle_input` in
   `_unhandled_input`; `want_song(0)` at boot. Verify `--menu-shot` and
   `--road` paths still skip it.

### Stage B — data generation (redo; both died at session limit)

1. **Music render.** Write `tools/render_music.c` (repo-root tools/, treat
   `skyroads-port/` read-only): parse retail `MUZAX.LZS` with
   `skyroads-port/src/core/audio.c`'s logic + `lzs.c`, synthesize through
   `skyroads-port/tools/opl3.c`, emit `godot/data/music/song_00..13.wav`
   (16-bit 44100 mono, intro + one full loop body) plus `music_meta.json`
   `[{index, file, loop_begin_sample, length_samples, mix_rate, channels}]`.
   `AudioMgr.gd` already reads exactly those names/fields. Retail data:
   `<scratch>/`
   (do NOT copy .LZS into the repo). Cross-check durations vs
   `song_NN.json` "seconds". Then run a headless import so the wavs get
   `.import` files (`godot --headless --path godot --import` or the
   verify.sh harness's import step).
2. **GOMENU index export.** `analysis/export_gomenu_index.py` exists as an
   UNFINISHED draft from the dead agent — finish or rewrite: emit
   `godot/data/gfx/gomenu_index.json` = {width, height, pixels: base64 raw
   indices, palette: 256×[r,g,b] after applying GOMENU.LZS sections onto a
   zeroed palette, 6→8-bit via (v<<2)|(v>>4)}. Must round-trip pixel-exact
   against `gomenu_0.png`. Then replace the white rect (Menu.gd:166-170)
   with the DOS remap: pixels ≥0x63 → 240+(p&7) over the 48×9 cell.
3. **SETMENU check.** Look at `setmenu_0..10.png` + gfx.json offsets and
   determine what base + picts[1+sel] alone renders (game.c:256-262); then
   make the settings screen match DOS exactly and drop the invented cursor
   rect (#16).

### Stage C — renderer (RoadMesh.gd, ShipSprite.gd)

1. **The CRIT bias fix first.** Try `DEPTH_BIAS = 0` (true depth): nearer
   floor occluding the ship's below-deck pixels is DOS-correct behaviour.
   The §2.8 "floor swallowing the sprite" regression risk is why the bias
   exists — if it reappears, find the minimal bias (~0.05, enough to clear
   the coplanar own-row deck) instead of 0.95. Extend `test_occlusion.gd`
   with a THIRD case: a wall NEARER than the ship must fully hide it (0 px)
   — the currently untested direction, and the one the bias broke.
2. Face colours + half variants (#2, #3): follow `render.c:154-171` and
   sr_quad; vertex-colour lookups keyed by (record kind, screen half).
3. Edge conditions #22, shapes 6..15 #23, lip/tier #24 — small, mechanical,
   each cites its render.c lines.
4. Arch/bore/tunnel records #5/#6 from `render.c compose_tun_low/high/
   compose_tunnel:173-251` — real geometry, colours 65/66, split tops.
5. 10-row window #4: per-row visibility toggled from `view_row()` (build
   per-row surfaces or MeshInstances; render.c:361-374).
6. Ship #21 (tilt from view_x) and #25 (shadow: only darken floor + block
   sides; never the ship) last.
   After each renderer change: `tools/verify.sh` windowed pass + a manual
   road-1 run with the C overlay off (§1.2).

### Stage D — HUD/polish

Progress-bar art probe + lamp 0x63↔0x64 pixel swap (precompute masks from
`dashbrd_0.png` matched against `game_palette.json` entries 99/100 in the
WARN rects), RoadEnd colour from palette 99, dead-data cleanup (#27 — delete
or wire, and remove orphan dbg uid files).

### Explicitly out of scope / decisions needed

- Joystick/mouse (#12): EXE-authentic but the C reference never implemented
  it either. Decide whether to implement (Godot makes it cheap) or drop the
  radio to keyboard-only.
- Routes for roads 2..29 (#26): solver compute, not a code bug.
- Road 30 solver (§ In flight): unchanged, known hard.

### Traps for the next session (beyond STATUS.md's standing list)

- Do not touch `SkyRoadsPlay.gd` — re-verified bit-exact, incl. death paths.
- New wavs are invisible to `load()` until an import pass runs.
- `AudioMgr`/`Intro` guard every asset load with `ResourceLoader.exists` —
  keep that, the game must boot with no music rendered.
- Fades must not run in any automated path or the screenshot/replay suites
  hang or slow 2 s per transition.
- Never copy retail `.LZS`/`.SND` into the repo; derived exports only.
