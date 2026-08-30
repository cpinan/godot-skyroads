# The dashboard, redrawn every tick exactly as fn_124b does.
#
# The original's dashboard is a static image with small shapes stamped over it:
# arc segments for the speedometer, bars for the tanks, a column per progress
# step, digit stencils for the gravity readout, and a two-state lamp for the
# landing assist. Every shape and every colour index below comes out of the
# retail data (data/hud/shapes.json, data/tables.json, data/game_palette.json).
#
# Values, from renderer.md §9:
#
#   speedometer  (speed - autopilot delta) / 0x141, capped at 34
#   oxygen       ceil(oxy  / 0xBB8), capped at 10
#   fuel         ceil(fuel / 0xBB8), capped at 10
#   progress     (z - 3 rows) / ((rows - 3) rows / 30), capped at 29
#   GRAV-O-METER (gravity - 3) * 100, four digits, leading zeros suppressed
#   jump-o-master lit while the landing assist is correcting a jump
#
# The speedometer deliberately shows speed MINUS the autopilot's correction:
# the assist is invisible to the player, and showing the true speed would give
# it away.
class_name Dashboard
extends Node2D

var _shapes: Dictionary = {}
var _tables: Dictionary = {}
var _palette: PackedColorArray = PackedColorArray()
var _play: SkyRoadsPlay
var _rows := 1
var _art: Image
var _prog_top := PackedInt32Array()   ## per-column top y, screen coords
var _warn_masks := {}                 ## "oxy"/"fuel" -> [pixels@99, pixels@100]


func _ready() -> void:
	_shapes = _load("res://data/hud/shapes.json").get("gauges", {})
	_tables = _load("res://data/tables.json")
	var pal: Array = _load("res://data/game_palette.json").get("palette", [])
	for c in pal:
		_palette.append(Color8(c[0], c[1], c[2]))
	z_index = 10                # over the dashboard image, under nothing else
	var tex: Texture2D = load("res://data/gfx/dashbrd_0.png")
	if tex != null:
		_art = tex.get_image()
		_precompute_progress()
		_precompute_warn_masks()


## hud.c:98-107: each progress column's height comes from the art — read the
## slot colour at (x,143) and extend upward while it repeats, floor y=138.
func _precompute_progress() -> void:
	_prog_top.resize(SkyRoads.PROGRESS_STEPS)
	for i in SkyRoads.PROGRESS_STEPS:
		var x: int = SkyRoads.PROGRESS_X + i
		var slot := _art.get_pixel(x, SkyRoads.PROGRESS_Y - SkyRoads.DASH_PICT_Y)
		var yy: int = SkyRoads.PROGRESS_Y
		while yy >= 138 and _art.get_pixel(x, yy - SkyRoads.DASH_PICT_Y) == slot:
			yy -= 1
		_prog_top[i] = yy + 1


## The EXE colour-swaps lamp pixels 0x63<->0x64 inside the warning rects
## (renderer.md §13); find where each index sits in the pristine art.
func _precompute_warn_masks() -> void:
	for entry in [["oxy", SkyRoads.WARN_OXY_RECT],
			["fuel", SkyRoads.WARN_FUEL_RECT]]:
		var r: Array = entry[1]
		var at99: Array[Vector2i] = []
		var at100: Array[Vector2i] = []
		for dy in int(r[3]):
			for dx in int(r[2]):
				var x: int = int(r[0]) + dx
				var y: int = int(r[1]) + dy
				var c := _art.get_pixel(x, y - SkyRoads.DASH_PICT_Y)
				if c.is_equal_approx(_col(99)):
					at99.append(Vector2i(x, y))
				elif c.is_equal_approx(_col(100)):
					at100.append(Vector2i(x, y))
		_warn_masks[entry[0]] = [at99, at100]


func _swap_px(pts: Array, c: Color) -> void:
	for p in pts:
		draw_rect(Rect2(Vector2(p.x, p.y * SkyRoads.PIXEL_ASPECT),
			Vector2(1, SkyRoads.PIXEL_ASPECT)), c, true)


func _load(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("missing %s — run `sra export-godot`" % path)
		return {}
	return JSON.parse_string(f.get_as_text()) as Dictionary


func update(play: SkyRoadsPlay, rows: int) -> void:
	_play = play
	_rows = maxi(rows, 1)
	queue_redraw()


func _col(index: int) -> Color:
	return _palette[index] if index < _palette.size() else Color.MAGENTA


## Shapes store 0 (transparent), 1 and 2, selecting two colours.
func _stamp(cells: Array, w: int, h: int, x: int, y: int,
		c1: Color, c2: Color) -> void:
	for row in h:
		for col in w:
			var v: int = cells[row * w + col]
			if v == 0:
				continue
			draw_rect(Rect2(Vector2(x + col, (y + row) * SkyRoads.PIXEL_ASPECT),
				Vector2(1, SkyRoads.PIXEL_ASPECT)), c2 if v == 2 else c1, true)


func _gauge(key: String, lit_count: int) -> void:
	var list: Array = _shapes.get(key, [])
	for i in list.size():
		if i >= lit_count:
			continue            # unlit segments are simply the dashboard art
		var s: Dictionary = list[i]
		_stamp(s["cells"], int(s["w"]), int(s["h"]),
			int(s["screen_x"]), int(s["screen_y"]),
			_col(SkyRoads.HUD_COLORS["seg_lit"][0]),
			_col(SkyRoads.HUD_COLORS["seg_lit"][1]))


func _draw() -> void:
	if _play == null or _palette.is_empty():
		return

	# every readout comes from HudModel, which is the transcription of hud.c
	# and is asserted at its boundaries by test_hud.gd
	_gauge("speedometer", HudModel.speed_segments(_play.speed, _play.ap_delta))
	_gauge("oxygen", HudModel.gauge_segments(_play.oxy))
	_gauge("fuel", HudModel.gauge_segments(_play.fuel))

	# progress bar: one column per step, from the spawn row to the finish
	var steps := HudModel.progress_steps(_play.z, _rows)
	var pcol := _col(SkyRoads.HUD_COLORS["progress"])
	for i in steps:
		var top: int = _prog_top[i] if i < _prog_top.size() \
			else SkyRoads.PROGRESS_Y - 4
		draw_rect(Rect2(
			Vector2(SkyRoads.PROGRESS_X + i, top * SkyRoads.PIXEL_ASPECT),
			Vector2(1, (SkyRoads.PROGRESS_Y - top + 1) * SkyRoads.PIXEL_ASPECT)),
			pcol, true)

	# GRAV-O-METER: four digits, leading zeros suppressed
	var digits: Array = _tables.get("digits", [])
	if not digits.is_empty():
		var value := HudModel.gravity_value(_play.road.gravity)
		var d1 := _col(SkyRoads.HUD_COLORS["digit"][0])
		var d2 := _col(SkyRoads.HUD_COLORS["digit"][1])
		# least significant digit first, rightmost cell first
		var shown := HudModel.gravity_digits(value)
		for si in shown.size():
			_stamp(digits[shown[si]], 4, 5,
				SkyRoads.GRAVITY_POS[0] + (3 - si) * 5,
				SkyRoads.GRAVITY_POS[1], d1, d2)

	# jump-o-master lamp, two states
	var aplight: Array = _tables.get("aplight", [])
	if aplight.size() == 2:
		var c := _col(SkyRoads.HUD_COLORS["ap_light"])
		_stamp(aplight[1 if _play.ap_light else 0], 26, 5,
			SkyRoads.AP_LIGHT_POS[0], SkyRoads.AP_LIGHT_POS[1], c, c)

	# empty-tank warning lamps, blinking, per end_state
	if HudModel.warn_lit(_play.tick):
		var which := ""
		if _play.end_state == SkyRoadsPlay.NO_OXYGEN:
			which = "oxy"
		elif _play.end_state == SkyRoadsPlay.NO_FUEL:
			which = "fuel"
		if which != "" and _warn_masks.has(which):
			# swap, not fill: pixels at 0x63 turn 0x64 and vice versa
			_swap_px(_warn_masks[which][0], _col(100))
			_swap_px(_warn_masks[which][1], _col(99))
