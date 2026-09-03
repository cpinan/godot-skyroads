# PLAN — what comes after parity

Everything in `BUGS.md` is about making this port agree with 1993. This file is
the opposite: four things the original never did, wanted by the person who
commissioned the port, listed 2026-09-01.

Item 1 is part-done and item 4 is BUILT, both 2026-09-02 and both saying so
inline; 2 and 3 are untouched. The order below is a recommendation, not a schedule —
each item says what it costs and what it puts at risk, because three of the
four touch the projection or the input path, which is where every hard-won
number in `BUGS.md` lives.

**The one rule that applies to all four.** The parity work is measured through
`--shots` / `--surface-ids` against the C reference at a fixed 320x240 canvas.
Any feature that changes the camera, the field of view, the tick rate or the
input mapping must leave a way to run the old path unchanged, or the gate stops
meaning anything. `LaunchOptions.is_parity_capture()` is the existing hook for
exactly that and should be the one used.

---

## 1. Polish the joystick controls

**Why first: it is the only one of the four that risks nothing.** No camera, no
projection, no new screens. It is also the item with a real complaint behind
it — the touch stick was found unusable on a Pixel 10 Pro the first time this
build ran on hardware, and that turned out to be a menu bug (§12.26 in the
commit log, `Menu._keys_for_tap`), not the stick. Nobody has yet played long
enough to say whether the stick itself is good.

What exists: `scripts/TouchControls.gd`. The drawn circles are a hint; the hit
areas are the whole left and right halves. `STICK_RANGE = 27.0` canvas pixels is
full deflection and `PlayerInput.DEADZONE = 0.45` bites at about 12 px. Both
feed `PlayerInput.from_axes`, the same function the joystick and mouse devices
use, so the simulation receives the same three integers it always did.

Worth doing:
- ~~A real gamepad pass.~~ **Done 2026-09-02.** Device sampling moved out of
  `Main` into `scripts/app/InputDevices.gd`, and the pad path grew what a
  modern controller needs: a `PAD_NOISE_FLOOR` of 0.12 below which an axis is
  not moving at all (a resting stick reports a few hundredths on both axes, and
  the simulation only sees -1/0/+1, so without a floor a worn stick steers
  slowly and for ever), the d-pad overriding the stick rather than being summed
  with it, and A/B/X/Y, both shoulders and both analogue triggers all jumping —
  the original's joystick had two buttons and either of them jumped, a modern
  pad has eight, and a player who presses the wrong one reads it as the pad not
  working. **Still unplayed: no controller has been plugged in.**
- Tune `STICK_RANGE` and `DEADZONE` against actual play rather than against the
  reasoning in the comment. **Not done — this one needs a human and a phone.**
- ~~Consider a fixed-origin stick as an option.~~ **Done 2026-09-02:**
  `--fixed-stick` sets `TouchControls.fixed_origin`, which anchors the stick to
  its drawn circle instead of to the thumb that starts the touch. A flag rather
  than a setting, because which one should be the DEFAULT is the open question
  and a flag can be A/B'd in one session without changing the cfg format.
  Covered by `tests/test_touch.gd`, which asserts the two modes differ on the
  same gesture.

**What is left of this item is the part only a person can do**: play both stick
modes on the Pixel, with and without a pad, and say which should ship. The code
to try them is in; the answer is not.

Risk: none to parity. `PlayerInput` is pure and tested; changing thresholds
cannot change what the simulation does with a given input, only which input a
gesture produces.

---

## 2. Full-screen on mobile

**Read `BUGS.md` §12.25 before touching this.** It is the measured version of
this exact request, and it ends in a decision to keep the letterbox.

The facts: a 320x240 picture is 4:3, a modern phone is about 2.23:1, and no
scale factor fills one with the other. On a Pixel 10 Pro XL at integer 5x the
game is 1600x1200 inside 2992x1344 and 52.3% of the screen is black. Letting it
fill the height fractionally recovers 12 points and resamples every pixel of a
pixel game. `aspect=expand` recovers the rest by showing MORE WORLD than the
original's field of view, which invalidates every number in `BUGS.md` on the one
platform nobody measures.

So "adapted to full screen" has to mean one of these, and the choice is the
work:
- **Fill the height, accept soft pixels.** One line of config, mobile only.
  Cheap, reversible, and it makes the game look like every other emulated
  retro game on a phone.
- **Paint the bars.** Render into a fixed 320x240 `SubViewport`, put a bezel or
  artwork in the margins. Keeps integer scaling and the exact field of view.
  Costs: it moves the parity capture path (§12.16 is about how easily that
  breaks) and the touch transform.
- **Widen the field of view on mobile only**, and accept that mobile is no
  longer pixel-comparable to the reference. Honest if it is written down.

Recommendation: the `SubViewport` route if it is worth real work, the
fractional scale if it is not. Do not do `aspect=expand` without deciding, in
writing, that mobile parity is being abandoned.

---

## 3. First-person mode

The largest of the four, and the one furthest from what the port has been so
far — every camera constant in `SkyRoadsCamera.gd` was derived from the
original's baked span tables, and a first-person camera throws all of them away
by definition.

What is in the way, in order:
- **The road is not modelled for it.** `RoadMesh` builds geometry that is
  correct as seen through the DOS projection: block tops, front lips and side
  edges are emitted only where the original's composer would have drawn them
  (`_emit_cell` skips the outward-facing side edge because the DOS renderer
  never emits it). From inside the cockpit those omissions become holes.
- **The ship is a 2D blit.** `ShipSprite` places a sprite by the original's
  screen formula and never depth-tests it, which is the whole of §8.2 and
  STAGE X. In first person the ship is either invisible or has to become real
  geometry, which does not exist.
- **The three projection warps stop applying.** `dos_x_scale`, `dos_y_scale`
  (§12.18) and the arch fan (§12.21) are corrections FROM a fitted pinhole TO
  the original's hand-built fake perspective. In a first-person camera they are
  not corrections of anything and must all be off.

Doing it properly means a second, plain, honest 3D camera with the DOS warps
disabled, the omitted faces emitted, and a ship model. That is a feature, not
a tweak, and it should live behind a flag with the DOS path untouched and still
the default. The gate must keep running against the DOS path.

Do not attempt it by adjusting the existing camera. Five attempts at moving
that camera are recorded in `BUGS.md` (#29b x3, §12.13, §12.15) and all of them
measured worse.

---

## 4. Level editor — BUILT 2026-09-02

`--editor NAME` (`scripts/RoadEditor.gd`, `scripts/model/RoadEditModel.gd`),
covered by `tests/test_editor.gd`. It is reached by that flag and by nothing
else: the seven menu screens are compared against the reference at 0 differing
pixels and an eighth item would fail `tests/render_menu.gd`, so the editor
never appears on a menu. What was built against the list below:

- **The grid**, in the game's own 320x240 canvas, drawing the same glyphs
  `sra ascii_map` prints so the two read against each other. Shape and effect
  are separate brushes, and the effect is written into whichever nibble the
  SHAPE reads — blocktop for a block, surface for a floor — which is the one
  trap the format sets for a grid editor.
- **Live validation**, and it is the reason the rest is worth having.
  Structural faults are ERRORS and `P` refuses to play: no tunnel in the last
  row to finish in, a hole under the spawn, geometry above 5 (the composer
  sends it to a return, so it is invisible AND has no collision), a gap row
  with gravity at or above 20 where the ship cannot jump at all.
  **Fuel and oxygen are WARNINGS, never errors** — the arithmetic below said
  roads 14 and 28 are 9 and 6 rows longer than their tank with no supply tile
  anywhere, and road 14 is replayed to completion by the gate on every run, so
  the estimate is first-order and the shipped game beats it. That demotion was
  forced by `tests/test_editor.gd`, which runs every rule against all 31
  shipped roads and fails if any of them is called broken.
- **The solver button** (`C`). `sra solve` grew a `--road-json` option —
  building a `Road` from an exported JSON needs no retail data — and the editor
  runs it as a separate process, polled from `_process`, so a long search does
  not freeze the grid. `analysis/` is a sibling checkout, so an exported build
  will not have it and the button says exactly that rather than doing nothing.
  Its verdict wording is asserted: a route found is a proof, finding none is
  reported as "no route found (not proof that none exists)".
- **`user://levels/`**, never `res://data/levels/`. `--level-file` plays any of
  them, which is also how the play-test drives one: it saves first and loads
  from the FILE, so what is tested is what would ship.

Four more landed the same day, after the first road was authored with it and
the gaps were obvious:

- **The solver's furthest row.** `sra` prints `furthest row 34.7/60` on a
  failure and the editor was throwing it away. It is in the message now and the
  CURSOR JUMPS THERE, which is the answer to "why not" far more often than the
  verdict is.
- **Undo**, sixty steps, `U` and `shift+U`. The header travels with the grid,
  because undoing a gravity change and undoing a brush stroke are the same
  gesture to the person pressing the key. A fill is one step however many cells
  it touched, and repainting a cell with what it already holds banks nothing.
- **`I` / `D`** insert and delete a row, so the middle of a road can be
  restructured without retyping it. Insert adds FLOOR, for the same reason `]`
  grows with floor.
- **`A` fills** the cursor's row, or every row between the mark (`M`) and the
  cursor. A three-row band of ice is three keystrokes rather than twenty-one.

The key list stopped fitting the status band, so `H` opens it on a page of its
own.

Still not done: no copy/paste, no palette editor (a road borrows the 72 colours
of the first shipped road of its `world`, and every plain floor is nibble 3), no
overview of a long road, and no reachability check between adjacent rows — that
last one is the solver's job. It is keyboard and mouse only and unusable on a
phone, which should be written down rather than fixed.

### The original plan

The most self-contained of the four: it touches no camera, no simulation and no
parity path, and it can be built without opening any of them.

The format is already understood and already round-trips. A road is
`rows x 7` u16 cells, high nibble the shape (0 floor, 1 tunnel, 2/3 low block,
4/5 high block) and low nibble the surface (0 void, 2 sticky, 8 ice,
9 supplies, 10 boost, 12 burning), plus gravity, `fuel_rows` and
`oxygen_secs`. `data/levels/road_NN.json` is exactly that, `RoadData.load_json`
reads it, and `analysis/sra` writes it.

What a useful editor needs beyond a grid:
- **Live validation, because the road format lets you build roads nobody can
  finish.** A tank buys exactly `fuel_rows` rows however the road is driven,
  and four of the shipped roads are longer than their tank and depend on a
  single supply tile (that finding is §12.26). An editor that does not say
  "this road is 14 rows longer than its fuel and has no supply tile" will
  produce unplayable roads on the first try.
- **A solver button.** `analysis/sra solve` already answers "is this
  completable", authoritatively in one direction: a route found is a proof,
  because it is replayed from scratch. Wire it up and an author can ask.
- **Somewhere to put custom roads.** The shipped `data/levels/` is derived from
  Bluemoon's `ROADS.LZS` and `LICENSE` carves it out; user-made roads are the
  author's own work and belong in `user://`, not next to it.

Risk: low, provided the editor writes `user://` and never `res://data/levels/`.

---

## What none of this changes

The 475-check gate, the three-engine differential, and the parity captures are
the reason the port can claim what it claims. Every item above should leave
`THREEWAY=1 tools/verify.sh` green and the DOS path reachable and default. If a
feature cannot do that, it needs its own flag — and saying so in `BUGS.md` is
part of the work, not paperwork after it.
