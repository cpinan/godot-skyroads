# Does the drawn road match the road the physics collides with?
#
# The two are built from the same grid but by completely different code, so
# they can disagree silently — and a road that LOOKS solid where collision says
# hole (or the reverse) is the worst kind of bug: the player is told one thing
# and the simulation does another.
#
# This samples the floor mesh at the centre of every cell and compares against
# what SkyRoadsPlay.solid() reports for the same spot.
extends SceneTree

var _failures := 0
var _checks := 0


func check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL  %s" % label)


func _init() -> void:
	for idx in [1, 30]:
		_check_road(idx)
	_check_lateral_alignment()
	_camera_is_not_the_generated_one()
	print("Result: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## Does the lane the player SEES match the lane collision uses?
##
## The mesh places column c from (c - 3.5)*w to (c - 2.5)*w, while collision
## derives the column arithmetically from the ship's X (fn_04c0:
## col = (x/0x80 - 0x5F) / 0x2E). If those disagree by even half a lane the
## ship falls into holes that look solid, which is indistinguishable from
## "collision is broken".
func _check_lateral_alignment() -> void:
	var road := RoadData.load_json("res://data/levels/road_01.json")
	if road == null:
		return
	var w: float = SkyRoadsCamera.COLUMN_WIDTH
	var worst := 0.0
	var bad := ""
	for col in SkyRoads.COLS:
		# centre of this column in the original's X units
		var x: int = (0x5F + col * 0x2E + 23) * 0x80
		# what collision says
		var collision_col: int = (x / 0x80 - 0x5F) / 0x2E
		# what the drawing says: the mesh quad that contains this world x
		var world_x: float = SkyRoadsCamera.ship_position(x, SkyRoads.Y_DECK, 0).x
		var drawn_col: int = int(floor(world_x / w + 3.5))
		if collision_col != drawn_col:
			bad = "x=%d: collision lane %d, drawn lane %d" % [x, collision_col, drawn_col]
		# and how far the drawn lane centre is from the collision lane centre
		var drawn_centre: float = (float(col) - 3.0) * w
		worst = maxf(worst, absf(world_x - drawn_centre))
	check(bad.is_empty(), "every lane centre draws where collision puts it (%s)" % bad)

	# The ship is placed by the original's screen formula, the road by the
	# camera. If a lane is not 46 original pixels wide at the ship's depth the
	# two disagree, and the ship ends up beside the road it is colliding with —
	# which is what "no collision" and "collision too early" actually were.
	var px_per_unit: float = SkyRoadsCamera.FOCAL_PX / SkyRoadsCamera.BEHIND_ROWS
	var lane_px: float = SkyRoadsCamera.COLUMN_WIDTH * px_per_unit
	check(absf(lane_px - 46.0) < 0.5,
		"a lane draws 46 px wide at the ship's depth (got %.2f)" % lane_px)
	# Vertical scale, the same trap: block heights are quoted in ORIGINAL
	# pixels while the focal length is in canvas pixels, and the two differ by
	# PIXEL_ASPECT. Dropping it drew every block 1.2x too short.
	var half_px: float = SkyRoadsCamera.HALF_BLOCK_Y * px_per_unit
	var full_px: float = SkyRoadsCamera.FULL_BLOCK_Y * px_per_unit
	var want_half: float = float(SkyRoads.Y_HALF - SkyRoads.Y_DECK) / 0x80 \
		* SkyRoads.PIXEL_ASPECT
	check(absf(half_px - want_half) < 0.5,
		"a half block draws %.0f canvas px tall (got %.2f)" % [want_half, half_px])
	check(absf(full_px - want_half * 2.0) < 0.5,
		"a full block is twice a half block (%.2f vs %.2f)"
		% [full_px, want_half * 2.0])
	# and the ship's own screen x must land inside its drawn lane
	for col2 in SkyRoads.COLS:
		var xs: int = (0x5F + col2 * 0x2E + 23) * 0x80
		var sprite_centre: float = float(xs / 0x80 + SkyRoads.SHIP_PAN[col2] - 0x6E) + 14.5
		var world: float = SkyRoadsCamera.ship_position(xs, SkyRoads.Y_DECK, 0).x
		var drawn_centre_px: float = 160.0 + world * px_per_unit
		# the tolerance covers SHIP_PAN, the original's deliberate sprite lean
		# per lane (ds:0x38 = -1,-1,-1,0,1,2,4) — the ship is nudged toward
		# the outside of the turn, it is not meant to sit dead centre
		check(absf(sprite_centre - drawn_centre_px) <= 5.5,
			"lane %d: sprite at x %.1f, drawn lane centre at %.1f (pan %d)"
			% [col2, sprite_centre, drawn_centre_px, SkyRoads.SHIP_PAN[col2]])
	check(worst < w * 0.1,
		"lane centres line up to within a tenth of a lane (worst %.4f of %.4f)"
		% [worst, w])
	if bad.is_empty():
		print("lateral: all %d lanes agree between drawing and collision"
			% SkyRoads.COLS)


## Every floor triangle in the mesh, as (min_x, max_x, min_z, max_z) at y≈0.
func _floor_cells(mesh: Mesh) -> Dictionary:
	var covered := {}
	if mesh == null or mesh.get_surface_count() == 0:
		return covered
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var w: float = SkyRoadsCamera.COLUMN_WIDTH
	for i in range(0, verts.size(), 3):
		var a := verts[i]
		var b := verts[i + 1]
		var c := verts[i + 2]
		# only the flat top faces sit exactly at deck height
		if absf(a.y) > 0.001 or absf(b.y) > 0.001 or absf(c.y) > 0.001:
			continue
		var cx := (a.x + b.x + c.x) / 3.0
		var cz := (a.z + b.z + c.z) / 3.0
		var col := int(floor(cx / w + 3.5))
		var row := int(floor(-cz))
		covered["%d,%d" % [row, col]] = true
	return covered


func _check_road(idx: int) -> void:
	var road := RoadData.load_json("res://data/levels/road_%02d.json" % idx)
	check(road != null, "road %d loads" % idx)
	if road == null:
		return
	var rm := RoadMesh.new()
	rm.build(road)
	# the road is one floor mesh per grid row (RoadMesh.build); union them
	var covered := {}
	for mi in rm.get_children():
		if mi is MeshInstance3D and String(mi.name).begins_with("Floor"):
			covered.merge(_floor_cells(mi.mesh))

	var drawn_but_hole := 0
	var hole_but_drawn := 0
	var first_bad := ""
	for row in road.rows:
		for col in SkyRoads.COLS:
			var code := road.tile(row, col)
			var has_floor := SkyRoads.tile_surface(code) != 0
			var is_drawn: bool = covered.has("%d,%d" % [row, col])
			if is_drawn and not has_floor:
				drawn_but_hole += 1
				if first_bad.is_empty():
					first_bad = "row %d col %d code %04x drawn as solid" % [row, col, code]
			elif has_floor and not is_drawn:
				hole_but_drawn += 1
				if first_bad.is_empty():
					first_bad = "row %d col %d code %04x has floor but is not drawn" % [row, col, code]

	var holes := 0
	for row in road.rows:
		for col in SkyRoads.COLS:
			if SkyRoads.tile_surface(road.tile(row, col)) == 0:
				holes += 1
	check(drawn_but_hole == 0,
		"road %d draws no floor over a hole (%d wrong; %s)"
		% [idx, drawn_but_hole, first_bad])
	check(hole_but_drawn == 0,
		"road %d draws every solid cell (%d missing; %s)"
		% [idx, hole_but_drawn, first_bad])
	if drawn_but_hole == 0 and hole_but_drawn == 0:
		print("road %2d: %d cells, %d without floor — drawn road matches collision"
			% [idx, road.rows * SkyRoads.COLS, holes])


## A tripwire on `data/SkyRoadsCamera.gd`, which is a landmine.
##
## `sra export-godot` still WRITES that file, from a template that begins
## "GENERATED — do not edit by hand". It has not been generated since
## 2026-08-30, when the pinhole fit it carries was refuted by decoding the
## actual TREKDAT span tables. What the file holds now is hand-derived and is
## most of the port's visual fidelity: the DOS material and its shader, the
## horizontal cone, the raised-surface height ladder (§12.18), the arch band
## fan (§12.21) and the ship-row split. The template has NONE of those — it is
## 3,946 characters of constants and nothing else.
##
## So an innocent `sra export-godot`, run to refresh a level or a sprite, would
## silently replace all of it with the refuted fit, and nothing in the project
## would say so until somebody noticed the road looked wrong. This fails
## instead, immediately and by name.
##
## If it ever fires: `git checkout -- data/SkyRoadsCamera.gd`, and then fix the
## exporter so it stops writing a file it no longer owns.
func _camera_is_not_the_generated_one() -> void:
	# the refuted fit put the camera a full row too far back
	check(absf(SkyRoadsCamera.FOCAL_PX - 282.7632) < 0.001,
		"camera FOCAL_PX is the measured 282.7632, not the refuted 279.7 (%f)"
		% SkyRoadsCamera.FOCAL_PX)
	check(absf(SkyRoadsCamera.BEHIND_ROWS - 2.55) < 0.001,
		"camera BEHIND_ROWS is the measured 2.55, not the refuted 3.535 (%f)"
		% SkyRoadsCamera.BEHIND_ROWS)
	# The three things the generator's template does not contain at all. Their
	# ABSENCE would be a parse error rather than a failed check, which the gate
	# does catch — but as "res://tests/test_geometry.gd failed to load", which
	# says nothing about why. Calling them tests the value as well as the name.
	#
	# The height ladder passes through exactly 1.0 at the ship's own depth: a
	# block beside the ship is where the pinhole puts it, and everything else
	# is drawn flatter or taller than perspective would draw it (§12.18).
	check(absf(SkyRoadsCamera.dos_y_scale(SkyRoadsCamera.BEHIND_ROWS) - 1.0) < 0.005,
		"the height ladder is 1.0 at the ship's own depth (%f)"
		% SkyRoadsCamera.dos_y_scale(SkyRoadsCamera.BEHIND_ROWS))
	check(SkyRoadsCamera.dos_y_scale(1.05) > 1.2
		and SkyRoadsCamera.dos_y_scale(6.55) < 0.6,
		"and it flattens with distance, 1.29 near and 0.48 far")
	check(absf(SkyRoadsCamera.dos_x_scale(SkyRoadsCamera.BEHIND_ROWS) - 1.0) < 0.02,
		"the horizontal cone is ~1.0 at that depth too (%f)"
		% SkyRoadsCamera.dos_x_scale(SkyRoadsCamera.BEHIND_ROWS))
	check(SkyRoadsCamera.ARCH_BAND_RATIOS.size() == 4
		and SkyRoadsCamera.ARCH_RECORD_LEFT.size() == 6,
		"and the arch band fan is still here (§12.21)")
	# the shared shader cache: three render_mode combinations, not eight
	var opaque := SkyRoadsCamera.make_dos_material()
	var cover := SkyRoadsCamera.make_dos_material(true, true, false, 2)
	check(opaque.shader != null and cover.shader != null
		and opaque.shader != cover.shader,
		"the opaque and cover passes are different shaders, as they must be")
	check(SkyRoadsCamera.make_dos_material().shader == opaque.shader,
		"and two materials of the same kind SHARE one, so a road restart "
		+ "costs the driver no new program compiles")
