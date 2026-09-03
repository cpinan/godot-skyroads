# gd-audit: ignore GDBP-101 — every script in scripts/ is PascalCase; a lone
# snake_case file would be a third convention, not a fix. See docs/PERF.md.
# The road format, and what makes a road unplayable.
#
# Pure: strings and integers in, strings and integers out, no nodes. That is
# what lets tests/test_editor.gd run every rule below against all 31 SHIPPED
# roads and demand that none of them is called broken — which is the only
# check that stops the editor inventing rules the 1993 data refutes. Two of
# them already did (see BUDGET below).
#
# A cell is one u16:
#
#   bits 0-3    surface   the floor's palette nibble; 0 is a hole, and
#                         2/8/9/10/12 also carry an effect
#   bits 4-7    blocktop  the same nibble for a BLOCK's top face
#   bits 8-11   geometry  0 flat, 1 tunnel, 2/3 half block, 4/5 full block —
#                         3 and 5 are the bored variants
#   bits 12-15  unused    the composer ignores them
#
# The nibble an effect has to be written into DEPENDS ON THE GEOMETRY: the
# ship stands on a block's TOP and on a floor's SURFACE, so `sra`'s
# Tile.effect() reads blocktop for geometry 2..5 and surface otherwise. Paint
# "supplies" into the surface nibble of a block and the game shows a coloured
# floor under a block nobody can reach — which is the single easiest mistake
# to make in a grid editor, and why set_effect() below exists at all.
#
# No `class_name`: see scripts/PauseMenu.gd for why.
extends RefCounted

const COLS := 7

## The geometry values the composer draws. 6..15 exist in the format and are
## sent straight to a return by the jump table, so a cell carrying one is
## invisible AND has no collision — a hole that does not look like a hole.
const GEOM_MAX := 5

## Effect nibbles, from SkyRoads.SURFACE. 0 in the surface nibble is a hole;
## 0 in a blocktop nibble means "the default block colour", not a hole.
const EFFECT_NONE := 0
const EFFECT_STICKY := 2
const EFFECT_ICE := 8
const EFFECT_SUPPLIES := 9
const EFFECT_BOOST := 10
const EFFECT_BURNING := 12

## Nibbles that are only a colour. The editor offers one of them as "plain
## floor" so a road can be built without picking a palette index.
const PLAIN_FLOOR := 3

## What a problem costs the player.
##   ERROR — the road cannot be finished however it is driven
##   WARN  — a budget that does not add up on paper; shipped roads beat two of
##           these, so it is never an error
##   INFO  — a number worth knowing before playing
enum { INFO = 0, WARN = 1, ERROR = 2 }


# ---------------------------------------------------------------- cells ----
static func surface_of(code: int) -> int:
	return code & 0xF


static func blocktop_of(code: int) -> int:
	return (code >> 4) & 0xF


static func geometry_of(code: int) -> int:
	return (code >> 8) & 0xF


static func unused_of(code: int) -> int:
	return (code >> 12) & 0xF


static func is_hole(code: int) -> bool:
	return code == 0


## Which nibble the ship's feet actually read on this cell.
static func stands_on_blocktop(code: int) -> bool:
	var g := geometry_of(code)
	return g >= 2 and g <= 5


## The gameplay effect of the face the ship stands on, or "" for none.
## Mirrors sra's Tile.effect() exactly.
static func effect_of(code: int) -> String:
	var nib := blocktop_of(code) if stands_on_blocktop(code) else surface_of(code)
	var name: String = SkyRoads.SURFACE.get(nib, "")
	return name if name != "void" else ""


## Something the ship can come down on. A block gives a top face and a plain
## tunnel gives its roof — the autopilot treats geometry 1 as always safe
## (fn_1bb5 @0x1be4) because you land on the arch. Only bare floor depends on
## its surface nibble being set.
static func landable(code: int) -> bool:
	var g := geometry_of(code)
	if g >= 1 and g <= 5:
		return true
	return surface_of(code) != 0


## The road ends when the ship is inside a tunnel in the last row, so a road
## whose last row has none can be driven to the end and never finish.
static func has_tunnel(code: int) -> bool:
	var g := geometry_of(code)
	return g == 1 or g == 3 or g == 5


static func set_geometry(code: int, geom: int) -> int:
	return (code & ~0xF00) | ((geom & 0xF) << 8)


static func set_surface(code: int, nib: int) -> int:
	return (code & ~0xF) | (nib & 0xF)


static func set_blocktop(code: int, nib: int) -> int:
	return (code & ~0xF0) | ((nib & 0xF) << 4)


## Write an effect into the nibble the ship will actually read, whichever that
## is for this cell's geometry. Changing a floor into a block afterwards moves
## the effect too — `retarget_effect` is what the editor calls for that.
static func set_effect(code: int, nib: int) -> int:
	if stands_on_blocktop(code):
		return set_blocktop(code, nib)
	# a floor with no surface nibble is a hole, so an effect-less floor keeps
	# a plain colour rather than becoming one
	return set_surface(code, PLAIN_FLOOR if nib == EFFECT_NONE else nib)


## Change a cell's geometry and carry its effect across to whichever nibble
## the new geometry reads. Without this, turning a burning floor into a block
## silently disarms it.
static func retarget_effect(code: int, new_geom: int) -> int:
	var eff := blocktop_of(code) if stands_on_blocktop(code) else surface_of(code)
	var out := set_geometry(code, new_geom)
	var was_block := stands_on_blocktop(code)
	var is_block := stands_on_blocktop(out)
	if was_block == is_block:
		return out
	if is_block:
		# the floor under a block still has to be solid or the block floats
		# over a hole; keep whatever colour it had, or give it a plain one
		out = set_blocktop(out, eff)
		return set_surface(out, PLAIN_FLOOR if surface_of(out) == 0 else surface_of(out))
	out = set_surface(out, PLAIN_FLOOR if eff == EFFECT_NONE else eff)
	return set_blocktop(out, 0)


# ------------------------------------------------------------- geometry ----
## A road with a floor under the spawn and a tunnel to finish in. The smallest
## thing that is not immediately broken, which is what a new file should be.
static func blank(rows: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(maxi(rows, SkyRoads.Z_START_ROW + 2) * COLS)
	out.fill(0)
	var n := out.size() / COLS
	for r in n:
		for c in COLS:
			out[r * COLS + c] = set_surface(0, PLAIN_FLOOR)
	for c in COLS:
		out[(n - 1) * COLS + c] = set_geometry(
			set_surface(0, PLAIN_FLOOR), 1)
	return out


# -------------------------------------------------------------- budgets ----
## Everything sra's roads.analyse() reports that the editor can check without
## the retail container, computed the same way so the two agree.
static func stats(rows: int, cells: PackedInt32Array, gravity: int,
		fuel_rows: int, oxygen_secs: int) -> Dictionary:
	var gap_rows := 0
	var max_gap_run := 0
	var run := 0
	var narrow_rows := 0
	var supply_rows: Array[int] = []
	var boost_rows: Array[int] = []
	var hazard_rows: Array[int] = []
	var bad_geometry: Array[int] = []
	var unused_bits := 0
	var tallest := SkyRoads.Y_DECK
	for r in rows:
		var count := 0
		var haz := false
		var sup := false
		var boo := false
		for c in COLS:
			var code := _at(cells, r, c)
			unused_bits |= unused_of(code)
			var g := geometry_of(code)
			if g > GEOM_MAX:
				bad_geometry.append(r * COLS + c)
			elif g < SkyRoads.BLOCK_TOP.size():
				tallest = maxi(tallest, SkyRoads.BLOCK_TOP[g])
			match effect_of(code):
				"burning": haz = true
				"supplies": sup = true
				"boost": boo = true
			if landable(code):
				count += 1
		if count == 0:
			gap_rows += 1
			run += 1
			max_gap_run = maxi(max_gap_run, run)
		else:
			run = 0
			if count == 1:
				narrow_rows += 1
		if haz:
			hazard_rows.append(r)
		if sup:
			supply_rows.append(r)
		if boo:
			boost_rows.append(r)

	var finish: Array[int] = []
	for c in COLS:
		if has_tunnel(_at(cells, rows - 1, c)):
			finish.append(c)

	# The ship spawns at row Z_START_ROW and the finish triggers half a row
	# short of the end, so the distance actually driven is rows - 3.5.
	var distance := maxf(0.0, float(rows - SkyRoads.Z_START_ROW) - 0.5)
	# It starts at rest: SPEED_ACCEL per tick until SPEED_MAX, both in z units
	# where a row is 0x10000.
	var accel_rows := float(SkyRoads.SPEED_ACCEL) / 65536.0
	var rows_per_tick := float(SkyRoads.SPEED_MAX) / 65536.0
	var spin_ticks := float(SkyRoads.SPEED_MAX) / float(SkyRoads.SPEED_ACCEL)
	var spin_rows := 0.5 * accel_rows * spin_ticks * spin_ticks
	var min_ticks := sqrt(2.0 * distance / accel_rows) if distance <= spin_rows \
		else spin_ticks + (distance - spin_rows) / rows_per_tick
	var min_time := min_ticks / SkyRoads.TICK_HZ

	var apex := jump_apex(gravity)
	return {
		"rows": rows,
		"gap_rows": gap_rows,
		"max_gap_run": max_gap_run,
		"narrow_rows": narrow_rows,
		"finish_columns": finish,
		"supply_rows": supply_rows,
		"boost_rows": boost_rows,
		"hazard_rows": hazard_rows,
		"bad_geometry": bad_geometry,
		"unused_bits": unused_bits,
		"can_jump": gravity < SkyRoads.JUMP_MAX_GRAVITY,
		"jump_apex": apex,
		"reach_y": SkyRoads.Y_DECK + apex,
		"tallest_y": tallest,
		"fuel_margin_rows": fuel_rows - int(distance + 0.5),
		"min_time_secs": min_time,
		"oxygen_margin_secs": float(oxygen_secs) - min_time,
	}


## Peak height gain of a standing jump, in Y units (sra consts.jump_apex).
static func jump_apex(gravity: int) -> int:
	var g := -SkyRoads.grav_accel(gravity)
	return 0 if g <= 0 else (SkyRoads.JUMP_VEL * SkyRoads.JUMP_VEL) / (2 * g)


static func _at(cells: PackedInt32Array, row: int, col: int) -> int:
	var i := row * COLS + col
	return cells[i] if i >= 0 and i < cells.size() else 0


# ------------------------------------------------------------- problems ----
## What is wrong with this road, worst first. Each entry is
## {"level": INFO|WARN|ERROR, "text": String}.
##
## BUDGET, and why fuel and oxygen are never errors: `fuel_rows` is what the
## header says a tank buys, and the arithmetic below says roads 14 and 28 are
## 9 and 6 rows longer than their tank with no supply tile anywhere — yet road
## 14 is replayed to completion by tools/verify.sh on every run. The estimate
## is first-order and the shipped set beats it, so it warns and says the
## number. Only structural faults, the ones no way of driving can get around,
## are errors.
static func problems(rows: int, cells: PackedInt32Array, gravity: int,
		fuel_rows: int, oxygen_secs: int) -> Array:
	var s := stats(rows, cells, gravity, fuel_rows, oxygen_secs)
	var out: Array = []

	if rows < SkyRoads.Z_START_ROW + 2:
		out.append(_p(ERROR, "a road needs at least %d rows: the ship spawns on row %d"
			% [SkyRoads.Z_START_ROW + 2, SkyRoads.Z_START_ROW]))
	if rows > SkyRoads.MAX_ROWS:
		out.append(_p(ERROR, "%d rows: the engine reads into a %d-row buffer"
			% [rows, SkyRoads.MAX_ROWS]))
	if not landable(_at(cells, SkyRoads.Z_START_ROW, 3)):
		out.append(_p(ERROR, "nothing to spawn on: row %d column 3 is a hole"
			% SkyRoads.Z_START_ROW))
	if (s["finish_columns"] as Array).is_empty():
		out.append(_p(ERROR, "no finish — the road ends when the ship is inside "
			+ "a tunnel in the last row, and row %d has none" % (rows - 1)))
	var bad: Array = s["bad_geometry"]
	if not bad.is_empty():
		out.append(_p(ERROR, "%d cell(s) carry geometry above %d, which the "
			% [bad.size(), GEOM_MAX]
			+ "composer sends to a return: invisible, and no collision either"))
	if not s["can_jump"] and s["gap_rows"] > 0:
		out.append(_p(ERROR, "gravity %d is at or above %d, so the ship cannot "
			% [gravity, SkyRoads.JUMP_MAX_GRAVITY]
			+ "jump at all — and %d row(s) have nothing to land on"
			% s["gap_rows"]))

	var fm: int = s["fuel_margin_rows"]
	var supplies: Array = s["supply_rows"]
	if fm < 0 and supplies.is_empty():
		out.append(_p(WARN, "%d rows longer than its fuel (%d rows) and no "
			% [-fm, fuel_rows] + "supply tile anywhere"))
	elif fm < 0:
		out.append(_p(WARN, "%d rows longer than its fuel; it depends on the "
			% -fm + "supply tile(s) on row(s) %s" % [supplies.slice(0, 6)]))
	var om: float = s["oxygen_margin_secs"]
	if om < 0.0:
		out.append(_p(WARN, "%.1f s short of oxygen even at maximum speed "
			% -om + "(fastest possible run is %.1f s, tank is %d s)"
			% [s["min_time_secs"], oxygen_secs]))
	elif om < 5.0:
		out.append(_p(WARN, "only %.1f s of oxygen to spare at maximum speed"
			% om))

	if s["unused_bits"] != 0:
		out.append(_p(WARN, "unused bits set in some cells (mask 0x%X); the "
			% (int(s["unused_bits"]) << 12)
			+ "composer ignores them but nothing else guarantees to"))
	if s["max_gap_run"] > 5:
		out.append(_p(WARN, "a run of %d rows with nothing to land on; the "
			% s["max_gap_run"] + "longest in the shipped game is 5"))

	if s["tallest_y"] > s["reach_y"]:
		out.append(_p(INFO, "blocks here are taller than a standing jump at "
			+ "gravity %d reaches (%d vs %d): obstacles, not platforms"
			% [gravity, s["tallest_y"], s["reach_y"]]))
	# Two lines rather than one: the editor wraps a problem into two rows of
	# forty characters, and a single sentence with all six numbers in it loses
	# the last three off the bottom of the screen.
	out.append(_p(INFO, "%d rows, fuel margin %d rows, oxygen margin %.1f s"
		% [rows, fm, om]))
	out.append(_p(INFO, "%d gap row(s), %d narrow row(s), finish in %d column(s)"
		% [s["gap_rows"], s["narrow_rows"], (s["finish_columns"] as Array).size()]))
	return out


static func _p(level: int, text: String) -> Dictionary:
	return {"level": level, "text": text}


static func level_name(level: int) -> String:
	match level:
		ERROR: return "ERROR"
		WARN: return "warning"
		_: return "info"


## True when nothing structural is wrong. A road with warnings is playable;
## a road with an error is not, however it is driven.
static func playable(list: Array) -> bool:
	for p in list:
		if p["level"] == ERROR:
			return false
	return true


# --------------------------------------------------------------- files ----
## The on-disk form, which is exactly what `sra export-godot` writes and
## RoadData.load_json reads — so a road built here loads through the same code
## path as a road decoded from ROADS.LZS, and `--level-file` can point at
## either. `stats` is included because the shipped files carry it and a
## diff between a saved road and an exported one should be about the road.
static func to_dict(index: int, rows: int, cells: PackedInt32Array,
		gravity: int, fuel_rows: int, oxygen_secs: int, world: int,
		palette: PackedColorArray) -> Dictionary:
	var pal: Array = []
	for c in palette:
		pal.append([int(round(c.r * 255.0)), int(round(c.g * 255.0)),
			int(round(c.b * 255.0))])
	var cell_list: Array = []
	for v in cells:
		cell_list.append(v)
	return {
		"index": index,
		"rows": rows,
		"gravity": gravity,
		"dash_gravity": SkyRoads.dash_gravity(gravity),
		"grav_accel_per_tick": SkyRoads.grav_accel(gravity),
		"can_jump": gravity < SkyRoads.JUMP_MAX_GRAVITY,
		"fuel_rows": fuel_rows,
		"oxygen_secs": oxygen_secs,
		"world": world,
		"cells": cell_list,
		"palette": pal,
		"stats": stats(rows, cells, gravity, fuel_rows, oxygen_secs),
	}


## Read one back. Returns {} when the file is missing or is not a road, so a
## corrupt file in user:// opens as "could not read that" rather than as a
## half-loaded grid the author then saves over the top of.
static func from_file(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d: Variant = JSON.parse_string(f.get_as_text())
	if typeof(d) != TYPE_DICTIONARY:
		return {}
	for key in ["rows", "gravity", "fuel_rows", "oxygen_secs", "cells"]:
		if not (d as Dictionary).has(key):
			return {}
	var rows: int = int(d["rows"])
	var cells := PackedInt32Array()
	for v in d["cells"]:
		cells.append(int(v))
	if cells.size() != rows * COLS:
		return {}
	return {
		"index": int(d.get("index", 0)),
		"rows": rows,
		"gravity": int(d["gravity"]),
		"fuel_rows": int(d["fuel_rows"]),
		"oxygen_secs": int(d["oxygen_secs"]),
		"world": int(d.get("world", 0)),
		"cells": cells,
		"palette": d.get("palette", []),
	}


static func save_to(path: String, doc: Dictionary) -> bool:
	var dir := path.get_base_dir()
	if not dir.is_empty():
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(doc))
	f.close()
	return true
