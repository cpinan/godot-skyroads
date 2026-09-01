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

### 1.1 Holes and block collisions still feel wrong · NOT REPRODUCIBLE (2026-09-01)

The reporter has said this after each of the fixes in §2. It is the reason
this document exists.

**2026-09-01: the reporter played the current build and could not reproduce
it.** That is the live trace this section had been blocked on since the
beginning. Five recordings were taken across roads 2 and 4 — 2,486 ticks of
real play, ending in two wall crashes and three falls — and every one of them
replays **bit-identically through the C engine, the Python model and
GDScript**: 2,515 ticks x 24 state fields, no divergence anywhere. They are
kept as `tests/fixtures/traces/` so the evidence outlives the session.

That does not prove the original reports were wrong; it proves they do not
happen now. The most likely explanation is candidate 1 below, which this
section has always said to re-test first: §2.1 left the controls unbound for
part of the reporting window, and a ship that only does what gravity does
would produce exactly this complaint about holes and collisions. The remaining
candidates stay written down because "cannot reproduce" is not "cannot
happen" — if it is ever felt again, take a recording at the moment and this
section has somewhere to put it.

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
| `gameloop.md` §13 | `fn_1067` divisors ds:0x308 `{1000,100,10,1}` | **ascending** `{1,10,100,1000,10000,0x8000}` — read out of the EXE's data segment (paragraph 0x66E). si=0 is the ONES digit, drawn rightmost. The C reference has this right; the note does not. Found closing #41. |

---

## 4. MISSING — not implemented

Rewritten 2026-08-30: STAGE Z closed most of what this table used to list.
What is left is one solver failure and four modelling approximations, each of
which is a known simplification rather than an oversight.

| | notes |
|---|---|
| **Routes for 19 of 30 roads** | #26. The solver finishes 19 (1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 14, 15, 17, 21, 22, 23, 24, 25, 26) after the 2026-08-31 re-run: `--beam 1024 --hold 1 --max-ticks 16000` won road 4, and the `--sub-column 9` retry pass won 6, 8 and 25. The remaining eleven (10, 12, 13, 16, 18, 19, 20, 27, 28, 29, 30 — road 30 is 200 rows of stepping stones) still defeat both passes. Compute, not code. Unsolved roads are still covered field-by-field by the suites and by a deterministic probe trace |
| **Split-top tunnel records** | #5. The top face of a bored block stays one quad; the original emits it in halves |
| **Block centre-column colour** | #2/#3. A per-cell colour cannot split mid-column, so the centre column takes the left half's colour |
| **Arch quarter-band shading** | #31 residue. The four bands are area-matched to the decoded records rather than derived, so the vault reads a shade cooler than the reference's |
| **Shadow palette masking** | #25. The original darkens only palette 1..15 and 0x3D; the port approximates that with a stencil multiply |

Deliberate deviations from the original, as opposed to gaps — there are three,
and all three are here so nobody has to find them by reading diffs:

| | why |
|---|---|
| **Absent joystick falls back to the keyboard** | #12. The original leaves the player unable to steer. `PlayerInput.effective_device` |
| **Readable GRAV-O-METER** | #41. The retail game paints the hundreds digit tan on tan; the port extends the black window under it. Off for every parity capture |
| **Touch controls, and the settings screen's hidden control row** | §10. New; the original has no touch device. Off unless the build is mobile or `--touch` is passed |

---

## 5. Test coverage, and where it is weak

`godot/verify.sh` — 478 checks in 16 suites plus a parse pass and an end-to-end replay of every road that has a winning route, currently green:

| suite | what it covers |
|---|---|
| parse pass | every script, referenced or not |
| `test_occlusion` | windowed; ship hidden behind a wall AND drawn on open road |
| `test_data` | level shape, tile helpers, camera credibility |
| `test_geometry` | drawn road vs collision cell-for-cell; lane width 46 px; block heights |
| `test_hud` | gauge arithmetic incl. the hidden autopilot delta |
| `test_input` | full key truth table; actions have keys bound; the touch device override |
| `test_touch` | the on-screen stick's geometry: screen halves, floating origin, two thumbs at once |
| `test_intro` | the intro's phases, durations, palette pairs and where it hands off |
| `touch_shell` | windowed; a synthetic tap through the real input pipeline into the real Main.tscn |
| `test_physics` | 23-field golden traces vs the reference model |
| `test_timing` | same elapsed time at 15/30/60/144 fps |
| `test_menu` | MenuModel diffed against the C engine's own menu traces, plus the phone-only settings clamp |
| `test_audio`, `test_launch_options` | the audio wiring table; every command-line flag including the malformed ones |
| `render_dashboard` | the dashboard band vs C reference frames; JUMP-O-MASTER swap; GRAV-O-METER window (#41) |
| `render_menu` | every menu screen vs the C engine, plus touch navigation and the dimmed control row |
| `render_backdrop` | the backdrop renders its own source art exactly (#30a) |
| end-to-end | replays every solved route through the real scene |

**Known weaknesses:**

- Pixel coverage is no longer "almost nothing" — `render_dashboard`,
  `render_menu`, `render_backdrop` and `test_occlusion` all assert on pixels —
  but it is still thin where it matters most: there is no golden for the ROAD
  itself, only for the bands around it. Road parity is measured by hand
  against `tools/replay_frames.c` output and then written down, which means a
  regression in the road surface is caught by a person noticing, not by
  `verify.sh`.
- Golden traces replay routes that **succeed**, so they never exercise a
  crash, a fall or an empty tank. The three-way differential covers those, but
  it is opt-in (`THREEWAY=1`).
- No test compares against the **original binary** — only against the C port.
  If `play.c` diverges from DOS, the whole stack reproduces it faithfully.
  `DEMO.REC` is the one real check and it passes: 1775 ticks, matching the
  figure `gameloop.md` records from instrumented-original telemetry.
  Closing #41 showed how to attack this without DOSBox when a specific
  question needs answering: disassemble the routine out of the retail EXE
  (`capstone`, MZ header gives the code offset) and decode the retail asset
  it draws into (`skyroads-port/tools/lzs.py`). That settled a two-way
  disagreement in an afternoon and found an error in the RE notes on the way
  (§3, the divisor table). It is not a substitute for a running original, but
  it is a much cheaper first move than one.
- **Nothing drives the touch layer end to end.** `render_menu` covers the
  taps that navigate the menus and `test_input` covers the mapping, but the
  in-game thumbstick has never been dragged by a real finger, and neither has
  the pause box. Same standing as the joystick and mouse devices (§8.2 #12):
  implemented, unit-tested, never held.

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
> | 41 | **CLOSED 2026-08-30 — AUTHENTIC, and worked around anyway. No DOSBox run was needed: the retail `SKYROADS.EXE` and the retail `DASHBRD.LZS` settle it between them.** Disassembling the binary (`capstone`, code segment at file offset 512): `fn_2b21 @0x2ba7` pushes 4, `([0x456e]-3)*100`, `0x9c`, `0x60` and calls `fn_1067`; `fn_1067 @0x1091-0x10cd` takes digit si as `(value / ds:0x308[si]) % 10` with the divisor table **ascending** `{1,10,100,1000,10000,0x8000}` and draws it at `x + (ndigits-1-si)*5`, i.e. slots 96/101/106/111; it stops at `0x1080` once the remaining value is 0 and si>0. `fn_0fc6 @0xfd6` sets the two stencil colours to **0x61 and 0x62** in VGA mode. Every one of those matches `hud.c` and matches the port. Then decoding `DASHBRD.LZS` directly (`skyroads-port/tools/lzs.py`) shows the readout window — the palette-index-0 pixels the dashboard stamp leaves black — covers **exactly the two rightmost slots, x 106..109 and 111..114**, with the digit-0 stencil already painted into them; slots 96 and 101 are plain panel, and the panel is palette 0x61, the same index `draw_digit` paints strokes in. So a digit left of x=106 is tan on tan in the 1993 game too, and since `(g-3)*100` always ends in "00" the visible half of the GRAV-O-METER reads "00" on every road ever shipped. It is Bluemoon's bug, not the port's. **Kept reproducible and worked around:** `Dashboard.authentic_gravity_window` (default false) extends the art's own black window under the slots it does not cover, so gravity 8 now reads 500; `Main` sets it true whenever `LaunchOptions.is_parity_capture()`, so every measured frame is still the authentic one. This is the only deliberate deviation in the dashboard. Tripwire: `render_dashboard.gd` `_gravity_readout`, which asserts 0 dark pixels in the hundreds cell authentic and >=6 readable. |
> | 42 | **NOT A DEFECT — resolved 2026-08-30, user-reported twice ("jump-o-master does not show anything", then "appears IDLE even when running or jumping").** The panel is not a lamp, it is a WORD, and the port swaps it correctly: decoding the two 26x5 stencils shows state 0 spells **IDLE** and state 1 spells **IN USE**, and rendering the dashboard in both states changes 194 pixels. What the report actually exposes is a naming mismatch, not a bug: JUMP-O-MASTER is the LANDING-ASSIST indicator, not a jump indicator. It reads IN USE only while the assist is actively correcting the ship's speed to make a landing — 28 of road 1's 462 ticks, about 6%, and never for long — so a player jumping normally will almost always see IDLE. Pinned by `render_dashboard.gd`, which asserts the two states differ, so if the swap ever breaks it fails loudly instead of silently showing one word forever. Still worth confirming against the real DOS binary that the assist engages as rarely there. |
> | 40 | **DONE 2026-08-30 (user decision at STAGE Z7)** — the music was shipping as 125 MB of 44.1 kHz mono wav, in a 283 MB tree. Re-encoded to Ogg Vorbis q4: **17 MB, 7.4x smaller, 108 MB saved**, every file verified to decode to the same duration at 85-107 kbps. 44.1 kHz was kept deliberately — only 1.9% of the OPL renders' energy sits above 11 kHz, but it is real (the rhythm channels), and this is a port that measures things rather than assuming them inaudible. `AudioStreamOggVorbis` loops itself from `loop_offset`, so `AudioMgr._on_song_finished` and its end-of-stream seam are gone; `music_meta.json` still supplies the loop point. Verified still audible after the change: CoreAudio, master bus -3.2 dB. |
> | 27 | orphan `dbg_*.gd.uid` deleted (T21). The listed dead data files remain on disk, deliberately unwired; delete freely if the repo needs the space. |
> | 28 | **FOUND + FIXED 2026-08-30 (STAGE Y)** — the generated camera constants were wrong: BEHIND_ROWS a full row too big (3.535 vs the true 2.550), and DOS's horizontal mapping is a separate straight-line cone through y=32 that no pinhole reproduces. This was "the collisions are offset": world drawn misaligned against the DOS-exact ship blit at every depth. Fixed in `SkyRoadsCamera.gd` (new constants + `make_dos_material` vertex-shader warp on every road/overlay material, `dos_x_scale` for CPU-side label anchors). Derivation in the file header; measurement tools `tools/dump_bands.c`, `tools/replay_frames.c`; evidence in §1. The old §1.1 candidate #2 ("sprite vs collision vertically, diverges ~20% at altitude") was this same defect. |
> | 29 | **CLOSED 2026-08-30 (STAGE Z3) — the premise was wrong, and the symptom is fixed.** There is no per-row or near-field darkening anywhere in the DOS renderer. Proven directly: drive the C engine over a synthetic road whose every tile is the same code (0x0003) and read the palette index down the middle of the screen — it is index 3 at every distance from the horizon to the deck line, with no remap. Nothing in render.c or tables.c applies one either; `fill_record` resolves a colour through `sr_quad[k][half]` and half is the screen SIDE, not the depth. What the evidence composite actually showed was the block top/front colour swap (#24): road 26's near geometry is a big block, and the port was painting its front with the top's colour. Fixed in STAGE Z2; road 26's shading now tracks the reference at every sampled tick. Evidence `docs/parity/z3_road26_before_after.png`. |
> | 29b | **REDUCED 2026-08-31 — see §12.8.** Two thirds of the recorded gap was the metric: road 26's palette holds near-duplicate greys 4 RGB steps apart, so index-space comparison counts invisible differences. Measured by RGB it is 10.1% / 12.9% / 7.3%, about the same as road 2 rather than three times worse. What remains is real and still open. Original entry follows. OPEN, small, found while closing #29: road 26 still differs on ~17% of its solid road pixels, and the confusion is dominated by C index 3 -> port index 1 — two dark greys ONE PALETTE STEP APART, i.e. the port painting an adjacent ROW's colour. Road 26 is the one level that makes this visible, because its consecutive rows are a colour ramp (rows 31-40 run 15,15,3 / 15,3,4 / 15,4,5 / …), so a sub-tick difference in presented depth repaints whole bands from the neighbouring row. It is the residue of comparing an interpolating renderer against a tick-exact one, not a drawing fault. **Three fixes were tried and all measured WORSE — do not repeat them:** presenting the capture at alpha=0 (road 2: 6.5% -> 8.0%), stopping the catch-up loop on the scheduled tick so the shot is of that tick rather than tick N+k (-> 8.5%), and both together. The reference's frame for a tick corresponds to a moment this engine reaches PART-WAY through its own, so the interpolated, end-of-frame state is the closer match. Recorded in `Main._capture_pending`. |
> | 29c | **CLOSED 2026-08-31 — see §12.1.** The tier has no lower bound to derive: below it the original paints the kind-3 front, not the vault. Original entry follows. OPEN, small, found while closing #29: on a tun_high cell (geometry nibble 5) the masonry tier's front stops flat at half-block height while the reference's runs down onto the arch, leaving a sliver of the vault's outer surface showing — measured on an isolated tile as the tier ending 5 screen rows early at the bore's centre. Recipe: a synthetic road of 0x0003 with 0x053f at rows 20-23 column 3, driven with a held-accelerate route, compared at t=170/178. A per-slice fix bounding the tier front by ARCH_OUTER_PX closed it on the isolated tile but REGRESSED road 2 (t=640: 9.9% -> 16.7%), so it was reverted; the tier's true lower bound is not ARCH_OUTER_PX and has not been derived. |
> | 29-old | **CLOSED 2026-08-30 — same premise as #29, disproven by the same measurement.** This entry and #29 are one claim: that the C reference darkens near rows and the port does not. #29's direct test settled it — driving the C engine over a synthetic road of one tile code and reading the palette index down the middle of the screen gives index 3 at every distance, horizon to deck line, with no remap anywhere in `render.c` or `tables.c`. There is no near-field darkening to model, on road 26 or anywhere else. The darkness the composite showed was the block top/front colour swap (#24), fixed in STAGE Z2. Nothing to do; kept for the audit trail because "two entries, one wrong premise" is a shape that recurs. |
> | 34 | **FIXED 2026-08-30 (user report: "UI bugs in the player speed and UI")** — one root cause behind four symptoms. The DOS screen is a single opaque framebuffer: the world picture fills rows 0..137, the dashboard is STAMPED over rows 129..199 skipping its index-0 pixels, and the road is composed into rows 32..137 ONLY, so every transparent dashboard pixel below row 137 shows palette index 0, i.e. black. In the port the 3D viewport covers the whole window, so the live road bled through the dashboard art's transparent pixels — through the GRAV-O-METER digits, the JUMP-O-MASTER panel, the unlit side of the SPEEDOMETER and the bottom corners — and changed hue as the player drove between worlds. Fixed with an opaque black band behind the dashboard from row 138 down. Dashboard parity vs the C engine on the user's road-2 recording went from ~800 differing pixels per frame to **0 across every frame sampled**. This subsumes #30b, which was recorded as "corner speckle" but was the whole band. Tripwire: `tests/render_dashboard.gd` compares the band against C reference frames. |
> | 35 | **FIXED 2026-08-30 (user report: "also in game menu")** — same family. Every DOS menu begins with `sr_fb_clear(fb, 0)`, so index 0 is BLACK; the exports carry it as alpha 0 (INTRO.LZS alone has 15109 such pixels) and Godot's own grey clear colour showed through, mottling the main menu's night sky. Fixed with an opaque black ground behind every menu screen. |
> | 36 | **FIXED 2026-08-30** — the road-select completion pips drew as solid WHITE blocks instead of the original's small amber marks. Not a palette or export fault: `Menu._draw_overlay` called `load()` on the pip texture from INSIDE a `draw` handler, and a texture first loaded there renders as a plain white rectangle. Reproduced in isolation (the same texture preloaded draws correctly). Fixed by caching textures outside the draw pass. Road-select now matches the C engine **pixel for pixel**. |
> | 37 | **FIXED 2026-08-30, found by its own new test** — `LaunchOptions` (extracted from `Main._ready`): a flag needing a value treated the NEXT FLAG as its value, so `--shot-ticks --labels` parsed "--labels" as a tick list of one zero and silently dropped `--labels`. Every automated check in the repo reaches the game through these flags, so this broke harnesses rather than the game, and did it quietly. |
> | 39 | **CLOSED 2026-08-30 (STAGE Z6) — the framing defect is gone; the explosion pipeline is correct.** The task described the C engine drawing the road-16 mouth crash "small and framed INSIDE the ring" while the port drew the whole sprite over it. Both halves of that were the block-face colour swap (#24, fixed in Z2) plus the pre/post-ship draw order (#32, fixed in Z1): the "ring" is a block front, and with its colours swapped it read as a different shape entirely. Both engines now draw the same sprite in the same place, framed the same way. Three independent checks back it: the exported explosion art is BYTE-IDENTICAL to the reference's own CARS cells for all 14 frames (dumped straight from `sr_assets`); the sprite-index rule is the same expression (`expl_ctr / 3`, blank past 13); and `expl_ctr` traced tick by tick is identical in both engines (C reaches ctr=1 at its tick 57, the port at its tick 58, and the port's `play.tick` runs one ahead of the C loop index — same state, different label). Evidence `docs/parity/z6_explosion_framing.png`. |
> | 39b | **CLOSED 2026-08-31 by §12.3.** The cause was the capture photographing tick N+k; with `GameLoop.halt_ticks` pinning it, the road-16 crash reports `want=60 have=60 expl_ctr=3 sprite=1`, then 63/6/2, 69/12/4, 72/15/5 — exactly the 1/2/4/5 this entry says was called for. Note the original measurement method does NOT reproduce: counting the blast's pixels against the source sprites' sizes assumes it is drawn 1:1, and it is drawn scaled, so those counts are not a frame fingerprint. The state at capture is, and it is provably right. Original entry follows. OPEN, harness only, found while closing #39: a parity screenshot occasionally samples one ANIMATION frame stale. Measured on the road-16 crash by counting the blast's own pixels against the known sprite sizes — the port's frames came out at 231/115/67/272 px, i.e. sprites 1/2/3/5, where `expl_ctr` at capture time called for 1/2/**4**/5. Three of the four sampled ticks match the rule exactly and one is one frame behind, which makes it a property of WHEN the screenshot is taken relative to the tick loop, not of the game: `_capture_pending` runs after the frame's catch-up loop, so a frame that owes several ticks presents one of them and captures another. Same family as #29b, and the two fixes tried there (capture at alpha=0, break the loop on the scheduled tick) both made still-frame parity worse — so this is recorded rather than papered over. It does not affect gameplay; it affects the measuring instrument. |
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

> **RETRACTED 2026-08-30 — one claim in this section was wrong.** It used to
> read "the settings screen shows no current-state feedback at all, which is
> the original's own behaviour, not an omission here", sourced from
> `game.c:257-260` blitting exactly one overlay. The retail EXE does not agree:
> `fn_4ae2 @0x4ae2` loops all five items and calls `fn_4aaf(i + 5, mode)` with
> mode **1** when `i == [0x4526]` (the cfg's control device) or
> `i == [0x4528] + 3` (the cfg's sound flag), and **0xff** otherwise —
> and `fn_41e5`'s threshold blit (`0x41cb`: `p < 0x63` transparent,
> `0x63 <= p < threshold` erased back to the base picture, `p >= threshold`
> drawn) means mode 1 DRAWS an overlay and mode 0xff ERASES it. Overlays 5..9
> are the ORANGE set. So the original marks the active control device and the
> active sound setting in orange, permanently, and the white set 0..4 is the
> moving cursor on top of that. The C reference never implemented it, the
> goldens come from the C reference, and the port therefore passes a pixel
> test against a screen that is missing a feature. See §11.
>
> **RETRACTED 2026-08-30 (second pass) — "demo attract wiring (10 s idle …)
> exact" is wrong about the trigger.** The `z/0x666` indexing is right; the
> ten-second idle is not. The retail menus read keys with fn_5fad, a
> **blocking** `int 21h ah=7` (@0x5fad), so no menu can time out. The attract
> demo is reached from the INTRO: fn_4575 returns its abort flag (@0x4aa5),
> and main @0x0221 answers a zero — nobody touched anything — with
> `[0x9602] = 3` and road 0. See §11.11.

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

---

## 10. 2026-08-30 — mobile

New work, not a defect fix. The original has no touch device, so nothing here
is recovered from the EXE; what follows is the reasoning, so the next person
does not have to guess which parts were choices.

### What was added

| | where |
|---|---|
| Thumbstick + jump button + pause box | `scripts/TouchControls.gd` |
| `PlayerInput.Device.TOUCH` | `scripts/model/PlayerInput.gd` |
| Tap navigation on every menu screen | `scripts/Menu.gd` `_keys_for_tap` |
| Settings control row dimmed and unreachable | `MenuModel.touch_ui`, `settings_first_item()` |
| Android + iOS export presets | `export_presets.cfg` |
| Icons built from the game's own art | `tools/make_icons.py` → `data/branding/` |
| Landscape-either-way, GL Compatibility on mobile | `project.godot` |
| MIT for the code, with the derived assets carved out | `LICENSE` |

### Decisions worth knowing about

- **The simulation never learns a finger was involved.** `TouchControls.sample`
  returns `PlayerInput.from_axes(...)`, the same call the joystick and mouse
  devices make, so the three-way differential against the C engine is
  untouched by any of this.
- **`Device.TOUCH` is never persisted.** `skyroads.cfg` is the DOS save format
  and a 3 in its control word would not be a SkyRoads save. The platform picks
  TOUCH at runtime; the cfg keeps whatever 0..2 it had.
- **The hit areas are the screen halves, not the drawn circles.** The circles
  are a hint. A control you have to hit is a control you fight, and the stick's
  origin follows the thumb that starts it for the same reason.
- **The road list needs two taps.** Tap selects, a second tap on the same road
  starts it. Thirty 48x9 cells and an instant launch is a bad pairing.
- **Menu hit regions come from `gfx.json`**, i.e. from the original's own
  overlay picts, so they cannot drift away from the art. This also means a
  wrong lookup fails silently as "the menu ignores taps" — hence the tests in
  `render_menu.gd`.
- **`stretch/aspect` stays `keep`.** "expand" would show more world than DOS
  did and quietly invalidate every parity measurement in this file, on the one
  platform nobody is measuring.
- **`renderer/rendering_method.mobile="gl_compatibility"`.** Without the
  override Godot puts mobile on a different renderer than every measurement
  here was taken on.

### A trap found while doing it

Every texture `.import` in `data/` carried `detect_3d/compress_to=1`: on a
reimport, Godot may decide a texture is used in 3D and rewrite it to VRAM
compression. The ship and the road **are** 3D. A VRAM-compressed ship sprite
would break every pixel-parity number in this document without touching a line
of code, and enabling ETC2/ASTC for the Android export is exactly what makes
that compression available. All 374 of them are now pinned to
`detect_3d/compress_to=0`. If a new asset is exported, check that it lands the
same way.

### Not done

- **Never held.** The touch layer has never run on a phone. `--touch` drives it
  with the mouse on a desktop, which proves the wiring, not the ergonomics.
- **No signing.** The Android keystore and the iOS team id are deliberately
  absent from `export_presets.cfg`.
- **The package name `com.cpinan.skyroads` is a placeholder** and the app is
  named SkyRoads, which is Bluemoon's. Publishing under either is a decision
  nobody has made — see `LICENSE`, and note the repository is private on
  purpose.

---

## 11. 2026-08-30 — the port vs the retail EXE, not vs the C reference

Everything above this section was measured against `skyroads-port/`. This
section is the first pass measured against **`SKYROADS.EXE` itself**, decoded
with capstone (MZ header paragraph count x 16 is the code offset; the RE notes'
addresses are code-segment relative, data segment is paragraph 0x66E) and
against the retail `.LZS` files decoded with `skyroads-port/tools/lzs.py`.

Seven defects. **All seven were also present in the C reference**, which is why
no existing test could see them and why two of them were written down in this
document as "authentic". Every one is fixed.

| # | what the original does | what the port did |
|---|---|---|
| 11.1 | **Main menu carries the SkyRoads logo.** fn_4e36 @0x4f06 blits INTRO.LZS pict 1 (320x54 at y=32) over the title before any item box | drew the title and the boxes and nothing between them — the menu had no game name on it |
| 11.2 | **Settings screen marks the current setting.** fn_4ae2 @0x4ae2 walks all five items and calls fn_4aaf(i+5, mode) with mode 1 where `i` is the cfg's control device or its sound flag + 3, 0xff elsewhere; objects 5..9 are the ORANGE overlays | showed the white cursor only. §8.3 asserted this was authentic. It is not — **retracted there** |
| 11.3 | **The intro runs for another 23 s after the animation**: a 319-column two-way curtain wipes in the logo (@0x484a-0x48e3), it flashes white and settles (@0x4938-0x4950), then five credit plates fade in/hold/out at 50 ticks each (@0x49de-0x4a16). Plus a 36-tick fade-in on the title (@0x4749) | stopped at the end of the ANIM. `intro_1` and `intro_4..8` were exported and referenced by nothing |
| 11.4 | **Both menus play song 1.** fn_4e36 @0x4e3f and fn_5164 @0x5172 both `music_start(1)`; song 0 is the intro's alone (fn_4575 @0x4586) | played song 0 on the main menu, so the intro track ran over the menu and song 1 was only ever heard on the road select |
| 11.5 | **Help is two pages, each faded.** fn_4e12 @0x4e21 calls fn_4dac once, then again only if the key was not ESC; fn_4dac fades in 36 (@0x4dd8) and out 36 (@0x4ded) around its wait | paged through three screens with instant flips. `helpmenu_2` is art the 1993 game never shows |
| 11.6 | **"Road Completed" holds 27 ticks and moves on.** fn_2b21 @0x2c90 is `fn_443d(0x1b)`, a frame count with no key test — its abort flag was disarmed at 0x4a6f when the intro ended | waited for a keypress the original never asks for |
| 11.7 | **A key skips the intro's fades.** fn_4315 jumps to t=100 on `[0x54ac]`, set by fn_4137 on any key while armed by `[0xaf42]` — raised at 0x470d for the intro, cleared at 0x4a6f | froze input for the whole fade, so mashing a key through the intro did nothing |

### How the fades are reproduced without a palette

fn_4315 interpolates the DAC between two palettes of the same picture, and
`lerp(A[v], B[v], t)` per pixel is exactly "draw the A render, then the B
render over it at alpha t". So each cross-faded picture ships as two PNGs and
the fade is a `modulate`. `tools/export_intro_palettes.py` writes the A
renders and, as its own cross-check, re-renders B and compares it against the
already-shipped `intro_N.png` — all six match byte for byte, which is what
makes the pairing trustworthy. `test_intro.gd` asserts that flag stays true.

### Consequences for the test suite

- **The `menu_settings_*` goldens are C-engine frames and were missing 11.2.**
  Rather than compare against a reference known to be wrong, `render_menu.gd`
  now composites the retail orange picts onto the golden at their own PICT
  offsets before diffing — retail pixels, not the port's own output, so the
  test still measures against the original. Both settings screens are back to
  **0.000% differing**.
- **`menu_traces.txt`'s `help-pages-wrap` script came from the C engine and
  had three pages.** Corrected in place, with a `#` note in the fixture:
  regenerating that file from `tools/menu_trace.c` will silently reintroduce
  11.5.
- `menu_help_2` is still rendered and compared. It is unreachable in the game
  now, and the check is kept deliberately: it exercises the art pipeline on a
  screen nothing else covers.

### 11.8-11.11 — a second pass, over the road select and the attract loop

| # | the original | the port |
|---|---|---|
| 11.8 | **LEFT from the first column goes to road 1.** fn_5164 @0x52cb: `if sel >= 15 then sel -= 15 else sel = 0` | refused to move, from game.c's `if (LEFT && go_sel >= 15)` |
| 11.9 | **RIGHT from the second column goes to road 30.** @0x52e6 is an unconditional `sel += 15`, and the loop top @0x527f clamps `sel >= 30` to 29 | refused to move |
| 11.10 | **Only Enter confirms.** Every menu dispatches on the BIOS scancode and tests 0x0D, 0x1B and the four arrows — main @0x5037, road select @0x531b, settings @0x4d6c. The help screen is the exception: fn_4dac @0x4dfa tests only for ESC, so **any other key turns the page** | accepted space as confirm everywhere, and paged help on Enter alone |
| 11.11 | **The attract demo comes off the end of the INTRO, and the menus have no clock at all.** fn_5fad @0x5fad is a blocking `int 21h ah=7`. fn_4575 returns its abort flag (@0x4aa5): zero means untouched, and main @0x0229 answers with `[0x9602] = 3` and road 0. When that demo ends naturally main @0x0385 jumps back to the `fn_4575()` call — intro, demo, intro, demo. Only ESC (play-loop result 7, @0x037a) breaks out to the menu | started the demo after ten idle seconds on the main menu, ended it back at the menu, and exited it on any key |

11.11 also answers a question `docs/STATUS.md` had been carrying since STAGE
Z: **yes, the intro replays** — on the attract loop, and only there. Returning
to the menu never replays it, which is what the port already did.

### Consequences for the fixtures, again

`menu_traces.txt`'s `go-nav-and-launch` rows 6-10 were C-engine output and
encoded the guarded left/right of 11.8-11.9. Corrected in place with a `#`
note, the same treatment the help rows got. `test_menu.gd`'s attract test is
now its own inverse — it asserts that a minute of idling on any screen changes
nothing at all, because the failure to guard against is that timer coming
back.

### A cheap trap in the harness, not the game

`touch_shell.gd` waited out the shell's fades by counting FRAMES. This
harness renders as fast as it can — measured at about 1400 fps — so 900
frames is 0.6 s of a 2 s fade, and the suite failed on a transition that was
working perfectly. It waits on the wall clock now. Anything that waits for a
fade must.

### A trap that cost a save file

`render_menu.gd`'s touch test drives the settings screen through the real
view, and the view's job is to persist — so the suite wrote
`user://skyroads.cfg`, flattening the sound flag and thirty completion
counters. `Config` now has an overridable `path` and every test points it at a
scratch file. **Any new suite that reaches a commit path must do the same.**

---

## 12. 2026-08-31 — the gameplay composer, read out of the EXE

§11 measured the SHELL against the retail binary and left the gameplay
composer untouched. This section is the first pass over it, by the same
method: disassemble `SKYROADS.EXE` with capstone (code image at
`hdrpar * 16`, the u16 at EXE offset 8; addresses code-segment relative; data
segment paragraph `0x66E`) and decode the TREKDAT span records the composer
consumes with `tools/dump_bands.c kindlines <slot>`.

### How the composer is actually built

`fn_2d03` is the frame composer. It walks 11 direction rows x 4 columns x 2
halves, and for each cell dispatches on the cell's geometry nibble through a
**16-entry table at `ds:0x0b7f`**:

| nibble | handler | what it is |
|---|---|---|
| 0 | `0x2e50` | the deck slab, plus a skirt at each side that only appears where the neighbouring cell is empty (colour +0x1e and +0x0f) |
| 1 | `0x303d` | the tunnel: mouth wall at `0x43`, then the six kind-4 arch records, plus two rims at the mouth |
| 2 | `0x2e9f` | low block |
| 3 | `0x2ee1` | low block with a bore |
| 4 | `0x2f3c` | full-height block |
| 5 | `0x2fb0` | tun_high |
| 6..15 | `0x3aad` | nothing |

Records are a cursor, not an index: `[si]` is the colour byte of the record
about to be drawn, `call [0xe4c]` draws it and advances, and `0x31b5`
(`si += 3` until `0xff`, then `si++`) advances past one without drawing. The
directory at `di` gives 6 entry points per cell, 12 bytes apart, which is the
`dir[slot*2]` that `dump_bands.c` already reads.

### 12.1 — a tun_high is a bored full-height block, not a tunnel with a tier

**What the original does.** `0x2fb0` is `0x2f3c`, the full block, with one
substitution. Where the full block draws the plain lower front, the tun_high
draws the bore interior and the kind-3 PAIR that splits that front around it:

```
0x2f3c (kind 4)                     0x2fb0 (kind 5)
  compose_floor                       compose_floor
  nearer<2: seek 3, fill              nearer<2: seek 1, fill 0x41
                                      nearer<2: seek 3, skip, fill, fill
  seek 2, skip, inner<2: fill         seek 2, skip, inner<2: fill
  seek 5, fill blockcolor             seek 5, fill blockcolor
    inner<4 ? fill : skip               inner<4 ? fill : skip
    nearer<4: fill                      nearer<4: fill
```

`0x2fb0` never loads `[di+8]`, so **none of the six kind-4 arch records a
plain tunnel paints appear on a tun_high at all.**

**What the port did.** It drew a full tunnel — arch gradient and all — and
stood a block on top of it whose front stopped flat at half-block height. It
did that because `skyroads-port/src/core/render.c`'s `compose_tun_high` has
both halves of the error: it seeks kind 4 and paints the six arch records,
and it omits the kind-3 pair entirely. Another entry for §11's list — the C
reference was wrong, the port copied it, and no test could see it because
both sides agreed.

**The evidence, at phase 0 / dr7 / ci1.** The kind-3 pair carves an opening
16 px high at the lane centre and 20 px half-wide at the deck: that is
`RoadMesh.ARCH_BORE_PX` to the pixel, the same bore the geom-3 blocks already
draw. The kind-5 records above it are top `y[51..61]`, side `y[51..81]`,
front `y[62..81]`, and the kind-3 front below them runs `y[82..101]` down to
the deck — one continuous masonry face from the tier's top edge to the road,
pierced once.

**Fixed on both sides.** `render.c` is corrected in place, with a comment
citing `0x2fb0` — it is the measuring instrument and it had to be right
before anything could be measured against it. `RoadMesh.gd`'s geometry 5 is
now `_block(..., FULL_BLOCK_Y, code, bored = true, col)`: the geom-3 path at
full height, which is what the substitution above says it is.

**This closes #29c.** The tier's "true lower bound", which that entry says had
not been derived, is not a bound at all — the tier front simply ends where the
kind-3 front begins, and the sliver of vault the port left showing was vault
it should never have drawn.

### The measurements

Both states measured against the CORRECTED reference, since the old one
disagrees with the binary on exactly these cells. The metric is the fraction
of road-ish pixels (the deck ramp, the block and arch colours) that classify
differently, over rows 40..167. Road 2 has two tun_high cells at row 80, on
screen only at t=640; road 19 has 31 of them at rows 15..27.

| frame | port before (3 runs) | port after (2 runs) |
|---|---|---|
| road 2 t=100 | 15.03 / 14.98 / 15.03 % | 14.98 / 15.03 % |
| road 2 t=240 | 18.94 / 19.04 / 20.61 % | 20.59 / 20.31 % |
| road 2 t=420 | 15.77 / 14.21 / 16.90 % | 16.02 / 15.80 % |
| **road 2 t=640** | **19.98 / 18.98 / 18.49 %** | **11.23 / 10.46 %** |
| road 19 t=120 | 10.06 % | 9.52 % |
| **road 19 t=180** | **38.97 %** | **17.70 %** |

**These figures were taken in palette-index space, which §12.8 later showed
overstates the gap.** Re-measured by RGB > 16, the same frames read: road 2
t=640 **18.9% -> 9.5%**, road 19 t=180 **34.2% -> 17.6%**. The conclusion is
unchanged and the improvement is if anything cleaner; only the absolute
"before" numbers were inflated. Quote the RGB figures.

The repeated runs are there because a windowed capture does not repeat
exactly — #29b and #39b — and the spread has to be known before a difference
can be called one. The ticks where no tun_high is on screen move around inside
that spread and nowhere else; the reference itself is byte-identical at
t=100/240/420 before and after the correction, which is the check that says
so.

### 12.2 — two more functions read, both clean

- **`fn_5064`, the road-select highlight.** A 48x9 box at `0xf3e`, i.e.
  x=62 y=12, stepped by `(sel % 3) * 9` rows and `((sel / 3) % 5) * 39` rows,
  plus 160 px of x for `sel >= 15`. `Menu.gd`'s `GO_BASE (62,12)`,
  `GO_ROAD_PITCH 9`, `GO_WORLD_PITCH 39`, `GO_COLUMN 160` and its 48x9
  highlight are the same numbers, and `(rd % 15) / 3` equals `(sel / 3) % 5`
  over 0..29. Recorded because a 0-pixel agreement with the C reference was
  what made this suspicious, and it is now agreement with the binary.
- **`fn_1f2c`, the per-road init.** Ship placed at x `0x8000`, y `0x2800`;
  gravity acceleration is `-(gravity * 0x1680 / 0x190)`, i.e. `-(g * 14.4)`
  truncated. Checked against `grav_accel_per_tick` in all 30 exported roads:
  30 of 30 agree (road 2: gravity 8, -115).

### A lead that is now exhausted

§11's best lead was art exported under `data/gfx/` that nothing referenced —
it is what found 11.3, the intro's missing 23 seconds. Re-run today, every one
of the 46 PNGs is referenced, the six `*_dim` plates through `gfx.json`'s
`dim` field rather than by name. That lead is spent; the composer's own
dispatch table is the one that replaced it.

### A dead end worth writing down: the letterbox cannot be painted

On a 16:9 screen `aspect=keep` pillarboxes the 4:3 picture and the bars are
black. Filling them with a frame looks like a ten-line `CanvasLayer` and is
not possible at all from inside the tree. Two measurements, at 1440x810:

- A layer at `layer = -100` drawing into the bar coordinates runs, and its
  arithmetic is right — inverting `get_final_transform()` puts the window
  corners at canvas `(-80,-15)` and `(400,255)`, exactly the 80- and
  15-pixel bars — and **nothing appears**.
- `RenderingServer.set_default_clear_color()` does not reach them either.

With `keep`, Godot attaches the root viewport to the letterboxed sub-rect;
the surround is not part of any viewport and no draw call can reach it. The
only way to paint there is `aspect=expand` plus rendering the game into a
fixed 320x240 `SubViewport`. Scoping that properly turns up **two** coupling
points, not one:

- **The parity capture path.** `Main._capture_shot`, `_capture_roadend` and
  `_capture_menu` all read `get_viewport().get_texture()`. Inside a
  `SubViewport` that is the wrong texture, so all three move — and that is the
  path this document's own rule says not to change without measuring.
- **The touch input path.** Events would arrive through a
  `SubViewportContainer`, so the transform changes. `touch_shell.gd` maps
  synthetic touches with `get_root().get_final_transform()`, which would no
  longer be the transform that matters, and the suite runs at two window sizes
  precisely to catch that class of mistake.

Everything visual has to move: `_world`, `_hud`, `_menu`, `_intro`,
`_roadend`, `_touch` and the fade layer.

So the bars stay black for now. **The right time to do this is the first task
of the mobile phase**, when the touch layer is being revisited anyway and both
coupling points are already open — not bolted onto a desktop-parity pass, where
it would put the two most protected paths in the project at risk for a
cosmetic gain. This note is here so the next person does not spend the hour
rediscovering that the letterbox is unreachable.

### 12.3 — #29b / #39b: the capture was of a tick nobody asked for

Both entries describe the same thing from different ends: a screenshot named
`t0640` was not necessarily of tick 640. `GameLoop._process` runs a catch-up
loop, and a frame that owes several ticks simulates all of them; `Main`'s
capture then ran afterwards and photographed tick N+k. Nothing recorded k, so
the same build measured 18.5% and 20.0% of road 2's road pixels on
consecutive runs, and the road-16 explosion came out one animation frame
stale.

**Fixed at the cause.** `GameLoop.halt_ticks` stops the catch-up loop on a
tick that is going to be photographed. The debt is deferred, not dropped, so
the run does not slow down — the next frame catches it up. `Main` fills it
from `--shot-ticks`, and only when `--shots` is set, so ordinary play is
untouched.

`LaunchOptions.shot_alpha` (`--shot-alpha`) then pins WHERE inside the tick
the shot is taken, since presentation interpolates between ticks. It defaults
to **0.0** — the state exactly on the tick, which is what the reference draws
a frame *for*.

Measured on road 2 t=640, against the corrected reference:

| | runs | spread |
|---|---|---|
| before | 18.49 / 18.98 / 19.98 % | 1.49 pts |
| after, alpha 0.0 | 9.61 / 10.51 / 11.23 % | 1.62 pts |
| after, alpha 1.0 | 11.23 / 11.66 % | — |

The simulated state at capture is now identical run to run — four consecutive
runs report the same tick, z, x, y and presented row to the last digit, where
before they did not. **The remaining spread is not the simulation.** Diffing
two captures of the identical pinned state shows 776 differing pixels and
every one of them is a single-pixel silhouette edge: block corners, the near
edge of the deck. That is GPU rasterisation rounding on a 3D scene being
compared against a 2D span filler, and the metric counts each such pixel, so
~2 points of it is the floor of what this measurement can resolve. Recorded
so the next person does not read a 2-point move as a result.

The old note in `Main._capture_pending` — that the reference corresponds to a
moment part-way through this engine's tick, so the un-rewound capture is
closer — was drawn from the behaviour it was describing: the capture was PAST
the tick, not part-way into it. With k pinned to 0 the fractional argument no
longer applies, and alpha 0.0 measures at least as well as anything else.

### 12.4 — the other four composers, all clean

With `fn_2d03`'s dispatch table in hand the remaining handlers were read
against `skyroads-port/src/core/render.c` line by line:

| nibble | EXE | reference | verdict |
|---|---|---|---|
| 0 | `0x2e50` | `compose_floor` | matches |
| 1 | `0x303d` | `compose_tunnel` | matches — mouth wall `0x43`, six arch records, two rims at the mouth only |
| 2 | `0x2e9f` | `compose_lowblock` | matches |
| 3 | `0x2ee1` | `compose_tun_low` | matches — and it is the shape 12.1 says a tun_high is, at half height |
| 4 | `0x2f3c` | `compose_highblock` | matches |
| 5 | `0x2fb0` | `compose_tun_high` | **WRONG — see 12.1** |
| 6..15 | `0x3aad` | — | a bare `ret`: those nibbles draw nothing |

So the damage was bounded to the one handler. Two labelling slips are left
alone because they change no behaviour: `compose_lowblock`'s "top faces"
comment is on the record that draws the FRONT, and `compose_highblock`'s
"upper front"/"upper side" are the other way round — the kind-5 group is top,
side, front in that order, which the decoded records show directly
(`k61 y[51..61]`, `k63 y[51..81]`, `k62 y[62..81]`).

The port's `geom` 2 and 3 are `_block(..., HALF_BLOCK_Y, code, geom == 3, col)`
— unbored and bored half blocks — which is exactly the pair the EXE draws, and
12.1 makes geom 5 the same pair's full-height bored member.

One difference is deliberate and applies to every handler: the original gates
each face on its neighbour's shape (`nearer < 2`, `inner < 4`, ...) because it
paints spans with no depth buffer. The port draws the faces unconditionally
and lets 3D occlusion hide them.

**Checked, and the two agree everywhere.** Across all 30 roads the gates fire
on 870 cells — 723 where a full block or tun_high one row nearer suppresses
the tier front, and 147 where a half block one row nearer suppresses the
lower front — spread over 24 roads. In every one the suppressing neighbour is
the thing that would occlude the face anyway, and it is drawn LARGER than the
face it hides because it is closer to the camera. A gate can only become
visible where the suppressing neighbour is smaller on screen than the face it
suppresses, which a same-column cell one row nearer never is. So the port
loses nothing by letting depth do the work.

### The audit tooling

`scratchpad/audit/sdis.py` (code) and `dat.py` (data segment) are throwaway
but the recipe is not: code image at `hdrpar * 16`, data at paragraph
`0x66E`, `CS_MODE_16`, and `tools/dump_bands.c kindlines <slot>` for the
records a handler consumes. That pair is what turns "the C reference says so"
into a measurement.

### 12.5 — a capture run must not be steerable

The gate reported `render_backdrop.gd` failing on road 5 at ticks 61 and 121,
571 pixels wrong in rows 0..31 — the band that suite exists to protect,
because tall roadside blocks used to project up into the sky there. The
reference was checked first and holds the invariant exactly: rows 0..31 of
road 5 differ from `world1_0.png` by **0 pixels** at ticks 60, 61, 62, 120,
121 and 122.

The 571 pixels were not geometry. They were text —
`recorded 15 ticks / road05_2026-08-31T10-49-54.bin`, the recording toast,
drawn over the sky. That file is on disk, 45 bytes, 15 ticks of `01 02 00`,
which is the held-accelerate route; and the run went on to tick 121, so it
was not the death-path dump. The remaining trigger is the `R`/`F2` developer
key, and the gate had a focused windowed Godot at that second.

So the measurement was steered by a keystroke that had nothing to do with the
game. **`Main._unhandled_input` now ignores every developer key during a
`--shots` run** — `P` stalls the loop, `L` and `C` paint overlays, `F2`/`R`
dumps and toasts. ESC still works, so a run can still be abandoned. Nothing
changes for ordinary play.

Worth keeping in mind beyond this one suite: a windowed capture takes focus,
so anything typed while the gate runs goes into the game.

### 12.6 — collision, read out of the EXE. Clean.

`BUGS.md` has said since #31 that `TUN_INNER`/`TUN_OUTER` are the COLLISION
profile and disagree wildly with what the original DRAWS. That was established
by measuring the drawn side. The collision side had never been read out of the
binary at all — so with §11 finding eleven defects in the shell and §12.1 one
more in the composer, it was overdue.

`fn_1685` is the collision test, `fn_1584` the per-slice profile it calls:

```
fn_1685(z32, x, y):
    right = tile_at(z, x + 0x700)          # 0x700 is the ship's half-width
    left  = tile_at(z, x - 0x700)
    if (right | left) & 0x00f:             # low nibble: the cell has floor
        if y < 0x2800 and y + 0x600 > 0x2480:   return true      # landing
    if y + 0x680 <= 0x2800:                     return false     # too low to hit
    if not ((left | right) & 0xf00):            return false     # nothing stands
    t = 0x17 - ((x / 0x80 - 0x31) % 0x2e)       # slice across the column
    step = -0x1700
    if t <= 0: t = 1 - t; step = +0x1700
    return fn_1584(tile_at(z, x), t, y)
        or fn_1584(tile_at(z, x + step), 0x2f - t, y)

fn_1584(tile, t, y):
    if t > 0x25: return false
    h = (y - 0x2200) / 0x80
    switch tile & 0xf00:
      0x100 tunnel:   return INNER[t] <= h < OUTER[t]
      0x200 low:      return y < 0x3200
      0x300 tun_low:  return y < 0x3200 and h >= INNER[t]
      0x400 full:     return y < 0x3c00
      0x500 tun_high: return y < 0x3c00 and h >= INNER[t]
      default:        return false
```

`INNER` is `ds:0x46`, `OUTER` is `ds:0x92`, **38 entries each** — the bound is
`t > 0x25` at `0x158d`, not the 24 a half-column would suggest.

**Everything matches.** `sra/sim.py`'s `solid` and `_solid_block` reproduce
both functions branch for branch, including the asymmetric `<` / `<=` at the
`y + 0x680` gate, and `SkyRoads.TUN_INNER` / `TUN_OUTER` are byte-identical to
the two tables across all 38 entries. The GDScript side comes along
transitively: the three-way differential already proves C, Python and GDScript
agree on 24 fields across 60,964 ticks, and the Python is now anchored to the
binary rather than to the C reference.

So the eleven roads with no route are **not** blocked by a physics defect. That
was worth establishing before tuning a search against them — a wrong collision
profile would have made "unsolvable" mean something else entirely.

It also confirms the #31 note from the other side: the collision arch really is
a different shape from the drawn one. `INNER[0] = 16` and `OUTER[0] = 32` in
units of `0x80`, against a drawn vault of `ARCH_OUTER_PX` 19 and `ARCH_BORE_PX`
16 in screen pixels. Two profiles, both authentic, and neither is the other.

### 12.7 — what the remaining road-2 gap is made of

With the tick pinned (§12.3) and the reference corrected (§12.1), road 2 at
t=640 sits at 10.46% of road pixels differing. About 2 points of that is
irreducible — single-pixel silhouette edges from rasterising a 3D scene
against a 2D span filler, measured in §12.3 — so the real target is ~8.

Classifying every differing pixel by which palette index each side chose turns
that number into a ranked list of causes rather than a mood:

| C index -> port | px | what it is |
|---|---|---|
| 13 -> 28 | 560 | deck colours, and NOT adjacent shades — a whole row band painted from the wrong row |
| 68 -> 69, 69 -> 70, 70 -> 67 | 727 | the arch gradient's four bands, boundaries in the wrong place |
| 68 -> 61, 61 -> 64, 61 -> 63, 64 -> 61 | 537 | block top/front/side, so face boundaries |
| 0 -> 61 | 119 | the original draws NOTHING and the port draws block top |
| 53 -> 61 | 91 | backdrop where the port draws block top |

By band, the differences concentrate at rows 56..71 (1443 px, the horizon,
where a row is a couple of pixels tall and a sub-tick of depth repaints all of
it) and rows 152..167 (571 px, hard against the dashboard).

**The arch bands are the one with a known fix.** `RoadMesh.TUNNEL_ARCH_LEFT` /
`_MID` / `_RIGHT` and their slice boundaries were fitted to reproduce the
measured AREAS of each record through this camera, not the records' own
extents — the comment there says so. `tools/dump_bands.c archlines` prints the
exact painted mask per record, so the boundaries can be taken from the data
instead of fitted. Worth about 2 points if it lands.

**`0 -> 61` was looked at, and it is not a discrete bug.** All 119 pixels sit
in rows 65..72 at x 229..316 — a wedge that widens with each row, hard against
the horizon on the right. That is not a cell being drawn that should not be;
it is the far end of the visibility window projecting a few pixels higher than
the original does, which puts it with #28 (the camera is a vertical pinhole at
B=2.550 AND a horizontal cone through y=32) rather than with the geometry. Not
worth chasing on its own.

**The arch bands are the real target, and they are harder than the note above
suggests.** The four records OVERLAP rather than tiling the lane — at dr7/ci0
they span x[15..69], [22..79], [33..84], [40..86] — because each paints over
the one before, so a band's VISIBLE extent ends where the next record starts,
not where its own does. Deriving the boundaries means walking that paint order
per column, not reading extents off `archlines`. Left undone deliberately:
this document already records three parity "improvements" that measured worse,
and a fit that looks obvious is exactly how those happened.

Nothing in this section is fixed yet. It is here so the next attempt starts
from a ranked list, and because "the residual is ~10%" is not a finding.

### 12.8 — #29b's number was mostly the measurement

Road 26 was recorded at ~17% of its solid road pixels differing, "dominated by
C index 3 -> port index 1 — two dark greys ONE PALETTE STEP APART". That
observation was right and its consequence was underestimated: **road 26's
palette is full of near-duplicate greys**, and comparing in palette-index space
turns invisible differences into wrong pixels.

```
palette[16] = (20,20,20)      palette[46] = (16,16,16)      <- 4 RGB steps
palette[ 1] = (28,28,28)      palette[33] = (32,32,32)
palette[49] = (40,40,40)      palette[18] = (36,36,36)
```

The single largest "error" at t=240 is 1525 pixels of `16 -> 46`. That is a
difference of 4/255 per channel. Nobody can see it, and nearest-index
classification cannot reliably tell them apart either — which also means the
confusion is not evidence of a neighbouring row being painted.

Measured both ways, against the corrected reference and the pinned capture:

| frame | by palette index | by RGB > 8 | by RGB > 16 |
|---|---|---|---|
| road 26 t=240 | 33.1% | 12.3% | **10.1%** |
| road 26 t=600 | 20.3% | 13.5% | **12.9%** |
| road 26 t=1000 | 22.0% | 8.8% | **7.3%** |
| road 2 t=640 | 10.5% | 10.2% | **9.5%** |

So road 26 is not three times worse than road 2; it is about the same, and
roughly two thirds of its recorded gap was the metric. Road 2 barely moves,
because its palette has no such near-duplicates — which is why this went
unnoticed.

**Anything measuring road parity should compare RGB with a tolerance**, not
palette indices. Index classification is still the right tool for asking WHICH
SURFACE a pixel belongs to (§12.7 uses it for exactly that, on road 2), but it
is the wrong tool for asking whether two frames differ.

### 12.9 — the rest of the simulation, spot-checked against the EXE

Continuing 12.6 into the parts that were still trusted only because the C
reference agreed with the port:

| what | EXE | verdict |
|---|---|---|
| surface effects | `fn_1a9c` + its switch at `0x1b40` | matches |
| sticky / boost | `0x1b17` / `0x1b2f`, both `0x12f` on the 32-bit speed, both guarded by `expl_ctr == 0` | matches |
| supply tile | `0x1ad6`: refill both tanks to `0x7530`, chirp unless BOTH were already `>= 0x6978` | matches |
| burning tile | `0x1aab`: `end_state = 2`, `expl_ctr = 1`, sfx 0 | matches |
| oxygen burn | `0x2a29`: `0x7530 / (0x24 * oxygen_secs)` per tick | matches |
| fuel burn | `0x2a4e`: `(0x7530 / fuel_rows) * speed >> 16` | matches |

Nothing found. Which is the point of writing it down — the value of an audit
pass is as much in the parts it clears as the parts it breaks, and "clean"
only means something if it is recorded with the address that was read.

**Still unread**, and therefore still resting on the C reference: the autopilot
proper (`fn_1d4d`) and its two helpers (`fn_1bb5`, `fn_1c20`), audio and music
timing, the attract demo, and the road-end screen. On the record so far — one
defect in the composer, none in collision, movement, HUD or surfaces — the
autopilot is the biggest unaudited surface left and the obvious next target.

### The autopilot, spot-checked

`fn_1d4d` and its two helpers were the largest unaudited surface after 12.9.

- **`fn_1bb5`** (is this cell fatal to land on) reproduces exactly, including
  the awkward shape of it: `kind == 0x100` returns false outright, a non-zero
  kind shifts the code down four bits before the surface nibble is read, and a
  zero surface nibble answers `kind == 0` rather than falling through to the
  `0xC` test.
- **`fn_1c20`** (does this jump land) matches on every constant and on the
  order of operations: `X_MIN`/`X_MAX` are `0x2f80`/`0xd080`, the lateral term
  is `xvel * (speed + 0x618) / 0x200`, gravity comes from `ds:0x54b6` and the
  side push from `ds:0x54a2`, and the x bounds are tested BEFORE `y += yvel`.
- **`fn_1d4d`** matches structurally: land first and zero `ap_delta` if it
  already lands, else `speed0 = speed`, `si = xvel`, `di = 1`, and the search
  scales by `di/10` through `imul`/`idiv` exactly as `cdiv(xvel * di, 10)`
  does, bounded by the six strengths `consts.py` already cites at `0x1efe`.

**Honest limit on this one:** the four attempt branches inside the loop were
matched on shape and constants, not traced one by one to their `_ap_lands`
calls. The structure, the constants and the three-way differential all agree,
so nothing suggests a defect — but this is a spot check, not the branch-for-
branch treatment `fn_1685` got in 12.6, and it should not be quoted as one.

### 12.10 — the gameplay song could repeat, and the original never does

Found while auditing audio. Both the port and the C reference dodge an
immediate song repeat by comparing the new pick against `want_song`:

```c
int song = 2 + (int)((g->rng >> 16) % 12);
if (song == g->want_song)          /* <- wrong operand */
    song = 2 + (song - 1) % 12;
```

`want_song` is also what the menus set — 0 for the intro, 1 for both menu
screens. On the normal path (road, back to the road select, next road) it is 1
when the road starts, a gameplay song is never 1, and **the dodge never
fires**. The port could play the same song twice running.

`main` at `0x29f-0x2c9` keeps the previous game index in its own slot at
`[bp-6]`, which no menu touches:

```
0x29f   r = rand() % 12
0x2ab   cmp di, [bp-6]         ; the previous GAME index
0x2b2   r = (r + 1) % 12       ; a step, not a reroll
0x2c0   [bp-6] = r
0x2c5   music_start(r + 2)
```

Fixed on both sides — `AudioMgr._last_game_song` and `sr_game.last_game_song`.
The arithmetic was already right: `2 + ((song - 1) % 12)` is exactly
`(di + 1) % 12` re-based, including at the wrap. Only the operand was wrong.

**The fixture did not need regenerating**, which is worth stating because §11
had to correct three of them. `test_audio.gd` drives `gameplay_song()` in a
row with no menu between calls, so the last song asked for and the last
gameplay song are the same value at every step and both versions emit the
identical sequence. This one only shows in play.

Thirteenth defect found by reading the binary, and the first outside the
renderer and the shell.

### 12.11 — the ship was sheared off on a high jump

Found by playing, which is the only way it could have been found: every parity
suite compares frames with the ship near the deck.

The world is composed into rows 32..137 of the DOS framebuffer and never above
— `render.c` writes into `fb->px + 32*320` and the span records are baked to
stay inside that. A 3D camera has no such bound, so a tall block close to the
ship projects up into the sky (that was #30-era work). The port clipped it by
painting the backdrop's own top rows back over the 3D from a `CanvasLayer`.

**A `CanvasLayer` draws over everything, including the ship** — and the
original draws the ship UNCLIPPED. `draw_ship` bounds x and the cowl mask and
never y:

```c
int x = left + j, y = top + i;
if (x < 0 || x >= 320 || cowl_hidden(x, y))
    continue;
fb->px[y * 320 + x] = px;          /* no y bound at all */
```

`top = 0x9d - p->y / 0x80`, so the ship rests at row 77 and a jump walks it up
the screen and legitimately into the sky band. Measured on road 17 at t=150,
where the sprite straddles the boundary:

| | ship pixels | topmost row |
|---|---|---|
| reference | 290 | 31 |
| port, before | 145 | 35 |
| port, after | 149 | 32 |

The top of the ship — its navy canopy and the white dot — was simply gone.

**Fixed by clipping the geometry instead of covering it.**
`SkyRoadsCamera.make_dos_material` now discards fragments above the viewport
top in screen space, which is what the original's baked span records amount
to, and the `AboveViewport` cover is deleted. The backdrop already fills those
rows, so nothing else was needed. `render_backdrop.gd` still measures 0
differing pixels on all four of its frames, which is the check that would have
caught this going wrong.

Note the same code implies the original writes the ship at NEGATIVE y on a big
enough jump — road 11's route reaches `top = -65`. In the C port that is a
buffer underrun; what the 1993 binary does there has not been looked at.

### 12.12 — outer-column blocks are drawn too large, and too low

Reported from play on road 1 ("asteroid belt"), whose only obstacles are full
blocks in columns 0 and 6 — the outermost lanes — at rows 3, 8, 15 and 19.
Measured against the corrected reference with the tick pinned:

| tick | reference | port | delta |
|---|---|---|---|
| 120 | x[180..227] y[32..103], 185 px | 213 px | **+15%** |
| 160 | x[190..293] y[32..106], 848 px | y[32..114], 953 px | **+12%**, base 8 rows low |
| 200 | x[180..304] y[32..77], 549 px | y[32..74], 597 px | **+9%** |

The horizontal extents agree almost exactly and both tops clip at row 32
identically — so the §12.11 shader clip matches the original's band, and the
x cone is doing its job. **The whole error is at the bottom edge**: the port
puts the block's base up to 8 screen rows lower, which reads as the block
being nearer than it is.

**That explanation was WRONG and is corrected here.** The first version of this
section said the port lacked a vertical correction for off-centre columns. The
span tables refute it: the original's vertical geometry is **identical across
all four columns** at every band, for floors and for both block groups.

```
floor   dr5  ci0 y[52..60]  ci1 y[52..60]  ci2 y[52..60]  ci3 y[52..60]
        dr6  ci0 y[61..75]  ci1 y[61..75]  ci2 y[61..75]  ci3 y[61..75]
        dr7  ci0 y[76..101] ci1 y[76..101] ci2 y[76..101] ci3 y[76..101]
block   dr7  ci0 y[64..81]  ci1 y[64..81]  ci2 y[64..81]  ci3 y[64..81]
tier    dr7  ci0 y[51..61]  ci1 y[51..61]  ci2 y[51..61]  ci3 y[51..61]
```

A pinhole's y is already independent of x, so there is nothing to correct on
that axis — the shape of the port's projection is right and "add a vertical
cone" would have been a fix for a cause that does not exist.

**The error is in the depth-to-screen-row mapping.** Road 26's rows are a
colour ramp, so its boundaries can be read straight off a frame:

| | boundaries |
|---|---|
| reference, t=240 | 41, 42, 44, 47, 50, 56, 65, 112 |
| port, t=240 | 41, 42, 49, 60, 109 |
| reference, t=600 | 43, 44, ... |
| port, t=600 | 41, 42, ... (two rows high) |

The port's ladder does not land where the baked bands do, and it resolves
fewer rungs. That is what makes an outer-column block read as nearer: it is
sitting at the wrong depth on screen, not at the wrong height for its column.

Not attempted. The fix is to make the depth ladder land on the baked band
boundaries — the table above IS the target, `dr1` through `dr8` for phase 0,
and `tools/dump_bands.c lines` prints it for all eight scroll phases. That is
a derivation from data, not a re-fit, which matters because #28 already
records that re-fitting the camera as a single pinhole is a dead end.

Not attempted here. `docs/BUGS.md` records three parity "improvements" that
measured worse, all of them camera-adjacent, and this one wants the vertical
term derived from the span tables the way `dos_x_scale` was derived for the
horizontal — `tools/dump_bands.c lines` prints the per-row, per-column floor
extents that would drive it. It is the largest single visible discrepancy left
in the renderer, and the most likely to reward being done properly rather than
fitted.

### 12.13 — driving the vertical axis from the DOS ladder: measured much worse

The fourth camera-adjacent attempt in this document, and the fourth to fail.

The reasoning looked strong. `row = DOS_P200 + DOS_F200 * (1 - h) / d` predicts
the baked band edges exactly — 102, 76, 61, 52, 46, 41, 37 for d = 2.55..8.55,
which is dr7-near through dr2-far, seven for seven — and `HALF_BLOCK_Y`
0.216433 lands the half-block top at row 82 against the table's 81. So the
shader was changed to take POSITION.y from that ladder instead of the pinhole,
exactly as it already takes x from `dos_lane`.

Measured against the corrected reference, RGB > 16:

| frame | before | after |
|---|---|---|
| road 1 t=120 | 11.4% | **50.3%** |
| road 1 t=160 | 13.3% | **53.2%** |
| road 26 t=240 | 10.1% | **48.1%** |
| road 26 t=1000 | 7.3% | **76.0%** |

Reverted. Road 1 t=160 reads 13.0% again, which is the same number inside
capture jitter.

**Why the premise was wrong.** The pinhole is ALREADY fitted to those row tops
— `analysis/sra/project.py` has `row_tops_from_trekdat` and `fit_camera`, and
B = 2.550 came out of exactly this table. Replacing it with the ladder does not
add information; it discards a fit that reconciles the whole frame in favour of
one that is only correct for vertices lying exactly on the sampled rows.

**And the evidence for a problem was bad.** 12.12 cited road 26's row
boundaries landing in the wrong places — measured by palette-index
classification, on the one road §12.8 had already shown that metric invents
differences on, because its greys are 4/255 apart. Using a metric one section
after documenting that it lies is the actual mistake here, and it is worth more
than the failed change.

What survives: the outer-column block bbox measurements in 12.12, which were
taken in RGB and stand. Something is still wrong there. The cause is not known,
the ladder is not it, and the next attempt should start by re-measuring those
blocks with a mask that cannot pick up road or backdrop pixels.

### 12.14 — the parity work has been tuned against the easiest road

Everything in §12.7 was measured on road 2. A sweep of eight solved roads at
three ticks each, RGB > 16 against the corrected reference with the tick
pinned, says road 2 is the BEST case in the game:

| road | mean | road | mean |
|---|---|---|---|
| 2 | **9.5%** | 24 | 16.8% |
| 3 | 9.3% | 7 | 17.5% |
| 26 | 11.0% | 15 | 21.1% |
| 9 | 12.6% | 21 | **22.8%** |
| 5 | 15.7% | | |

Median **16.4%**, worst **30.0%** (road 21 at t=200). So the honest figure for
the renderer is not 9.5% — that is the number for the one road every fix has
been measured on.

**And the dominant defect is not the arch bands.** Classifying every differing
pixel by which surface each side chose:

| frame | share involving a block face | largest single confusion |
|---|---|---|
| road 21 t=200 | 68% | `61 -> 7` x2170 — block TOP where the port draws deck |
| road 5 t=400 | 57% | `0 -> 61` x940 — nothing where the port draws block top |
| road 7 t=400 | 53% | `62 -> 9` x676 — block FRONT where the port draws deck |
| road 15 t=400 | 52% | `61 -> 62` x1194 — block top where the port draws front |
| road 24 t=600 | 3% | `69 -> 66` x540 — arch band vs rim |
| road 3 t=200 | 0% | `3 -> 66` x143 — deck vs rim |

Road 21's worst frame has **zero** pixels involving an arch colour. Two
separate families, and the block one is much the larger:

- **Block faces (roads 5, 7, 15, 21)** — the port puts the top/front/side
  boundaries in the wrong place, and sometimes draws deck where a block top
  belongs. This is the same thing §12.12 measured as "outer-column blocks 9-15%
  too large", seen from the colour side rather than the bounding-box side.
- **Arch bands (roads 3, 24)** — §12.7's `TUNNEL_BAND_EDGES_*`, fitted to
  areas rather than derived from the records' paint order.

`r = 0.45` between a road's tunnel fraction and its error, which is too weak to
act on; the block family is the one to chase, and it is worth roughly three
times the arch family across this sample.

**None of this is fixed.** It is recorded because "road 2 is at 9.5%" has been
the project's headline number and it is not representative — and because the
next attempt should start on road 21, not road 2.

**Correction, same day.** The surface LABELS above do not survive checking. The
table calls `61 -> 7` "block top where the port draws deck" because 61 is the
default block-top colour and row 22's block-top nibbles are all 0, which made
it a reasonable read. But the baked records put a half-block top at dr8 on rows
82..99, and BOTH engines paint something else there — so which record each
index belongs to is not established, and the "52-68% block faces" split is
built on that same guess.

What survives, because it is measured rather than inferred:

- **The per-road spread.** Median 16.4%, worst 30.0% on road 21, road 2 best at
  9.5%. That is a straight RGB comparison and needs no labels.
- **The defect is one boundary in the near field.** Down the centre lanes of
  road 21 t=200, the two engines agree exactly above DOS row 102 and below row
  114, and disagree only between: one surface boundary sits 12 rows lower in
  the port. Near edge exact, far edge short.
- **The geometry in view is a single row two behind the ship** — road 21 row
  22, `3 3 3 5 3 3 3`.

And one fact that constrains any explanation: **dr9 (-2) has no floor records
at all**, and `post-ship` (0x240) has none either. The original draws nothing
two rows behind the ship, and `pre-ship` (0x210) duplicates dr7's own band.
Whatever the port is drawing back there, the original is not drawing it the
same way.

Three hypotheses were tested and eliminated: the cover materials do not clip
(they pass CLIP_NONE), they do not blend (palette entries are RGB, alpha 1),
and the row is inside the visibility window. The cause is not yet known.

**Why the attribution failed, definitively.** Road 21's palette contains exact
duplicates:

```
[61] (247,150,142) == [68]   gap 0      block top  == arch band
[62] (203,121,117) == [66]   gap 0      block front == arch rim
[ 8] ( 81, 81, 81) == [34]   gap 0
```

Nearest-palette classification **cannot distinguish a block face from an arch
band on this road** — they are byte-identical. So the block/arch split in the
table above is not merely unproven, it is unknowable by that method, and the
same doubt applies to every road whose palette repeats an entry.

This is §12.8 again, one road over. That section established that index
classification counts differences nobody can see; this one adds that it also
merges surfaces nobody can separate. **Index classification is for asking
"did this pixel change", never "what is this pixel".**

**The method that would work**: render a SURFACE-ID buffer. The corrected
reference already knows which record it is filling — `fill_record` is called
once per record with the kind in hand — so writing the record index into a
second buffer instead of the colour gives an unambiguous per-pixel surface map,
and the port can be made to emit the same thing from its own materials.
`docs/reference-corrections/` is the place for that instrumentation. Until it
exists, no claim about WHICH surface is wrong should be trusted, including the
ones in §12.7.

**It exists now, and it has been run — see §12.15**, which also records why a
`none` on the reference side is a question rather than a verdict.

### 12.15 — the surface-ID buffer exists. What it says.

§12.14 ended with a method and no instrument. The instrument is now built on
both sides and has been run: `SR_SID_*` written by `fill_record` into
`sr_surface_ids` (dumped beside each PPM when `SR_SURFACE_IDS=1`), the same
identities emitted per quad by `RoadMesh` in `UV2.x` and painted by the road
shader under `--surface-ids`, and `tools/sid_compare.py` to put the two maps
side by side. Recipe, road 21 t=200:

```bash
clang -O2 -o /tmp/sr_replay_frames tools/replay_frames.c \
    skyroads-port/src/core/{assets,audio,cfg,game,gfx,hud,lzs,play,render,tables,text}.c \
    skyroads-port/src/thirdparty/opl3.c -lm
SR_SURFACE_IDS=1 /tmp/sr_replay_frames <retail> <out> 21 godot/data/routes/road_21.bin 200 400
$GODOT --path godot --resolution 640x480 -- --replay 21 \
    --route-file res://data/routes/road_21.bin --shots <out> --shot-ticks 200 --surface-ids
tools/sid_compare.py <out>/c_t0200.sid <out>/road21_t0200.sid.png [--column X]
```

**First result, and the blind spot it exposed.** Over the full view the maps
disagree on 13.7% of pixels — but 2643 of those 4546 are `none` on the
reference side, and `none` does not mean DOS drew nothing. The map records only
what `fill_record` writes. At the lane centre the composer's nearest record
stops at y=128 on every tick sampled (50, 100, 150, 200, 250), yet rows
129..137 of the same frames **agree with the port in RGB to 14 pixels in 2880
(0.5%)**. DOS paints them by another route. Restricted to rows 34..128, where
both engines name a record, the disagreement is 9.0% and has essentially one
member:

```
reference          port               pixels
tunhigh.k5.0       floor.k0.0         1633      <- the whole defect
none               floor.k0.0          503      <- blind spot again
ship               *                   ~400     <- see below
```

**§12.14's near-field defect, attributed.** The column ladder at the lane
centre, road 21 t=200 (phase 3, row 22 = `3 3 3 5 3 3 3`):

```
             reference           port
y[ 34..101]  floor.k0.0          floor.k0.0    (runs to 111)
y[102..128]  tunhigh.k5.0        tunhigh.k5.0  (112..137)
```

It is **not a wrong surface**, which is what every previous attempt assumed and
what the palette made unfalsifiable. Both engines agree the surface is
`tunhigh.k5.0`. The block top is also **not the wrong size** — 27 rows in DOS,
26 in the port. It is in the wrong PLACE, about 10 rows too low.

And the error is not a constant, so it is not one offset:

```
 x=100   boundary  ref 107   port 123    16 rows low
 x=140             ref 102   port 112    10
 x=160             ref 102   port 112    10
 x=200             ref 102   port 112    10
 x=240   floor top ref 113   port 113     0      exact
```

**A third finding: the ship and the road are not drawn at the same instant.**
At x=140 the reference paints `ship` at y[59..67] and the port at y[51..59] —
same height, 8 rows up, and visible in the pictures, not only the maps. That
was first written up here as an altitude->row scale error. **It is not.** Both
engines compute the sprite's row with the identical expression — C
`render.c:395` `alt = ((on_sticky ? p->y - 0x80 : p->y)) / 0x80`,
`top = 0x9d - alt`; port `ShipSprite.sync` `alt = (py - 0x80 if on_sticky else
py) / 0x80`, `top = SCREEN_Y_BASE - alt` with `SCREEN_Y_BASE == 0x9D`. There is
no scale between them to be wrong.

It is a TICK ALIGNMENT. The ship is falling 8 rows per tick right here — the
reference paints it at y[59..67] on t=200 and at y[67..75] on t=201 — and the
port's t=200 frame sits one step above the reference's, which is to say at the
reference's t=199. Compared against `c_t0199.sid` the ship lands within **one
row** (ref y[52..60], port y[51..59]).

The road does not follow it there. Against t=199 the block-top boundary goes
from 10 rows out to 16 (ref 96, port 112): the road matches t=200 better while
the ship matches t=199, and no single reference tick fits both. The port's road
is running roughly one to two ticks ahead of its own ship, and the near-field
number above is contaminated by that offset — which is the second reason not to
chase the boundary with a camera change.

This is §12.3's lesson again. `_capture_pending` deliberately does NOT rewind to
the exact simulated tick (`SHOT_ALPHA_DEFAULT == 0.0`, and both the rewound and
the inside-the-loop variants measured worse on road 2). That choice was made on
whole-frame RGB, which cannot see the road and the ship disagreeing with EACH
OTHER; the surface map can.

**The `--shot-alpha` sweep was run, and it found a different bug: the flag does
not reach the saved image at all.** Captures at `--shot-alpha` 0.0, 0.25, 0.5,
0.75 and 3.0 are BYTE-IDENTICAL, with and without `--surface-ids`
(md5 `2ceda940c3310195774ff2ad1ee11861` for every one). The flag is parsed and
applied — a print in `_capture_pending` after the override shows
`shot_alpha=0.750000 loop_alpha=0.750000 play.y=15331 prev_y=16134
view_y=14729`, i.e. `view_y` moved 602 game units, 4.7 screen rows, and at
alpha 3.0 it would move about 19 — yet not one pixel of the PNG changes.

So the frame that gets saved is not the frame `_present()` was just asked to
draw. `_capture_pending` does `override_alpha` -> `_present()` ->
`RenderingServer.force_draw()` -> `get_viewport().get_texture().get_image()`,
and what comes back is the frame drawn BEFORE the override — the ordinary
`_present()` at line 699, at whatever alpha the frame loop happened to hold.

This matters well beyond this section. **Every parity capture in the project is
of a frame whose interpolation fraction was never pinned**, which is precisely
the non-reproducibility #29b believed `--shot-alpha` had fixed, and it is a
candidate explanation for "the same build measured 18.5% and 20.0% on
consecutive runs". Fix the capture path first; until it is fixed, the alpha
question above cannot be asked, and no near-field number here should be treated
as better than approximate.

**What is NOT the cause.** The eighth-of-a-row scroll quantisation
(`SkyRoadsCamera.dos_scroll_row`) was written as this defect's explanation. It
is not. A/B on the same frame:

```
                    sid differ    RGB differ (tol 16)
scroll quantised    13.7%         8.6%
continuous          14.1%         9.0%
```

Worth keeping — it wins on both metrics and it is read off the eight baked band
tables rather than fitted — but it moves the misattributed band from 1685 px to
1633 and leaves the boundary 10 rows out. Its docstring has been corrected.

**Do not fix this by moving the camera** until the discriminator below is run.
The error is +16 / +10 / +10 / +10 / 0 across x, and at t=350 the far field is
2 rows HIGH while the near field is low — a single camera term cannot produce
that, and four previous camera attempts measured worse (§12.13, #29b). The
ladder now makes the honest experiment cheap: dump `dump_bands` for the phase,
and compare the port's row tops against the baked table row by row, for a frame
with geometry at several depths.

### 12.16 — the capture path drew the frame before the one it saved

§12.15 ended on a flag that changed nothing: `--shot-alpha` 0.0, 0.25, 0.5,
0.75 and 3.0 all produced the same PNG, md5 `2ceda940c3310195774ff2ad1ee11861`,
while a print inside `_capture_pending` showed `view_y` moving 602 game units
between them. The state moved and the picture did not.

**Cause — `Node3D` does not talk to the rendering server when you assign a
transform.** It puts itself on the SceneTree's pending-transform list, and that
list is flushed *after* the idle frame's `_process` calls. `_capture_pending()`
runs inside `_process` and calls `RenderingServer.force_draw()` there, so the
frame the server composed was built from the PREVIOUS flush: the camera and the
ship of the frame before. `override_alpha` + `_present()` had moved
`SkyRoadsCamera.position` and the ship's `Sprite3D.global_position`, and neither
had reached the server yet. Nothing about `force_draw()` was wrong; it drew
exactly what it had been told, one frame late.

The fix is `Main._flush_transforms(get_tree().root)` — a recursive
`Node3D.force_update_transform()` — in front of every `force_draw()` on the
capture path, the surface-ID pass included. The flag is per node rather than
inherited, so the walk has to visit the whole subtree.

**It works, and the capture is reproducible now.** Road 21 t=200, five alphas,
five different images, and two separate runs at 0.0 byte-identical:

```
alpha   md5                                 RGB>16   sid      (rows 34..128)
0.0     201431ce18140ece3fabfccaae79318d     9.3%     8.8%     (2690/30400)
0.25    904bef2561a9fdbf690f8f85bc12760a     9.3%     8.7%
0.5     e59bb9b89152390d7ba84777ec904398     9.1%     8.4%     <- best
0.75    065e1d50e91a00b04ffdd3accd37a2b8    10.7%    10.2%
1.0     6807cc3d9c936123702d7257f1818e05    10.3%     9.9%
(before the fix, every one of them: 2ceda940c3310195774ff2ad1ee11861)
```

That is #29b's non-reproducibility closed at last — the same build measuring
18.5% and 20.0% on consecutive runs was measuring whatever interpolation
fraction the frame loop happened to hold, because the pin never took effect.

**The default stays 0.0.** 0.5 wins this frame by 0.4 points of sid, which is
one frame on one road, and §12.14 is the whole lesson about tuning on one road.
0.0 is also the only fraction that means something — the tick the file is named
after. Changing it needs the sweep run across several roads first.

**What this did NOT explain.** The near-field defect is unchanged: the
`tunhigh.k5.0 -> floor.k0.0` band is still 1633 pixels, the same count §12.15
measured through the broken path, and the block top still starts at port 112
against reference 102 at the lane centre. So it is not an interpolation
artefact, and the ladder experiment §12.15 asks for is still the next step.

**What it did explain.** The ship/road disagreement shrank: the ship rows of the
confusion table fall from about 400 pixels to 226 (88 + 73 + 40 + 25). The
"port's road runs one to two ticks ahead of its own ship" reading in §12.15 was
partly this bug — the road is rebuilt from `_loop.play.z` every frame while the
ship is placed by a transform, so a stale flush moved one and not the other.

### 12.17 — every parity capture was compared against the NEXT reference tick

`tools/replay_frames.c` steps the game and then writes the frame under the
loop counter it entered the iteration with, so **`c_tN` holds the state after
N+1 ticks**. Confirmed with its own `SR_STATE=1` print — the file labelled
t=199 carries `z=0018474c`, which is the z the simulation reaches on tick 200
(`sra` sim, road 21, `data/routes/road_21.bin`) — and the file's own comment
claims the opposite ("matching the port's capture").

The port names its capture after `play.tick`, the number of ticks simulated.
So the published recipe

```
--shot-ticks 200   against   c_t0200.sid
```

compares the port's tick 200 against the reference's tick **201**. Road 21 at
that moment is falling 8 screen rows per tick, which is exactly the "the ship
is 8 rows high" of §12.15 — an artefact of the comparison, not of the port.

Aligned properly, the same capture measures better:

```
port t=200 vs c_t0199   7.8% of surface ids differ   <- correct pairing
port t=200 vs c_t0200   8.8%
port t=200 vs c_t0201  12.6%
```

**The golden dashboard test was never wrong**: `render_dashboard.gd:259` reads
the port's `tick + 1` capture for each C golden, which is the correct pairing.
Its stated reason — "presentation carries the ship forward into the tick being
simulated" — is not; the reason is this off-by-one. The numbers stand.

The file numbering is left alone deliberately: renaming the four checked-in
goldens means rewriting their `.import` files, and every one of those is pinned
to `detect_3d/compress_to=0`. **The rule to remember is that C's `c_tN` is the
port's `t(N+1)`,** and the recipes in this file and in STATUS say so now.

### 12.18 — the near-field defect, attributed: raised surfaces are not on the
### camera's pinhole at all

§12.15 measured the near-field error and could not attribute it. With the tick
alignment of §12.17 corrected and the capture of §12.16 fixed, the remaining
error is real and it has a clean shape.

**Method.** No screenshots. The retail span tables are the ground truth, so
compare them directly against the port's own projection. For the tun_high tier
(`seek_kind 5`, record 0 — the id `tunhigh.k5.0` the surface map reports), take
the span that covers the lane centre x=159 in every phase and every band:

```bash
/tmp/sr_dump_bands <retail> <phase> kindlines 5 \
  | awk -F, 'NR>1 && $3==0 && $7<=159 && $8>=159 {print $1, $6}'
```

and against it the port's own formula, which for a horizontal surface is
exactly the DOS one — `y200 = 9.569 + 235.636 * (1 - h) / d` — with
`h = FULL_BLOCK_Y = 0.432866` and the far edge of band `dr` at
`d = 2.550 + 8 - dr - phase/8`.

```
        retail   port    error        retail   port    error
dr4 p0     38    30.0    -8.0     dr7 p0     51    47.2    -3.8
dr5 p0     41    33.6    -7.4     dr8 p0     62    62.0    -0.0
dr6 p0     45    38.9    -6.1     dr9 p0     85    95.8   +10.8
dr9 p1     90   103.3   +13.3     dr9 p4    109   136.8   +27.8
dr9 p2     96   112.4   +16.4     dr9 p5    116   154.0   +38.0
dr9 p3    102   123.3   +21.3     dr9 p6    125   176.6   +51.6
```

**Read it as an effective height.** Invert the formula on the retail numbers,
`h_eff = 1 - (y - 9.569) * d / 235.636`, at phase 0:

```
dr4   dr5   dr6   dr7   dr8    dr9
.210  .260  .316  .376  .433   .504      FULL_BLOCK_Y = .4329
```

The tier's apparent height climbs steadily with proximity and equals
`FULL_BLOCK_Y` **exactly** at dr8 — the band one row nearer than the ship.
Farther than that the original draws the tier LOWER than a pinhole would;
nearer, higher; and in the nearest band, dr9, the pinhole runs away entirely
(+11 rows at phase 0 to +52 at phase 6) because its far edge passes within
1.05 units of the eye.

**So the near-field defect is not a wrong row, a wrong scroll phase or a wrong
block height.** It is the vertical twin of #28: the camera is a least-squares
pinhole through the DECK band edges, it reproduces those to 0.24 px, and the
original's raised surfaces are simply not on it. One camera cannot carry both,
exactly as no camera carries both the vertical pinhole and the horizontal cone.

**Do not fix this by moving the camera.** The deck is currently right; any
change that puts the tier where the table wants it moves the deck off. The
correction belongs where the horizontal one already lives — in
`make_dos_material`, as a height-dependent term applied to raised vertices
only.

**The shape a correction would take.** `h_eff ≈ h * (1.375 - 0.136 d)` fits the
phase-0 ladder to within 3%. Algebraically that is the same pinhole with height
`0.595 h` plus a constant screen offset of `235.636 * 0.136 * h ≈ 13.9 px` per
unit of height — one multiply and one add in the vertex shader. It is fitted to
ONE record of ONE tile kind at ONE column, so it is a candidate, not a change:
before shipping it, run the same ladder for the low block (kind 2), the tunnel
tier (kind 3) and the outer columns, and check it against §12.12's outer-column
measurements, which are probably the same effect seen in colour.

### 12.19 — the vertical warp, measured. Four roads, both metrics, all better.

§12.18's candidate is now in `SkyRoadsCamera.dos_y_scale()` and applied to
view-space Y in `make_dos_material`'s vertex stage, beside the horizontal cone
it mirrors. One line of shader: the vertex's height above the deck is scaled by
`g(d) = 1.23112 - 0.12108 d + 0.19879 / d`, clamped to `d >= 0.80` and
`g >= 0`. The deck itself is at height 0 and is therefore untouched, which is
what keeps the band edges the camera was fitted to exactly where they were.

Measured on four roads, at the tick alignment of §12.17 and through the fixed
capture of §12.16, over DOS rows 34..128:

```
                RGB > 16            surface ids
road 21 t=200   7.9% -> 1.7%        7.8% -> 1.6%
road  2 t=640   4.5% -> 1.5%       11.7% -> 8.7%
road 26 t=240   2.0% -> 0.5%        5.5% -> 4.6%
road  5 t=120   8.4% -> 2.0%       12.4% -> 6.3%
```

Nothing measured worse. The near-field boundary this started from — §12.14's
"which surface is wrong", §12.15's "measured but unattributed", the thing four
camera attempts made worse — reads:

```
reference                    port
y[ 34.. 95] floor.k0.0       y[ 34.. 94] floor.k0.0
y[ 96..128] tunhigh.k5.0     y[ 95..137] tunhigh.k5.0
```

One row, from sixteen.

**Why this is not "touching the camera on a hypothesis".** The camera is
unchanged: same focal length, same principal point, same 2.550 rows behind the
ship, and the deck lands where it always did. What changed is a term read off
the baked tables, in the same place and the same form as the horizontal cone
that was already there for the same reason — the original's projection is not
one pinhole, and X was already known not to be.

**What is left in the numbers.** Road 2's surface map still disagrees on 8.7%
where its picture disagrees on 1.5%; most of that is the `none` blind spot of
§12.15 (the reference map records only what `fill_record` writes) rather than
anything drawn wrong. The remaining RGB differences are 1-2% of road pixels,
which is the order of the single-row quantisation in the tables themselves.

**Still open.** `RoadMesh.ARCH_OUTER_PX` / `ARCH_BORE_PX` were measured at
phase 0 / dr7, where `g = 0.868`, and converted to world units with `PIXEL_Y`,
which is calibrated at the ship's own depth where `g = 1.000`. The arch now
goes through the same warp as everything else, and road 21 — a tunnel road —
improved by a factor of four, so it cannot be far wrong. It has not been
re-derived, though, and if the arch is ever re-measured the ladder has to be
divided out first.

### 12.20 — inside a tunnel is the worst frame in the game, and it is the arch

§12.19 asked whether the arch had been double-corrected. It has not: the warp
improves tunnel frames like everything else. Road 2, the same route, one frame
at the mouth and one from inside the vault:

```
                       RGB > 16          surface ids
t=710  at the mouth    7.7% -> 1.7%      9.3% -> 4.0%
t=741  inside          14.3% -> 10.2%   48.6% -> 44.9%
```

But inside a tunnel is still five times worse than anywhere else measured, and
the surface map says exactly what it is — every one of the top disagreements is
one arch band being taken for another:

```
reference        port             pixels
tunnel.k4.4      tunnel.k4.1      1979
tunnel.k4.4      tunnel.k4.2      1899
tunnel.k4.3      tunnel.k4.2      1897
tunnel.k4.3      tunnel.k4.1      1771
tunnel.k4.2      tunnel.k4.1      1205
tunnel.k4.5      tunnel.k4.0       640
```

Nothing is the wrong SURFACE — it is the vault throughout, in both engines. The
bands are in the wrong places, and two of them do not exist: `_tunnel` splits
the 46 slices of a column into FOUR bands at `TUNNEL_BAND_EDGES_*`, chosen to
reproduce the measured areas, and the original paints SIX. `k4.4` and `k4.5`
are therefore never emitted at all, which is why they head the table.

This is #31 — the sector geometry was never recovered — with a number attached
at last. The instrument for recovering it exists now. `dump_bands archlines`
gives every span of every kind-4 record, and asking which record owns the
TOPMOST pixel at each screen x gives the band boundaries directly, because the
port's slices are strips at the arch's outer height:

```bash
/tmp/sr_dump_bands <retail> 0 archlines | awk -F, 'NR>1 && $1==7 && $2==1'
```

At phase 0 / dr7, that reads:

```
ci0  rec6:x[0,14] rec2:x[18,66] rec3:x[70,79] rec4:x[80,84] rec5:x[85,86]
ci1  rec6:x[43,59] rec2:x[60,99] rec3:x[100,108] rec4:x[109,113] rec5:x[114,115]
ci2  rec6:x[90,100] rec2:x[101,129] rec3:x[130,137] rec4:x[138,142] rec5:x[143,144]
ci3  rec6:x[136,137] rec1:x[138,151] rec2:x[152,159]
```

Two things to settle before building on it. The bands are DIAGONAL ribbons
following the vault, not vertical slabs — rec2 at ci1 runs x[96,99] at y=64 and
x[60,62] at y=82 — so "the record that owns the topmost pixel" is the right
question for the port's strip model but throws away how they meet lower down.
And a record's x extent is wider than the 46-px column the port builds an arch
inside (ci1 spans 73 px), so the mapping from record to column is not 1:1 and
has to be worked out before any constant is changed.

### 12.21 — the sector geometry, recovered: the arch bands are radial lines

§12.20 left the tunnel interior as the worst frame in the game and named the
cause: four bands where the original paints six. #31 had called the missing
piece "the sector geometry" and could not recover it. It is recovered, and it
is not geometry at all.

**Method.** `dump_bands archlines` gives every span of every kind-4 record.
Rasterise the six of them in paint order into a screen buffer, per band and
column cell, and read off where the owner changes down each scanline. Plotting
the result makes it obvious — the boundaries are straight diagonals — and
converting each crossing to the radial ratio `(x - 160.5) / (y200 - 32)` makes
it certain:

```
                         phase 0   phase 2   phase 4   phase 6
column 0  2|3              -2.820    -2.819    -2.821    -2.821
          3|4              -2.454    -2.454    -2.454    -2.454
          4|5              -2.013    -2.012    -2.011    -2.011
column 1  2|3              -1.890    -1.890    -1.889    -1.889
          3|4              -1.571    -1.570    -1.570    -1.570
          4|5              -1.236    -1.235    -1.235    -1.235
column 2  2|3              -0.957    -0.956    -0.956    -0.956
          3|4              -0.687    -0.686    -0.685    -0.685
          4|5              -0.460    -0.460    -0.459    -0.459
column 3  1|2              -0.244    -0.243    -0.243    -0.242
```

The same to ±0.03 across bands dr4..dr8 and to **±0.002 across all eight scroll
phases**. They are fixed radial lines through **(160.5, 32)** — the lane cone's
own vanishing point, #28's `DOS_X_VANISH_Y`. The centre column has one
boundary and only two records; the others have three and four.

**Why the old model could not work, however the edges were chosen.** `_tunnel`
picked the band from the SLICE INDEX within the column, which is a position in
the lane. A radial line is a position on the SCREEN, and for a RAISED surface
the two are not the same thing — screen x depends on world X and depth, screen
y also on height, so the ratio moves with height along a fixed slice. It shows
up in the numbers: column 0's outermost boundary sits at lane offset -4.23,
which is off the road entirely. No table of slice indices can express that.

**The fix.** A vault quad carries its column + 1 in `UV2.y`; the road shader
computes the ratio per fragment and picks the record from
`SkyRoadsCamera.ARCH_BAND_RATIOS`. Colour comes from `sr_quad` rows 68..73
(`tables.c`), which is a V and not a ramp — `71,70,69,68,69,70` on the left
half, mirrored on the right — so both palettes are uploaded and the fragment
picks by which side of the centre it is on. `TUNNEL_ARCH_*` and
`TUNNEL_BAND_EDGES_*` are gone.

**Measured**, road 2 t=741, the frame from inside the vault:

```
                RGB > 16        surface ids
before §12.19   14.3%           48.6%
after §12.19    10.2%           44.9%
after this       6.4%           10.2%
```

and the bands now land where the reference puts them, one row out:

```
reference                    port
y[ 60.. 63] tunnel.k4.2      y[ 60.. 62] tunnel.k4.2
y[ 64.. 75] tunnel.k4.3      y[ 63.. 74] tunnel.k4.3
y[ 76.. 97] tunnel.k4.4      y[ 75.. 96] tunnel.k4.4
y[ 98..115] tunnel.k4.5      y[ 97..116] tunnel.k4.5
y[116..117] tunnel.k4.1      y[117..119] tunnel.k4.1
```

Roads 21, 2 and 26 are unchanged to the pixel — the fan only touches vault
quads — so this is a tunnel fix and not a global one.

**The two rims are NOT radial.** `k4.6` and `k4.7` split the mouth ring, and
the same measurement gives -2.194 ±0.527, -1.381 ±0.408, -0.634 ±0.289 for
columns 0..2 — an order of magnitude looser than the vault boundaries, which
are ±0.03. Whatever separates them is not a radial line, so the port still
emits one rim record and `k4.7` still shows up as absent. That is the honest
remainder, along with the one-row offset above.

### 12.22 — the "one-row offset" is not one, and must not be fitted away

§12.19 and §12.21 both ended by naming a residual one-row offset. It is not a
defect and there is nothing to correct.

**The comparison path is exact.** The ship sprite is blitted at DOS screen
coordinates with no projection in it, and its box is identical in both engines
at road 21 t=200 — `x[130,158] y[50,61]`. So the capture, the canvas mapping
and `sid_compare`'s sampling are all right, and any difference is in the road
geometry rather than in how it is measured.

**The bias is a fifth of a row.** Pairing every sid boundary that both engines
name the same way, down every column of five frames (n = 4071):

```
road  2 t=640   n= 981   mean -0.248 rows   100.0% within one row
road 26 t=240   n= 125   mean +0.072        99.2%
road  5 t=120   n=1032   mean -0.151        100.0%
```

and by depth the mean runs -0.09, -0.14, -0.35, -0.16, -0.28, -0.13 over DOS
rows 32..127 — no trend, and everywhere well under half a row. The silhouette's
x agrees to ±1 px, and at the lane centre the ladders are identical run for run,
block tops included.

So the ±1 row seen at individual boundaries is quantisation: a boundary whose
true position is at y = 95.6 falls in row 95 for one engine and 96 for the
other, and the reference's own position comes from a hand-baked table rather
than from a formula, so there is no "correct" rounding to match.

**Do not fix this.** Shifting the projection by the measured 0.2 rows would be
fitting a constant to a metric with nothing behind it, which is what #29b and
§12.13 did, twice, and measured worse for. The number to remember is that on
clean frames **100% of paired boundaries already agree to within one row**.

### 12.23 — the attract demo and the road-end fade, anchored to the binary

These were the last two things resting on the C reference alone. Both turn out
to be RIGHT; what was wrong is what they cited.

**The attract demo.** Disassembling `SKYROADS.EXE`:

- `main @0x021e` calls the intro and branches on its return: 0 — nobody
  touched a key — sets `[0x9602] = 3`, and `@0x026c` pushes **0** and calls the
  road loader, so the demo is always road 0. Non-zero opens the menu. There is
  no idle timer anywhere; `Menu.gd`'s header comment was the last thing in the
  tree still claiming one, and it is corrected.
- `@0x5525` pushes `ds:0x0dec` — `"demo.rec"` — reads all `0x18fe` bytes (6398,
  the retail file's exact size) into `ds:0x962e`.
- `@0xa49` is the consumer: it divides the ship's 32-bit z by **`0x666`** and
  reads ONE byte at that index, then takes `(b & 3) - 1` into `[0x933c]`,
  `((b >> 2) & 3) - 1` into `[0x9600]`, and `(b >> 4) & 1` for jump.
  `[0x933c]` is accel and `[0x9600]` is steer, from their own consumers:
  `@0x24ac` multiplies `[0x933c]` by `SPEED_ACCEL 0x4B`, `@0x254c` multiplies
  `[0x9600]` by `STEER_VEL 0x1D`.
- `@0x0385` jumps back to `0x219`, the intro call, so a demo that runs out goes
  back to the intro rather than to the menu.

Every one of those matches the port: `DEMO_BYTES_PER_SAMPLE = 1638` is `0x666`,
`Main._apply_replay_input` indexes `play.z / 1638`, `sra.demo.decode` unpacks
the same three fields in the same order, and `_end_intro` branches the same
way. The buffer covers `6398 * 1638 / 65536` = **159.9 rows** against road 0's
55, so it can never be read past its end.

**The road-end fade.** `fn_4b72(palette, direction, steps)` is called from
fourteen sites and every one pushes `0x24` — 36 — for steps, in both
directions; the single exception `@0x472b` pushes 0, an instant set. Its loop
(`fn_4315`) and the 27-tick road-completed hold (`fn_443d`, `@0x2c90`) call the
same per-frame wait `fn_4137`, so the fade's 36 steps are 36 of the ticks
`RoadEnd` already counts — **1.0 s at 36.0036 Hz**, which is what `FADE_SECS`
has always been. The constant is unchanged; its comment now cites the binary.

Nothing in the port changed for either. What changed is that "matches the C
reference" is no longer the reason to believe them.

### 12.24 — the second rim record: measured, and deliberately not emitted

§12.21 left `tunnel.k4.7` as the port's one unemitted arch record, worth 459
pixels of the surface map at road 2 t=741. Measuring it settles it as a
labelling artefact rather than a defect.

**The two rims are the same colour.** Both `k4.6` and `k4.7` carry `k = 66` in
the span tables, so `sr_quad[66]` resolves both to the same palette entry. The
split is invisible: emitting the second record would move no pixel, and the 459
is the surface map noticing that the port draws ONE quad where the reference
writes two records over the same colour.

**Only one of them is radial.** Their own edges, measured per band:

```
        rec6 left        rec7 left            width in ratio
ci0     -2.730 ±0.265    -2.171 ±0.532        0.092 / 0.086
ci1     -1.897 ±0.160    -1.438 ±0.408        0.087 / 0.088
ci2     -1.109 ±0.070    -0.647 ±0.289        0.101 / 0.097
```

Both are narrow wedges of the same angular width, ~0.09, but per band `rec6`
holds still (ci2: -1.127, -1.114, -1.103, -1.101 across dr5..dr8) while `rec7`
swings 0.3 and moves OUTWARD as the row approaches. `rec7` is tied to the bore
— a world-space opening whose projected width grows with proximity — not to
the screen, so the §12.21 fan cannot express it.

**And the port's rim is the right size.** The record map shows a gap between
the two rims at the lower rows, which reads like the port's full-face rim quad
overpainting. It is not: that gap is about which record CLAIMS a pixel, not
what colour lands on it. Removing the mouth quad entirely and re-measuring:

```
                with rim    without rim
road 2 t=710    1.7%        1.7%
road 2 t=741    6.4%        9.9%
```

So the quad is carrying its weight, and the honest conclusion is that emitting
`k4.7` means modelling a bore-edge band, in world space, to change no pixel and
improve one metric that is already known to be counting a labelling difference.
Not done, on purpose. §12.21's `_tunnel` comment and this section are the
record of why.

### 12.25 — the letterbox is geometry, and it stays

Listed for weeks as a mobile job: "at integer 5x scaling a 2992x1344 screen
shows 696px bars each side", with a proposed fix of `aspect=expand` plus a
fixed 320x240 `SubViewport`. Measured, the framing was wrong — there is no
fix, only a choice, and the choice is to keep it.

A 320x240 picture is 4:3. A modern phone is 2.23:1. **No scale factor fills one
with the other**; only cropping or distorting does. What the bars cost:

```
2992x1344   integer x5 -> 1600x1200   696 px sides   52.3% of screen unused
2340x1080   integer x4 -> 1280x960    530 px         51.4%
2778x1284   integer x5 -> 1600x1200   589 px         46.2%
1920x1080   integer x4 -> 1280x960    320 px         40.7%
```

Most of that is INTEGER scaling rather than the aspect ratio: letting the image
fill the height fractionally on 2992x1344 gives 1792x1344 and 40.1% unused,
which buys 12 points at the price of resampling a pixel game — the one thing
`window/stretch/scale_mode="integer"` exists to prevent. `aspect=expand` buys
the space by showing MORE WORLD than the 320x200 field of view, which is not
the original's picture and invalidates every number in this file.

So the three real options are: keep it, scale fractionally on mobile only
(soft pixels), or render into a `SubViewport` so the bars become paintable
decoration (same 52%, but deliberate — at the cost of moving the parity
capture path of §12.16 and the touch transform).

**Decided 2026-09-01: keep it.** Integer scaling, exact field of view, bars
where a 4:3 game puts them on a 21:9 screen. The item is closed as working as
intended rather than left open as a defect. Note for anyone reopening it: the
scale mode is a DISPLAY setting and parity runs are windowed at
`--resolution 640x480`, an exact 2x, so a mobile-only scale change could never
have shown up in a measurement either way.

### 12.26 — the unrouted roads are a FUEL problem, and the solver optimises the wrong thing

STATUS has called these seven "verification coverage, not defects — collision is
clean, so nothing makes them unwinnable" and "beam width is exhausted". The
first half is right for the wrong reason and the second half is wrong. **No
road routed by this section** — what it establishes is why they fail, which is
not what was assumed.

**Fuel is spent per DISTANCE, not per throttle.** `sim.step` burns
`(TANK_FULL // fuel_rows) * speed >> 16` every tick, unconditionally — airborne
too — and the ship covers `speed / 65536` rows in the same tick. The speed
cancels: a tank buys exactly `fuel_rows` rows however the road is driven.
Nineteen of the thirty roads are LONGER than their tank, and most carry many
supply tiles (floor nibble 9, which resets fuel AND oxygen to full when the
ship is grounded on one). Four of the seven unrouted roads are fuel-short:

```
road  rows  fuel_rows  headroom  supply tiles
 12    164     150       -14      1  (row 151, col 0)
 18    163     150       -13      1  (row 141, col 3)
 28    234     225        -9      0
 29    136     120       -16      1  (row  97, col 3)
 20    186     195        +9      0
 27    166     200       +34     82
 30    200     201        +1      0
```

**The beam never collects the single tile. Not once.** Instrumenting a full
search of each of 12, 18 and 29 for a fuel increase: **zero refuels**. It is
not that the tile is hard to reach — roads 14, 22 and 23 are fuel-short with
one to three tiles each and all three are routed. It is that these three put
the tile somewhere the beam has no reason to go. Road 18's sits in a one-row
deck-level slot: `4/0` full block at row 140, `0/9` supply at 141, `5/5`
tunhigh at 142, with a void at col 3 for the three rows before. The ship must
ride the block tops, drop about 40 px into a single-row gap, and carry on
through the bore. Every grounded visit to that column during a whole search was
at `y = 0x3C00`, block-top height — never the deck at `0x2800`. It goes over
the slot, every time.

**Road 28 has no supply tile at all and is still finishable.** The burn
TRUNCATES: `(q * speed) >> 16` with `q = 133` is **zero** for any speed below
493, and the ship still covers 0.0075 rows a tick. Nine rows of free crawling
costs 1199 ticks against road 28's 5000-tick oxygen budget. So the fuel-short
roads have two solutions — the tile, or driving slowly enough that fuel is free
— and **no road in the game is unwinnable**. That is the same conclusion STATUS
reached, but from the wrong premise: collision being clean says nothing about
whether the tank reaches the end.

**Which is why beam width was never the problem.** The beam's niche is keyed on
`(row, column)` and within a niche it keeps the state furthest along, which is
always the fastest. The thrifty line and the slow drop are discarded before
they can pay off, at every width. Three changes were tried and are recorded
here so they are not tried again blind: fuel in the de-dup key (`s.fuel >> 12`),
a speed bucket in the NICHE rather than just the key, and a waypoint
decomposition that searches to the refuel first and onward second. None routed
a road, and the finer niches made 28 and 29 measurably WORSE by fragmenting the
beam — they now stall at rows 15.7 and 17.0.

**And two of them are not only a fuel problem.** Roads 28 and 29 stall at rows
~16-17 whatever the fuel handling, so they have an early obstacle as well.
Roads 12 and 18 reach 160.9 and 163.0 of 164 and 163 — those two fail at the
end and at the end only, on fuel.

What would actually be needed: a search whose objective is not progress. Every
one of these roads is a constrained problem — reach a specific cell, or hold
under a speed for a while — and a beam that ranks states by how far along they
are cannot express either. That is a different solver, not a wider one.
