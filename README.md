# Godot SkyRoads

A port of **SkyRoads** (Bluemoon Interactive, 1993) to Godot 4 — rebuilt from
the original's own data and checked, frame by frame and tick by tick, against
a reference implementation of the DOS engine.

The aim was not "a game that plays like SkyRoads". It was a port whose
simulation agrees with the original on **every field of every tick**, and whose
screen agrees with it pixel for pixel wherever that is achievable.

![Road 2](docs/screenshots/play_road02_tunnel.png)

---

## How close is it?

Close enough that most comparisons are a diff of zero. The left half of each
image below is the DOS engine; the right half is this port, driven by the same
recorded input to the same tick.

**Road select — pixel-identical, 0 differing pixels of 64,000:**

![Road select comparison](docs/screenshots/compare_menu.png)

**Driving into a tunnel** — the arch profile is decoded from the original's
span tables, not modelled by eye:

![Tunnel comparison](docs/screenshots/compare_tunnel.png)

**A dark world** — the backdrop, its stars, and the road's shading:

![Road 26 comparison](docs/screenshots/compare_road26.png)

**A crash** — the explosion art is byte-identical to the original's sprite
cells, and the animation runs on the same counter:

![Explosion comparison](docs/screenshots/compare_explosion.png)

Measured parity, as of the last verification run:

| what | result |
|---|---|
| Simulation vs C and Python reference engines | **46,502 ticks, 24 fields, three engines, identical** |
| Dashboard band vs the DOS frame | **0 differing pixels** across a whole run |
| Menu screens (road select, settings, help) vs DOS | **0 differing pixels** |
| Backdrop vs its source art | **0 differing pixels** |
| Road geometry, road 2 | ~6% of road pixels, thin one-pixel edges |

The remaining road-geometry difference is documented rather than hidden — see
[`docs/BUGS.md`](docs/BUGS.md), entries #29b and #29c.

---

## The game

| | |
|---|---|
| ![Main menu](docs/screenshots/menu_main.png) | ![Road select](docs/screenshots/menu_road_select.png) |
| Main menu | Road select — 30 roads across 10 worlds |
| ![Settings](docs/screenshots/menu_settings.png) | ![Help](docs/screenshots/menu_help.png) |
| Settings — keyboard, joystick or mouse | Help |
| ![Road 1](docs/screenshots/play_road01.png) | ![Road 5](docs/screenshots/play_road05.png) |
| Road 1 | Road 5 |
| ![Road 16](docs/screenshots/play_road16.png) | ![Road 26](docs/screenshots/play_road26.png) |
| Road 16 | Road 26 |

---

## Running it

You need Godot 4.4 or newer (developed against 4.7) and the retail SkyRoads
data — see [Game data](#game-data) below.

```sh
godot --path .                            # intro, menu, play
godot --path . -- --road 7                # straight into road 7
godot --headless --path . -- --replay 1   # replay road 1's solved route
```

**Controls** follow the original, including its four diagonal keys — one key
meaning "steer *and* throttle", because many keyboards cannot report three
simultaneous presses:

| | |
|---|---|
| Arrows | steer, throttle, brake |
| `Q` `E` `Z` `X` (or Home/PgUp/End/PgDn) | the diagonals |
| Space | jump |
| `P` | pause |
| `L` / `C` | object IDs / collision overlay |
| `F2` or `R` | dump a replayable recording of this run |

Joystick and mouse are selectable on the settings screen, as in the original.

---

## Game data

This repository contains **no retail game files**. `data/` holds derived
exports — PNG, JSON, Ogg — produced from a copy of the 1993 release by the
analysis toolkit that lives alongside this project.

SkyRoads was released as freeware by Bluemoon Interactive and is still
distributed by them. The derived assets here are included so the port is
runnable and reviewable; they remain the work of Bluemoon Interactive, and
nothing in this repository is offered under a licence that could grant rights
to them. The code is the part this project claims.

---

## How it was built

The port is checked against a reference implementation of the DOS engine
rather than against screenshots or memory. Three things follow from that.

**The simulation is bit-exact.** A three-way differential runs the same input
through the C reference, a Python model and this GDScript implementation and
compares 24 state fields on every tick — position, velocity, fuel, oxygen,
collision flags, the lot. 46,502 ticks over the 30 shipped levels and 80
randomised roads, with no disagreement.

**The renderer is derived from the original's tables, not fitted by eye.** The
DOS game has no 3D: every scanline of every tile shape is a span list baked
into `TREKDAT.LZS`. Those tables were decoded to recover the projection —
which turned out to be a vertical pinhole *plus* a separate horizontal cone
that no single camera reproduces — and the tunnel arch, the block faces and
the band ordering all come from the same source.

**Findings are recorded, including the wrong ones.** [`docs/BUGS.md`](docs/BUGS.md)
is the audit trail. Several defects turned out to be misdiagnosed: a reported
"near-row darkening" did not exist (the reference paints one colour at every
distance — the real fault was two swapped block faces), and "chunky blue stars"
were not stars at all but the sky's black rendering as a texture-importer
artefact. Fixes that were tried and *measured worse* are written down too, so
nobody repeats them.

---

## Tests

```sh
./verify.sh                    # 336 checks, 14 suites
THREEWAY=1 ./verify.sh         # + C vs Python vs GDScript on real levels
```

`verify.sh` runs three passes, because a suite run alone lies in two
documented ways: a syntax error in an unreferenced file ships green, and a
suite that dies before asserting prints no failures. Every suite must print a
positive `Result:` line.

| suite | covers |
|---|---|
| `test_physics` | the simulation against golden traces |
| `test_menu` | shell navigation, diffed step-by-step against the C engine |
| `test_hud` | every dashboard readout, at its boundaries |
| `test_audio` | music and sfx assets, loop points, song sequence |
| `test_input` | keyboard, joystick and mouse mapping |
| `test_occlusion` | what hides the ship — including inside a tunnel |
| `render_menu`, `render_dashboard`, `render_backdrop` | pixels, against frames the reference engine drew |
| `test_geometry`, `test_data`, `test_timing`, `test_launch_options` | mesh, level data, fixed-step loop, CLI |

The pixel suites compare against **golden frames produced by the reference
engine**, not against this port's own past output — so drift is measured
against the original, not against yesterday.

New suites in this project are mutation-tested: the code is deliberately
broken, the tests are confirmed to fail, and the break is reverted.

---

## Layout

```
scripts/          the shell, the renderer, the simulation
  model/          pure logic, no scene tree: MenuModel, HudModel, PlayerInput
  app/            LaunchOptions (the command line)
data/             derived assets + the recovered camera and tables
tests/            suites, fixtures, and golden frames from the reference
docs/parity/      before/after evidence for each fidelity fix
```

`scripts/SkyRoadsPlay.gd` is the simulation and is proven bit-exact — it is
not edited without a failing three-way trace to justify it.

---

## Credits

**SkyRoads** is by **Bluemoon Interactive** (Jaan Tallinn, Marko Kaasik,
Ivar Annamaa), 1993. This is an unofficial port. All game design, artwork and
music are theirs.
