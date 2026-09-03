# gd-audit: ignore GDBP-101 — tests/ follows scripts/ naming. See docs/PERF.md.
# The road format and the editor's validation rules.
#
# The check this suite exists for is `_shipped_roads_are_playable`: every rule
# in RoadEditModel runs against all 31 roads Bluemoon shipped, and none of them
# may be called broken. An editor that rejects the game's own levels is worse
# than no editor, and two candidate rules were demoted from ERROR to WARN by
# exactly this test — roads 14 and 28 are longer than their fuel with no supply
# tile, and road 14 is replayed to completion by verify.sh on every run.
#
# The rest is the cell codec, whose one real trap is that an effect lives in a
# different nibble depending on the geometry.
extends SceneTree

const Ed = preload("res://scripts/model/RoadEditModel.gd")
const Editor = preload("res://scripts/RoadEditor.gd")

var _failures := 0
var _checks := 0


func check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL  %s" % label)


func _init() -> void:
	_codec()
	_effect_follows_geometry()
	_blank_is_playable()
	_broken_roads_are_caught()
	_shipped_roads_are_playable()
	_round_trip()
	await _editor_edits()
	_solver_verdicts()
	print("Result: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## The four nibbles, against a real cell out of road 2: 0x0203 is a half block
## on a plain-3 floor.
func _codec() -> void:
	var code := 515
	check(Ed.geometry_of(code) == 2, "0x203 is geometry 2 (half block)")
	check(Ed.surface_of(code) == 3, "0x203's floor nibble is 3")
	check(Ed.blocktop_of(code) == 0, "0x203's block top is the default")
	check(Ed.unused_of(code) == 0, "and nothing is set above bit 11")
	check(Ed.is_hole(0), "code 0 is a hole")
	check(not Ed.landable(0), "and nothing lands on it")
	check(Ed.landable(Ed.set_surface(0, 3)), "a floor with a colour is landable")
	check(Ed.landable(Ed.set_geometry(0, 1)),
		"a tunnel is landable even with no floor — you come down on the arch")
	check(Ed.has_tunnel(Ed.set_geometry(0, 5)) and not Ed.has_tunnel(515),
		"geometry 1, 3 and 5 are the bored ones")


## The trap: the ship stands on a BLOCK's top and on a FLOOR's surface, so the
## same effect has to be written into a different nibble for each.
func _effect_follows_geometry() -> void:
	var floor_cell := Ed.set_effect(Ed.set_geometry(0, 0), Ed.EFFECT_BURNING)
	check(Ed.surface_of(floor_cell) == Ed.EFFECT_BURNING,
		"burning on a floor goes in the surface nibble")
	check(Ed.effect_of(floor_cell) == "burning", "and reads back as burning")

	var block := Ed.set_effect(Ed.set_geometry(Ed.set_surface(0, 3), 4),
		Ed.EFFECT_SUPPLIES)
	check(Ed.blocktop_of(block) == Ed.EFFECT_SUPPLIES,
		"supplies on a block goes in the blocktop nibble")
	check(Ed.effect_of(block) == "supplies", "and reads back as supplies")
	check(Ed.surface_of(block) == 3,
		"without disturbing the floor colour under it")

	# and turning one into the other must carry the effect across, or a burning
	# floor silently becomes a safe block
	var promoted := Ed.retarget_effect(floor_cell, 4)
	check(Ed.effect_of(promoted) == "burning",
		"a burning floor turned into a block is still burning (%s)"
		% Ed.effect_of(promoted))
	var demoted := Ed.retarget_effect(promoted, 0)
	check(Ed.effect_of(demoted) == "burning",
		"and back again (%s)" % Ed.effect_of(demoted))


func _blank_is_playable() -> void:
	var cells := Ed.blank(20)
	check(cells.size() == 20 * Ed.COLS, "a blank road is rows x 7")
	var probs := Ed.problems(20, cells, 8, 200, 60)
	check(Ed.playable(probs),
		"and a new file is not born broken: %s" % [_errors(probs)])


## Each of these is a road that cannot be finished however it is driven, and
## each must be reported as an ERROR rather than a warning.
func _broken_roads_are_caught() -> void:
	var ok := Ed.blank(20)

	var no_finish := ok.duplicate()
	for c in Ed.COLS:
		no_finish[19 * Ed.COLS + c] = Ed.set_surface(0, 3)
	check(not Ed.playable(Ed.problems(20, no_finish, 8, 200, 60)),
		"a last row with no tunnel is an error: nothing triggers the finish")

	var no_spawn := ok.duplicate()
	no_spawn[SkyRoads.Z_START_ROW * Ed.COLS + 3] = 0
	check(not Ed.playable(Ed.problems(20, no_spawn, 8, 200, 60)),
		"a hole under the spawn is an error")

	var bad_geom := ok.duplicate()
	bad_geom[5 * Ed.COLS + 2] = Ed.set_geometry(0, 9)
	check(not Ed.playable(Ed.problems(20, bad_geom, 8, 200, 60)),
		"geometry 9 is an error — the composer draws nothing and collides with nothing")

	# gravity 20 disables jumping entirely (can_jump = gravity < 20), so a row
	# with nothing to land on can never be crossed
	var gap := ok.duplicate()
	for c in Ed.COLS:
		gap[10 * Ed.COLS + c] = 0
	check(not Ed.playable(Ed.problems(20, gap, 20, 200, 60)),
		"a gap at gravity 20 is an error: the ship cannot jump")
	check(Ed.playable(Ed.problems(20, gap, 8, 200, 60)),
		"the same gap at gravity 8 is fine — that is most of the game")

	check(not Ed.playable(Ed.problems(4, Ed.blank(4).slice(0, 4 * Ed.COLS), 8, 200, 60)),
		"a road shorter than the spawn row plus one is an error")


## The one that decides whether the rules are right.
func _shipped_roads_are_playable() -> void:
	var checked := 0
	for i in SkyRoads.ROADS_COUNT:
		var doc := Ed.from_file("res://data/levels/road_%02d.json" % i)
		if doc.is_empty():
			continue
		checked += 1
		var probs := Ed.problems(doc["rows"], doc["cells"], doc["gravity"],
			doc["fuel_rows"], doc["oxygen_secs"])
		check(Ed.playable(probs), "shipped road %d is not called broken: %s"
			% [i, _errors(probs)])
	check(checked == SkyRoads.ROADS_COUNT,
		"all %d shipped roads were read (%d)" % [SkyRoads.ROADS_COUNT, checked])


## The budget arithmetic has to agree with the numbers `sra` baked into the
## level files, or the editor and the toolkit disagree about the same road.
func _round_trip() -> void:
	var doc := Ed.from_file("res://data/levels/road_02.json")
	check(not doc.is_empty(), "road 2 reads back")
	if doc.is_empty():
		return
	var s := Ed.stats(doc["rows"], doc["cells"], doc["gravity"],
		doc["fuel_rows"], doc["oxygen_secs"])
	check(s["fuel_margin_rows"] == 88,
		"road 2's fuel margin is sra's 88 rows (%d)" % s["fuel_margin_rows"])
	check(absf(s["min_time_secs"] - 20.6) < 0.1,
		"and its fastest possible run is sra's 20.6 s (%.1f)" % s["min_time_secs"])
	check(s["gap_rows"] == 7 and s["max_gap_run"] == 2 and s["narrow_rows"] == 14,
		"and its gap/narrow counts match (%d, %d, %d)"
		% [s["gap_rows"], s["max_gap_run"], s["narrow_rows"]])

	# save and reload, through the same JSON the game loads
	var path := "user://test_editor_roundtrip.json"
	var pal := PackedColorArray()
	for i in 72:
		pal.append(Color8(i, i, i))
	var out := Ed.to_dict(99, doc["rows"], doc["cells"], doc["gravity"],
		doc["fuel_rows"], doc["oxygen_secs"], doc["world"], pal)
	check(Ed.save_to(path, out), "a road saves to user://")
	var back := Ed.from_file(path)
	check(back.get("cells", PackedInt32Array()) == doc["cells"],
		"and every cell comes back unchanged")
	# RoadData is what the game itself loads with, so the file has to satisfy it
	var rd := RoadData.load_json(path)
	check(rd != null and rd.rows == doc["rows"] and rd.palette.size() == 72,
		"and RoadData reads it as a road")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _errors(probs: Array) -> String:
	var out: Array[String] = []
	for p in probs:
		if p["level"] == Ed.ERROR:
			out.append(p["text"])
	return "; ".join(out) if not out.is_empty() else "none"


## The editor itself, driven through the same handle_input() the shell calls.
##
## What this is here for is the brush: painting a shape and an effect are two
## separate keys, and the effect has to end up in whichever nibble the SHAPE
## reads. A test that only checked the model would not catch the editor
## applying them in the wrong order.
func _editor_edits() -> void:
	var ed := Editor.new()
	ed.name_stem = "test_editor_suite"
	ed.rows = 20
	get_root().add_child(ed)
	await process_frame

	check(ed.rows == 20 and ed.cells.size() == 20 * Ed.COLS,
		"a new editor opens on a 20-row road (%d)" % ed.rows)
	check(Ed.playable(Ed.problems(ed.rows, ed.cells, ed.gravity, ed.fuel_rows,
		ed.oxygen_secs)), "which is playable")

	# move to row 8 column 2 and paint a full block with supplies on top
	_press(ed, KEY_HOME)
	for i in 8:
		_press(ed, KEY_DOWN)
	_press(ed, KEY_LEFT)
	var code_before: int = ed.cells[8 * Ed.COLS + 2]
	_press(ed, KEY_6)                        # full block
	_press(ed, KEY_R)                        # supplies
	var code: int = ed.cells[8 * Ed.COLS + 2]
	check(code != code_before, "painting changes the cell under the cursor")
	check(Ed.geometry_of(code) == 4, "6 paints a full block (%d)"
		% Ed.geometry_of(code))
	check(Ed.effect_of(code) == "supplies",
		"and R puts supplies on its TOP, not on the floor under it (%s)"
		% Ed.effect_of(code))
	check(Ed.surface_of(code) != 0,
		"leaving solid floor beneath, so the block is not standing on a hole")

	# a hole, then back to a floor
	_press(ed, KEY_1)
	check(Ed.is_hole(ed.cells[8 * Ed.COLS + 2]), "1 punches a hole")
	_press(ed, KEY_2)
	check(Ed.landable(ed.cells[8 * Ed.COLS + 2]), "2 puts floor back")

	# resizing grows with FLOOR, not with holes: a row of nothing at the end
	# would delete the finish tunnel and drop the ship into space
	var was := ed.rows
	_press(ed, KEY_BRACKETRIGHT)
	check(ed.rows == was + 1, "] adds a row (%d)" % ed.rows)
	check(Ed.landable(ed.cells[(ed.rows - 1) * Ed.COLS + 3]),
		"and the new last row is floor, not a hole")

	# breaking the road has to be visible in the editor, not just in the model
	for c in Ed.COLS:
		ed.cells[(ed.rows - 1) * Ed.COLS + c] = Ed.set_surface(0, 3)
	ed._revalidate()
	check(not Ed.playable(ed._problems),
		"a last row with no tunnel shows as an error in the editor")
	var played := [0]
	ed.play_requested.connect(func(_p: String) -> void: played[0] += 1)
	_press(ed, KEY_P)
	check(played[0] == 0, "and P refuses to play a road with an error")

	# put the finish back, then save, reload and compare
	for c in Ed.COLS:
		ed.cells[(ed.rows - 1) * Ed.COLS + c] = Ed.set_geometry(
			Ed.set_surface(0, 3), 1)
	ed._revalidate()
	check(Ed.playable(ed._problems), "restoring the tunnel clears the error")
	_press(ed, KEY_S)
	var doc := Ed.from_file(ed.path_for(ed.name_stem))
	check(doc.get("cells", PackedInt32Array()) == ed.cells,
		"S writes the grid to user:// unchanged")
	_press(ed, KEY_P)
	check(played[0] == 1, "and P now asks the shell to play it")

	ed.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(
		"user://levels/test_editor_suite.json"))


func _press(ed: Node, keycode: int) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.pressed = true
	ed.handle_input(ev)


## Turning the toolkit's output into a claim. The solver is authoritative in
## ONE direction — a route found is a proof because sra replays it, while
## finding nothing only means the search failed — so the failure wording must
## never say "impossible". The search itself is not run here: it needs python3
## and the analysis checkout, neither of which the gate may depend on.
func _solver_verdicts() -> void:
	var solved := Editor._verdict(
		"road  0  g8    24 rows  SOLVED       furthest row 24.0/24  completed")
	check(solved.contains("solvable"), "SOLVED reads as solvable (%s)" % solved)
	var lost := Editor._verdict(
		"road  0  g8    24 rows  unsolved     furthest row 11.0/24  stuck")
	check(not lost.contains("solvable") and lost.contains("no route"),
		"an unsolved search reads as 'no route found' (%s)" % lost)
	check(lost.contains("not proof"),
		"and says so is not proof that none exists (%s)" % lost)
	check(Editor._verdict("  ").contains("python3"),
		"silence points at the missing interpreter, not at the road")
