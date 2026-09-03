# PERF — where the frame time and the reading time go

Written 2026-09-02. Everything with a number in it was measured on this machine
(M1 Max, macOS, `gl_compatibility`, a 640x480 window over the 320x240 canvas),
not reasoned about. The method is at the bottom so the numbers can be redone.

The headline: **there was no frame-rate problem to solve.** The port renders a
road in 17 draw calls and spent about 1 ms of CPU per frame before this pass and
about 0.7 ms after it. What follows is therefore a list of costs removed because
they were pure waste — on a phone's battery, on a low-end device, and on the
reader — not because anything was dropping frames.

---

## 1. Where a frame went, before

Uncapped (`Engine.max_fps = 0`, vsync off), road 21 on its recorded route, 400
frames per sample:

| what is running | ms/frame | fps |
|---|---|---|
| everything | 1.01 | 991 |
| dashboard hidden | 0.70 | 1423 |
| `_present()` not called at all | 0.66 | 1524 |

So the per-frame cost divided as:

* **0.66 ms** — the engine's own frame, `GameLoop._process` and the simulation.
* **0.31 ms — the dashboard.** 31% of the whole frame, and the single largest
  thing the port itself did.
* **0.04 ms** — everything else in `_present()`: the camera, the ship sprite,
  the visibility window, the two debug overlays. Effectively free.

The renderer was never the question: **17 draw calls, 184 nodes, 2,720
primitives, 10.5 MB of video memory.**

## 2. Why the dashboard cost that

`Dashboard._draw` stamps **one `draw_rect` per lit pixel**. The shapes come
straight out of the retail art, so the count is fixed and knowable:

| gauge | segments | lit pixels at full |
|---|---|---|
| speedometer | 34 | 1,829 |
| oxygen | 10 | 223 |
| fuel | 10 | 229 |
| GRAV-O-METER | 4 digits | up to 80 |
| jump-o-master lamp | 1 | 130 |
| progress bar | 30 columns | 30 rects |

Up to ~2,500 canvas commands, rebuilt from GDScript. The cost was not the
stamping — it was that `Main._present()` calls `Dashboard.update()` **once per
rendered frame**, and `update()` called `queue_redraw()` unconditionally. At 120
fps the dashboard was redrawn 120 times a second to show a picture that changes
at most 36 times a second, and in practice a handful.

**Fixed.** `update()` builds a signature of everything `_draw()` reads — the
three gauge segment counts, the progress step count, the gravity value, the
assist lamp, the end state, the warning blink phase, and
`authentic_gravity_window` — and only calls `queue_redraw()` when it changes.

| | before | after |
|---|---|---|
| whole frame | 1.01 ms | **0.71 ms** (−29%) |
| dashboard's share | 0.31 ms | **0.03 ms** (−90%) |

`authentic_gravity_window` is in the signature deliberately:
`tests/render_dashboard.gd` flips it between two otherwise identical states and
compares the two frames, so a signature without it would hand that test the same
picture twice and the BUGS #41 check would silently stop testing anything.

## 3. What a road start cost

| | ms |
|---|---|
| `RoadMesh.build`, road 27 (166 rows, 120,732 verts, 265 meshes) | 31.0 |
| `RoadMesh.build`, road 11 (199 rows, 86,532 verts) | 22.4 |
| `RoadMesh.build`, road 21 (130 rows, 52,338 verts) | 15.2 |
| `RoadMesh.build`, road 2 (115 rows, 21,336 verts) | 8.5 |
| `Backdrop.flattened` (320x138, per-pixel GDScript) | 3.3 |
| eight shader sources built | 3.5 |
| five shadow stencil textures | 0.3 |

About 40 ms of CPU here, which is fine. What is **not** fine is invisible in
that table: each of those eight `Shader` objects was a **new** resource with its
own source string, so the GL driver compiled eight programs — on every road
start **and on every death**, because `_begin()` rebuilds the world. On desktop
that is a few ms; on Android a program compile is tens of milliseconds and it
lands exactly on the restart after a crash, which is the moment a player is most
sensitive to.

**Fixed, twice:**

* `SkyRoadsCamera.make_dos_material` caches by render mode. The whole game uses
  **three** shader sources — opaque, the transparent cover pass, and the debug
  overlay — and `clip` (`CLIP_NONE` / `CLIP_FAR` / `CLIP_NEAR`) became a
  `uniform int` instead of a fourth and fifth source variant. Verified at
  runtime: the cache holds exactly three entries after a full road. Restarting a
  road now hands the driver **zero** new programs.
* `ShipSprite`'s two surface-ID materials are built lazily, on the first
  `set_sid_mode(true)`, and share one `Shader` (they differed only in two
  uniforms). They are only reachable through `--surface-ids`, so every player
  was paying two program compiles per road start for a parity tool.

Writing `ALPHA` at all is what puts a Godot spatial shader in the transparent
queue, so that one cannot become a uniform — which is why there are three
sources and not one. The comment in the file says so.

## 4. Still on the table, in the order to do them

1. **Nothing, until a device complains.** After the three fixes the port uses
   ~0.7 ms of a 16.7 ms budget. The next items are worth real money only if a
   low-end phone says so, and the way to find out is `adb` frame timing on the
   Pixel, not more desktop measurement.
2. **Bake `Backdrop.flattened` offline.** 44,160 GDScript `get_pixel` /
   `set_pixel` calls per road start to undo Godot's `fix_alpha_border`. Either
   turn that flag off in the world textures' `.import` and `convert()` to RGB8,
   or flatten the PNGs in `tools/` and ship them flat. Saves 3.3 ms per road
   start here, more on a phone. `tests/render_backdrop.gd` covers it.
3. **Gauge segments as prebuilt textures.** 2,500 `draw_rect` calls become ~60
   `draw_texture_rect`. Only worth it if item 1 says the redraw still hurts, and
   it carries the one real risk in this list: the dashboard is checked at **0
   differing pixels**, and a stretched texture does not have to rasterise
   identically to a column of 1x1.2 rects. Do not do it blind.
4. **`RoadMesh._quad` allocates a six-element `Array` per quad** — about 24,000
   allocations for road 27 — and pushes vertices one at a time through
   `SurfaceTool`. Worth 10-20 ms of a road start at most.
5. **265 `MeshInstance3D` for a road, ten of them visible.** Recycling ten
   instances would cut nodes and memory. It would also touch `update_window()`,
   which is where the DOS draw order lives, so the payoff has to be real before
   the risk is taken.

---

# READABILITY

State before this pass:

| lines | code | comment | %cmt | file | longest function |
|---|---|---|---|---|---|
| 1048 | 686 | 279 | 29 | `scripts/Main.gd` | `_begin` **154L** |
| 629 | 380 | 184 | 33 | `scripts/Menu.gd` | `_ready` 52L |
| 524 | 285 | 204 | 42 | `scripts/RoadMesh.gd` | `_emit_cell` 88L |
| 510 | 402 | 41 | **9** | `scripts/SkyRoadsPlay.gd` | `step` **167L** |
| 391 | 198 | 151 | 43 | `data/SkyRoadsCamera.gd` | shader source 104L |
| 283 | 178 | 75 | 30 | `scripts/ShipSprite.gd` | `sync` 54L |
| 266 | 156 | 80 | 34 | `scripts/Dashboard.gd` | `_draw` 59L |
| 178 | 114 | 43 | 27 | `scripts/CollisionDebug.gd` | `_rebuild` 70L |
| 161 | 104 | 41 | 28 | `scripts/app/LaunchOptions.gd` | `parse` 77L |

## Done

**1. `Main.gd` was seven files in a trench coat.** Its own header said
"deliberately thin", and it was — the capture path and the touch shell arrived
later. 1,048 lines holding command line and boot, world assembly, HUD assembly,
fade transitions, the parity capture path, input device sampling, the phone
pause menu, and the recording dump; `_begin()` alone was 154 lines that loaded a
level, built a 3D scene, built a HUD, built the touch layer, started the loop
and printed a summary.

Split into, all pure moves:

* `scripts/app/CaptureService.gd` (226L) — `--shots`, `--surface-ids`,
  `--menu-shot`, `--roadend-shot` and the transform flush. Only
  `tools/verify.sh` ever executes any of it.
* `scripts/app/InputDevices.gd` (112L) — reading the keyboard, pad, mouse or
  on-screen stick.
* `scripts/PauseMenu.gd` (84L) — the phone's three-row pause screen: its
  geometry, its drawing and its hit test. What each row MEANS stayed in the
  shell, as `_on_pause_choice`.
* Inside `Main`, `_begin` became `_load_replay_input`, `_build_world`,
  `_build_hud`, `_build_touch_ui` and `_start_loop`.

`Main.gd` is 846 lines and its longest function is `_unhandled_input` at 76.

**2. The shader source was built from twelve positional `%` arguments** and
could not be checked by eye. It is `{named}` placeholders through
`String.format` now, with a `_f()` helper — because `str(1.0)` is `"1"`, which
GLSL reads as an int literal and refuses to multiply by a float. The same change
is what made the shader cache possible.

**3. `_read_device() -> Array`** was read back as `inp[0]`, `inp[1]`, `inp[2]`.
It is `InputDevices.sample(...) -> Vector3i` now: `inp.x`, `inp.y`, `inp.z`.

**4. One dead field** (`_hold`) removed.

## Not done, and worth doing

**5. `SkyRoadsPlay.step` is 167 lines at 9% comments** — the longest and least
annotated function in a codebase whose whole claim is annotation. It is a
transcription of the C, so its shape is deliberate and should not be broken up;
but section markers naming the phases it runs through (input, tanks, swept move,
surface effects, autopilot, end tests) would make it navigable without changing
a line of logic.

**6. Three `.gd` files live in `data/`** — `RoadData.gd`, `SkyRoadsCamera.gd`,
`skyroads_constants.gd` — next to the JSON and PNG the folder is named for. They
are the three most-imported scripts in the project. `scripts/core/` is where a
reader looks for them.

**7. File naming is split down the middle**: `skyroads_constants.gd` in snake,
`SkyRoadsCamera.gd` and `RoadData.gd` in Pascal. Godot's own style guide says
snake_case for files, and `gd_audit` GDBP-101 flags every new file for it. Every
script in `scripts/` is Pascal, so the three files added in this pass carry a
`# gd-audit: ignore GDBP-101` line rather than becoming a third convention.
Picking one and doing the rename is a real job, not a per-file decision.

**8. `scripts/` is flat** — 19 files at the top level, plus `app/` and `model/`
which hold two and three. `shell/` (Main, Menu, Intro, RoadEnd), `render/`
(RoadMesh, ShipSprite, Backdrop, Dashboard, CellLabels, CollisionDebug, Text8x8)
and `input/` (TouchControls, Controls) would make the tree answer "where does
drawing happen".

**9. The same magic numbers are re-typed in three files.** `46` slices per cell
and `23` for the lane centre in `RoadMesh` and `CollisionDebug`; `0x380` (the
ship's support probe) four times in `ShipSprite`; `0x5F` / `0x2E` (lane from
pixel x) in `CellLabels`, `CollisionDebug` and `SkyRoadsPlay`; `- 3.5` (column
to world x) in four places. They belong in `skyroads_constants.gd` beside
`COL_W` and `SHIP_HALF_W`, which are already there.

**10. Four files are over 40% comment** — `PlayerInput` 56%, `SkyRoadsCamera`
43%, `GameLoop` 43%, `RoadMesh` 42% — and `RoadMesh` opens with 66 lines of
header before its first statement. This is not padding: it is the provenance
that makes the port's claims checkable, and it should not be deleted. But the
longest derivations already have `BUGS.md` section numbers, and the ones that do
could be cut to a one-line claim plus the `§` pointer. That is a judgement call
and it is the author's to make — flagged, not recommended.

**11. Two files were called `docs/STATUS.md`.** This repo's is current; the one
at the project root (outside the repo) was three days stale and said the repo
was private and the next action was a merge that had already happened.

---

## Method

```bash
# frame cost: uncapped, 400-frame samples, hide the dashboard between them
godot --path . --resolution 640x480 --script res://tests/_perf_scratch.gd -- --replay 21
```

The scratch script instantiates `scenes/Main.tscn`, sets `Engine.max_fps = 0`
and `VSYNC_DISABLED`, waits 120 frames for the road to settle, then times
`process_frame` over 400-frame windows while toggling `Dashboard.visible` and
`Main._in_game`. **Vsync must be off**: at 120 fps every variant measures 8.3
ms/frame and the whole difference is invisible. Road 21 because it has a route —
roads 12, 18, 20, 27, 28, 29 and 30 do not, and `--replay` on one of them backs
out to the menu, after which the script is timing the menu.

`Performance.TIME_PROCESS` was tried first and is not usable here: it reported
94 ms/frame against a measured 8.75 ms wall, i.e. it disagrees with itself by an
order of magnitude in this harness. Wall time across N `process_frame` awaits is
what the numbers above are.

Build costs come from a headless script that times `RoadMesh.build` per road and
reads `surface_get_array_len(0)` back off each committed mesh.

Both scratch scripts were deleted; they are three dozen lines each and
reproducing them from this section is quicker than maintaining them.
