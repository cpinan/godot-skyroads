# gd-audit: ignore GDBP-101 — tests/ follows scripts/ naming. See docs/PERF.md.
# The editor as a PERSON reaches it: through the shell, not by calling it.
#
# tests/test_editor.gd covers the format, the rules and the brushes by calling
# RoadEditor directly. Everything between the keyboard and those calls was
# uncovered, and that is where the wiring lives: `--editor` has to build the
# thing, `Main._unhandled_input` has to route to it ahead of the menu, a mouse
# click has to land on the cell under the pointer, and the play-test has to
# come back.
#
# Two of those had never been exercised at all — mouse painting, and the round
# trip out to a road and back — which is why this file exists.
#
# Events go through `get_root().push_input()` rather than into
# `RoadEditor.handle_input()`, because routing is the point. push_input takes
# WINDOW pixels and the 320x240 canvas is stretched into them, so a canvas
# coordinate has to be scaled by window / canvas before it is sent: computing
# that from `get_visible_rect()` gives 1:1 and silently clicks the wrong cell.
extends SceneTree

const Ed = preload("res://scripts/model/RoadEditModel.gd")
const STEM := "test_editor_shell"

var _failures := 0
var _checks := 0


func check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL  %s" % label)


func _init() -> void:
	# --editor is normally read from the command line; the suite runner owns
	# that, so the option object is built here instead
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	get_root().add_child(main)
	for i in 20:
		await process_frame

	var ed := _find(get_root(), "RoadEditor.gd")
	if ed == null:
		# the suite is launched without --editor, so open it the way the flag
		# would; this still goes through Main, which is what is being tested
		main.call("_open_editor", STEM)
		for i in 5:
			await process_frame
		ed = _find(get_root(), "RoadEditor.gd")
	check(ed != null, "the shell can open the editor")
	if ed == null:
		_report()
		return
	ed.name_stem = STEM

	var row0: int = ed._cur_row
	_key(KEY_DOWN)
	await process_frame
	check(ed._cur_row == row0 + 1,
		"a key event routed through the tree reaches the editor (%d -> %d)"
		% [row0, ed._cur_row])

	_key(KEY_6)
	await process_frame
	var painted: int = ed.cells[ed._cur_row * Ed.COLS + ed._cur_col]
	check(Ed.geometry_of(painted) == 4,
		"and '6' paints a full block under the cursor (geom %d)"
		% Ed.geometry_of(painted))

	# a click three rows down the visible grid and in column 5
	_click_canvas(ed, Vector2(ed.GUTTER + 5 * ed.CELL_W + 4.0,
		ed.GRID_TOP + 3 * ed.CELL_H + 4.0))
	await process_frame
	check(ed._cur_row == 3 and ed._cur_col == 5,
		"a mouse click lands on the cell under the pointer (r%d c%d, wanted r3 c5)"
		% [ed._cur_row, ed._cur_col])

	# --- the play-test round trip ---
	_key(KEY_2)                                  # floor, so the road stays valid
	await process_frame
	_key(KEY_P)
	var started := await _wait(func() -> bool: return main.get("_in_game"), 8000)
	check(started, "P saves the road and the shell starts driving it")
	check(str(main.get("_custom_level")).ends_with("%s.json" % STEM),
		"from the editor's own file in user:// (%s)" % main.get("_custom_level"))

	# ESC during the fade is swallowed on purpose (game.c:398-402), so wait it
	# out exactly as a player has to
	await _wait(func() -> bool: return not main.get("_fading"), 8000)
	_key(KEY_ESCAPE)
	var back := await _wait(
		func() -> bool: return _find(get_root(), "RoadEditor.gd") != null, 8000)
	check(back, "and ESC comes back to the EDITOR, not to the road select")
	var ed2 := _find(get_root(), "RoadEditor.gd")
	if ed2 != null:
		check(ed2.name_stem == STEM and Ed.geometry_of(
			ed2.cells[4 * Ed.COLS + 3]) == 4,
			"reopened on the same road, with the edit still in it")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(
		"user://levels/%s.json" % STEM))
	_report()


func _report() -> void:
	print("Result: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _find(n: Node, tail: String) -> Node:
	var s: Variant = n.get_script()
	if s != null and str(s.resource_path).ends_with(tail):
		return n
	for c in n.get_children():
		var r := _find(c, tail)
		if r != null:
			return r
	return null


func _key(code: int) -> void:
	for down in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.pressed = down
		get_root().push_input(ev)


## `p` is a canvas coordinate; push_input wants window pixels.
func _click_canvas(ed: Node, p: Vector2) -> void:
	var win := Vector2(DisplayServer.window_get_size())
	var canvas := Vector2(SkyRoads.SCREEN_W, SkyRoads.SQUARE_H)
	var scale := win / canvas if win.x > 0.0 and win.y > 0.0 else Vector2.ONE
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = p * scale
	get_root().push_input(ev)


## Waits are in MILLISECONDS, not frames. Headless runs a frame in well under a
## millisecond, so a frame budget that is generous windowed expires in a
## fraction of the 1-second fade the shell puts either side of a road — which
## is exactly how this suite first "failed" the ESC step in headless while
## passing it windowed.
func _wait(cond: Callable, msec: int) -> bool:
	var deadline := Time.get_ticks_msec() + msec
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		await process_frame
	return cond.call()
