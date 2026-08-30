# The exported level data has to mean what the engine thinks it means.
#
# Checks the shape, and then the two things that are silently fatal if wrong:
# the finish line is a tunnel tile on the last row (a road without one can
# never be completed), and the tile-decoding helpers agree with the physics.
extends SceneTree

var _failures := 0
var _checks := 0


func check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL  %s" % label)


func _init() -> void:
	for i in [1, 30]:
		_check_road(i)
	_check_tile_helpers()
	_check_camera()
	print("Result: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check_road(i: int) -> void:
	var r := RoadData.load_json("res://data/levels/road_%02d.json" % i)
	check(r != null, "road %d loads" % i)
	if r == null:
		return
	check(r.rows > 0, "road %d has rows" % i)
	check(r.cells.size() == r.rows * SkyRoads.COLS,
		"road %d cell count is rows x 7 (%d vs %d)" % [i, r.cells.size(), r.rows * SkyRoads.COLS])
	check(r.palette.size() == 72, "road %d has a 72-colour palette" % i)
	check(r.gravity >= 4 and r.gravity <= 20,
		"road %d gravity %d is in range" % [i, r.gravity])
	check(r.fuel_rows > 0 and r.oxygen_secs > 0, "road %d has tank budgets" % i)

	# the finish is literally a tunnel tile on the last row; without one the
	# road can never be completed no matter how well it is driven
	var gate := 0
	for c in SkyRoads.COLS:
		var geom := SkyRoads.tile_geometry(r.tile(r.rows - 1, c))
		if geom == 1 or geom == 3 or geom == 5:
			gate += 1
	check(gate > 0, "road %d ends in a tunnel gate (%d of 7 columns)" % [i, gate])

	# a road whose gravity forbids jumping must not contain a full-width hole
	if r.gravity >= SkyRoads.JUMP_MAX_GRAVITY:
		var impossible := -1
		for row in r.rows:
			var landable := 0
			for c in SkyRoads.COLS:
				var t := r.tile(row, c)
				if SkyRoads.tile_geometry(t) != 0 or SkyRoads.tile_surface(t) != 0:
					landable += 1
			if landable == 0:
				impossible = row
				break
		check(impossible < 0,
			"road %d forbids jumping, so it must have no full-width gap (row %d)"
			% [i, impossible])


func _check_tile_helpers() -> void:
	var t := 0x0433                                   # full block, plain faces
	check(SkyRoads.tile_geometry(t) == 4, "geometry nibble")
	check(SkyRoads.tile_surface(t) == 3, "surface nibble")
	check(SkyRoads.tile_blocktop(t) == 3, "block-top nibble")
	check(SkyRoads.tile_top_height(t) == SkyRoads.Y_FULL, "full block top height")
	check(SkyRoads.tile_top_height(0x0233) == SkyRoads.Y_HALF, "half block top height")
	check(SkyRoads.tile_top_height(0x0003) == SkyRoads.Y_DECK, "flat floor height")
	check(SkyRoads.tile_surface(0x000C) == 0xC, "burning surface")
	check(SkyRoads.dash_gravity(8) == 500, "gravity 8 shows 500")
	check(SkyRoads.grav_accel(8) == -115, "gravity 8 accelerates -115 per tick")


func _check_camera() -> void:
	var f := FileAccess.open("res://data/camera.json", FileAccess.READ)
	check(f != null, "camera.json exists")
	if f == null:
		return
	var d: Dictionary = JSON.parse_string(f.get_as_text())
	check(d.get("plausible", false), "the exported camera fit is credible")
	var w: Dictionary = d["world_scale"]
	check(absf(w["full_block_y"] - 2.0 * w["half_block_y"]) < 1e-5,
		"a full block is exactly twice a half block")
	check(SkyRoadsCamera.FULL_BLOCK_Y > 0.0 and SkyRoadsCamera.COLUMN_WIDTH > 0.0,
		"the camera script carries the world scale")
