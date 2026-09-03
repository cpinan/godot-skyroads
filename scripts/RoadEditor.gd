# gd-audit: ignore GDBP-101 — every script in scripts/ is PascalCase; a lone
# snake_case file would be a third convention, not a fix. See docs/PERF.md.
# A road editor, in the game's own 320x240 canvas.
#
# Reached with `--editor` and by no other route. It is deliberately NOT a menu
# item: tests/render_menu.gd compares all seven menu screens against the
# reference at 0 differing pixels, and an eighth entry on the main menu would
# fail that — the menus are 1993's, and this is not.
#
# What it draws is the same picture `sra ascii_map` prints, with the same
# glyphs, so a grid here and a dump there can be read against each other:
#
#     ' '  a hole            '.'  flat floor       'O'  tunnel
#     'n'  half block        'A'  half + bore
#     'H'  full block        'U'  full + bore
#     's' sticky  'i' ice  '+' supplies  '>' boost  'x' burning
#
# Custom roads are written to `user://levels/`, never next to `data/levels/`:
# the shipped ones are derived from Bluemoon's ROADS.LZS and LICENSE carves
# them out, while a road built here is the author's own work.
extends CanvasLayer

const Ed = preload("res://scripts/model/RoadEditModel.gd")

signal play_requested(path: String)
signal closed

## Where a road lives once it is saved.
const DIR := "user://levels"

## Canvas geometry, in the original's 320x240 display space. The screen is 40
## glyphs wide at Text8x8's 8 px, so every line below is written to fit 40
## characters — a longer one is simply cut off at the right edge.
const GUTTER := 34.0            ## room for a row number and its S/F tag
const CELL_W := 40.0
const CELL_H := 14.0
const GRID_TOP := 24.0
const STATUS_TOP := 170.0
const VISIBLE_ROWS := 10
const LINE_CHARS := 40

## The palette. Geometry decides the ground colour, the effect draws over it.
const GEOM_COLOUR := {
	0: Color(0.20, 0.24, 0.30),      ## flat floor
	1: Color(0.16, 0.34, 0.40),      ## tunnel
	2: Color(0.36, 0.32, 0.22),      ## half block
	3: Color(0.30, 0.34, 0.26),      ## half block, bored
	4: Color(0.48, 0.38, 0.22),      ## full block
	5: Color(0.40, 0.40, 0.26),      ## full block, bored
}
const HOLE_COLOUR := Color(0.06, 0.06, 0.08)
const INK := Color(0.86, 0.86, 0.78)
const DIM := Color(0.52, 0.54, 0.58)
const CURSOR := Color(1.0, 0.86, 0.35)
const ERR := Color(1.0, 0.45, 0.40)
const WARN_C := Color(1.0, 0.80, 0.40)

const GEOM_GLYPH := {0: ".", 1: "O", 2: "n", 3: "A", 4: "H", 5: "U"}
const EFFECT_GLYPH := {"sticky": "s", "ice": "i", "supplies": "+",
	"boost": ">", "burning": "x"}

## The brushes, in the order the number keys 1..7 select them.
const GEOM_BRUSHES := [-1, 0, 1, 2, 3, 4, 5]
const GEOM_LABELS := ["hole", "floor", "tunnel", "half", "half+bore",
	"full", "full+bore"]
## Q W E R T Y, in that order.
const EFFECT_BRUSHES := [Ed.EFFECT_NONE, Ed.EFFECT_STICKY, Ed.EFFECT_ICE,
	Ed.EFFECT_SUPPLIES, Ed.EFFECT_BOOST, Ed.EFFECT_BURNING]
const EFFECT_LABELS := ["plain", "sticky", "ice", "supplies", "boost", "burning"]

var rows := 40
var gravity := 8
var fuel_rows := 200
var oxygen_secs := 90
var world := 0
var cells := PackedInt32Array()
var name_stem := "custom"

var _cur_row := SkyRoads.Z_START_ROW
var _cur_col := 3
var _top_row := 0
var _geom_brush := 1            ## index into GEOM_BRUSHES: "floor"
var _effect_brush := 0          ## index into EFFECT_BRUSHES: "plain"
var _problems: Array = []
var _problem_at := 0
var _message := ""
var _dirty := true
var _draw_node: Control
## The 72 road colours a saved road carries. Copied from a shipped road rather
## than invented: the renderer indexes 72 entries with a fixed meaning per slot
## (SkyRoads.ROAD_PALETTE_LAYOUT), and a made-up one draws a road nobody can
## read. `world` picks which shipped road's colours to borrow.
var _palette := PackedColorArray()

## A running `sra solve`, or an empty dictionary. It is a separate PROCESS, not
## a thread: the search lives in analysis/sra/solver.py and reimplementing a
## beam search in GDScript to avoid one fork would be a second engine to keep
## honest. Polled from _process so a long search does not freeze the grid.
var _solver := {}
var _solver_frames := 0

## Undo. A road is rows x 7 ints — 5.6 KB for a 200-row one — so sixty states
## cost less than one texture and there is no reason to be clever about it.
## The header travels with the grid: undoing a gravity change and undoing a
## brush stroke are the same gesture to the person pressing U.
const UNDO_DEPTH := 60
var _undo: Array = []
var _redo: Array = []

## The other end of a fill. -1 when unset, in which case a fill covers the
## cursor's row alone.
var _mark_row := -1

## The key list, on H. It stopped fitting the status band once undo, the row
## keys and the fill arrived, and cramming it into two 40-character lines made
## both of them unreadable — so it moved onto a page of its own.
var _help := false

const HELP_LINES := [
	"ROAD EDITOR",
	"",
	"arrows PgUp PgDn Home End  move",
	"mouse click                move + paint",
	"1-7  hole floor tunnel half half+bore",
	"     full full+bore",
	"QWERTY  plain sticky ice supplies",
	"        boost burning",
	"A       fill the row (or mark..cursor)",
	"M       set / clear the fill mark",
	"I  D    insert / delete a row",
	"[  ]    shorter / longer  (shift: x10)",
	"U       undo      shift+U  redo",
	"G F O   gravity / fuel rows / oxygen s",
	"B       backdrop world  (shift: back)",
	"V       next problem",
	"S  L    save / reload",
	"P       play-test    C  ask the solver",
	"X       cancel a running solve",
	"H       this page    ESC  leave",
]


func _ready() -> void:
	layer = 60
	_draw_node = Control.new()
	_draw_node.position = Vector2.ZERO
	_draw_node.size = Vector2(SkyRoads.SCREEN_W, SkyRoads.SQUARE_H)
	_draw_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_draw_node.draw.connect(_draw_editor)
	add_child(_draw_node)
	# Reopen on whatever was last saved under this name, so a play-test comes
	# back to the road it left rather than to a blank grid.
	if cells.is_empty() and FileAccess.file_exists(path_for(name_stem)):
		_load()
		return
	if cells.is_empty():
		new_road()
	_load_palette()
	_revalidate()


## A fresh road: floor everywhere, a tunnel across the last row to finish in.
func new_road() -> void:
	if not cells.is_empty():
		_mark_undo()
	cells = Ed.blank(rows)
	rows = cells.size() / Ed.COLS
	_cur_row = SkyRoads.Z_START_ROW
	_cur_col = 3
	_top_row = 0
	_message = "new road"
	_revalidate()


## The 72 colours a road is drawn with, borrowed from the first shipped road of
## the chosen world. Roads 1..30 map to worlds by (index - 1) / 3.
func _load_palette() -> void:
	var doc := Ed.from_file("res://data/levels/road_%02d.json"
		% clampi(world * 3 + 1, 1, 30))
	_palette = PackedColorArray()
	for c in doc.get("palette", []):
		_palette.append(Color8(int(c[0]), int(c[1]), int(c[2])))
	while _palette.size() < 72:
		_palette.append(Color(1, 0, 1))


# ---------------------------------------------------------------- input ----
func handle_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_click(_to_canvas(mb.position))
		return
	if not (ev is InputEventKey):
		return
	var k := ev as InputEventKey
	if not k.pressed or k.echo:
		return
	var shift := k.shift_pressed
	match k.keycode:
		KEY_ESCAPE:
			closed.emit()
		KEY_UP:
			_move(-1, 0)
		KEY_DOWN:
			_move(1, 0)
		KEY_LEFT:
			_move(0, -1)
		KEY_RIGHT:
			_move(0, 1)
		KEY_PAGEUP:
			_move(-VISIBLE_ROWS, 0)
		KEY_PAGEDOWN:
			_move(VISIBLE_ROWS, 0)
		KEY_HOME:
			_cur_row = 0
			_follow()
		KEY_END:
			_cur_row = rows - 1
			_follow()
		KEY_SPACE:
			_paint()
		KEY_U:
			if shift:
				_redo_step()
			else:
				_undo_step()
		KEY_I:
			_insert_row()
		KEY_D:
			_delete_row()
		KEY_A:
			_fill()
		KEY_M:
			_toggle_mark()
		KEY_H:
			_help = not _help
			_redraw()
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7:
			_geom_brush = k.keycode - KEY_1
			_paint()
		KEY_Q, KEY_W, KEY_E, KEY_R, KEY_T, KEY_Y:
			_effect_brush = [KEY_Q, KEY_W, KEY_E, KEY_R, KEY_T,
				KEY_Y].find(k.keycode)
			_paint()
		KEY_BRACKETLEFT:
			_resize(rows - (10 if shift else 1))
		KEY_BRACKETRIGHT:
			_resize(rows + (10 if shift else 1))
		KEY_G:
			_mark_undo()
			gravity = clampi(gravity + (-1 if shift else 1), 1, 30)
			_message = "gravity %d (dash shows %d)" % [gravity,
				SkyRoads.dash_gravity(gravity)]
			_revalidate()
		KEY_F:
			_mark_undo()
			fuel_rows = maxi(fuel_rows + (-10 if shift else 10), 0)
			_message = "fuel %d rows" % fuel_rows
			_revalidate()
		KEY_O:
			_mark_undo()
			oxygen_secs = maxi(oxygen_secs + (-5 if shift else 5), 0)
			_message = "oxygen %d s" % oxygen_secs
			_revalidate()
		KEY_B:
			_mark_undo()
			world = wrapi(world + (-1 if shift else 1), 0,
				SkyRoads.WORLDS_COUNT)
			_load_palette()
			_message = "backdrop world %d" % world
			_redraw()
		KEY_V:
			_problem_at = wrapi(_problem_at + 1, 0, maxi(_problems.size(), 1))
			_redraw()
		KEY_X:
			_cancel_solve()
		KEY_N:
			new_road()
		KEY_S:
			_save()
		KEY_L:
			_load()
		KEY_P:
			_play()
		KEY_C:
			_solve()
		_:
			pass


func _to_canvas(p: Vector2) -> Vector2:
	return _draw_node.get_global_transform().affine_inverse() * p


func _click(p: Vector2) -> void:
	if p.y < GRID_TOP or p.y >= STATUS_TOP or p.x < GUTTER:
		return
	var col := int((p.x - GUTTER) / CELL_W)
	var row := _top_row + int((p.y - GRID_TOP) / CELL_H)
	if col < 0 or col >= Ed.COLS or row < 0 or row >= rows:
		return
	_cur_col = col
	_cur_row = row
	_paint()


func _move(dr: int, dc: int) -> void:
	_cur_row = clampi(_cur_row + dr, 0, rows - 1)
	_cur_col = clampi(_cur_col + dc, 0, Ed.COLS - 1)
	_follow()


## Keep the cursor on screen, and keep the scroll from running past the road.
func _follow() -> void:
	_top_row = clampi(_top_row, _cur_row - VISIBLE_ROWS + 1, _cur_row)
	_top_row = clampi(_top_row, 0, maxi(rows - VISIBLE_ROWS, 0))
	_redraw()


## What both brushes together would make of the cell at `i`. The geometry goes
## on first so the effect lands in whichever nibble the NEW geometry reads — a
## burning floor turned into a block has to stay burning.
func _brushed(i: int) -> int:
	var geom: int = GEOM_BRUSHES[_geom_brush]
	if geom < 0:
		return 0                              # a hole is the whole cell
	return Ed.set_effect(Ed.retarget_effect(cells[i], geom),
		EFFECT_BRUSHES[_effect_brush])


## Apply both brushes to the cell under the cursor.
func _paint() -> void:
	var i := _cur_row * Ed.COLS + _cur_col
	if i < 0 or i >= cells.size():
		return
	var want := _brushed(i)
	if want == cells[i]:
		return              # nothing changed, so nothing to undo and no redraw
	_mark_undo()
	cells[i] = want
	_revalidate()


## The far end of a fill. Pressing M on the marked row clears it, so the same
## key sets and unsets and there is nothing to remember.
func _toggle_mark() -> void:
	_mark_row = -1 if _mark_row == _cur_row else _cur_row
	_message = "mark cleared" if _mark_row < 0 else "mark on row %d" % _mark_row
	_redraw()


## Paint every cell of the cursor's row, or of every row between the mark and
## the cursor. One undo step for the whole thing: a fill is one action to the
## person who pressed A, whatever it touched.
func _fill() -> void:
	var lo := _cur_row if _mark_row < 0 else mini(_mark_row, _cur_row)
	var hi := _cur_row if _mark_row < 0 else maxi(_mark_row, _cur_row)
	lo = clampi(lo, 0, rows - 1)
	hi = clampi(hi, 0, rows - 1)
	_mark_undo()
	var changed := 0
	for r in range(lo, hi + 1):
		for c in Ed.COLS:
			var i := r * Ed.COLS + c
			var want := _brushed(i)
			if want != cells[i]:
				cells[i] = want
				changed += 1
	if changed == 0:
		_undo.pop_back()        # nothing happened, so do not bank an undo step
	_message = "filled rows %d..%d (%d cells)" % [lo, hi, changed]
	_revalidate()


## Insert a row of FLOOR before the cursor. Floor and not holes, for the same
## reason _resize grows with floor: a row of nothing dropped into the middle of
## a road is a fall, and an editor that adds one by default is fighting you.
func _insert_row() -> void:
	if rows >= SkyRoads.MAX_ROWS:
		_message = "%d rows is the engine's limit" % SkyRoads.MAX_ROWS
		_redraw()
		return
	_mark_undo()
	var out := PackedInt32Array()
	out.resize((rows + 1) * Ed.COLS)
	for r in rows + 1:
		for c in Ed.COLS:
			out[r * Ed.COLS + c] = Ed.set_surface(0, Ed.PLAIN_FLOOR) \
				if r == _cur_row else cells[(r if r < _cur_row else r - 1) * Ed.COLS + c]
	cells = out
	rows += 1
	if _mark_row >= _cur_row:
		_mark_row += 1
	_message = "inserted row %d (%d rows)" % [_cur_row, rows]
	_follow()
	_revalidate()


func _delete_row() -> void:
	if rows <= SkyRoads.Z_START_ROW + 2:
		_message = "a road cannot be shorter than %d rows" \
			% (SkyRoads.Z_START_ROW + 2)
		_redraw()
		return
	_mark_undo()
	var out := PackedInt32Array()
	out.resize((rows - 1) * Ed.COLS)
	for r in rows - 1:
		for c in Ed.COLS:
			out[r * Ed.COLS + c] = cells[(r if r < _cur_row else r + 1) * Ed.COLS + c]
	cells = out
	rows -= 1
	_cur_row = mini(_cur_row, rows - 1)
	if _mark_row > _cur_row:
		_mark_row -= 1
	_mark_row = mini(_mark_row, rows - 1)
	_message = "deleted a row (%d rows)" % rows
	_follow()
	_revalidate()


# ----------------------------------------------------------------- undo ----
func _state() -> Dictionary:
	return {"cells": cells.duplicate(), "rows": rows, "gravity": gravity,
		"fuel_rows": fuel_rows, "oxygen_secs": oxygen_secs, "world": world}


func _restore(st: Dictionary) -> void:
	cells = (st["cells"] as PackedInt32Array).duplicate()
	rows = st["rows"]
	gravity = st["gravity"]
	fuel_rows = st["fuel_rows"]
	oxygen_secs = st["oxygen_secs"]
	if world != st["world"]:
		world = st["world"]
		_load_palette()
	_cur_row = clampi(_cur_row, 0, rows - 1)
	_mark_row = mini(_mark_row, rows - 1)
	_follow()
	_revalidate()


## Call BEFORE a change. The redo stack is dropped, as it has to be: a new edit
## makes everything that was ahead of it a different road.
func _mark_undo() -> void:
	_undo.append(_state())
	if _undo.size() > UNDO_DEPTH:
		_undo.pop_front()
	_redo.clear()


func _undo_step() -> void:
	if _undo.is_empty():
		_message = "nothing to undo"
		_redraw()
		return
	_redo.append(_state())
	_restore(_undo.pop_back())
	_message = "undo — %d step(s) left" % _undo.size()
	_redraw()


func _redo_step() -> void:
	if _redo.is_empty():
		_message = "nothing to redo"
		_redraw()
		return
	_undo.append(_state())
	_restore(_redo.pop_back())
	_message = "redo — %d step(s) left" % _redo.size()
	_redraw()


## Growing adds floor rather than holes: a new row of nothing at the end of a
## road would silently delete the finish tunnel and drop the ship into space.
func _resize(new_rows: int) -> void:
	new_rows = clampi(new_rows, SkyRoads.Z_START_ROW + 2, SkyRoads.MAX_ROWS)
	if new_rows == rows:
		return
	_mark_undo()
	var out := PackedInt32Array()
	out.resize(new_rows * Ed.COLS)
	for r in new_rows:
		for c in Ed.COLS:
			out[r * Ed.COLS + c] = cells[r * Ed.COLS + c] if r < rows \
				else Ed.set_surface(0, Ed.PLAIN_FLOOR)
	cells = out
	rows = new_rows
	_cur_row = mini(_cur_row, rows - 1)
	_message = "%d rows" % rows
	_follow()
	_revalidate()


func _revalidate() -> void:
	_problems = Ed.problems(rows, cells, gravity, fuel_rows, oxygen_secs)
	_problem_at = clampi(_problem_at, 0, maxi(_problems.size() - 1, 0))
	_redraw()


func _redraw() -> void:
	_dirty = true
	if _draw_node != null:
		_draw_node.queue_redraw()


# ---------------------------------------------------------------- files ----
func path_for(stem: String) -> String:
	return "%s/%s.json" % [DIR, stem]


func _save() -> void:
	var doc := Ed.to_dict(0, rows, cells, gravity, fuel_rows, oxygen_secs,
		world, _palette)
	if Ed.save_to(path_for(name_stem), doc):
		_message = "saved %s" % path_for(name_stem)
	else:
		_message = "COULD NOT SAVE %s" % path_for(name_stem)
	_redraw()


func _load() -> void:
	var doc := Ed.from_file(path_for(name_stem))
	if doc.is_empty():
		_message = "nothing to load at %s" % path_for(name_stem)
		_redraw()
		return
	rows = doc["rows"]
	cells = doc["cells"]
	gravity = doc["gravity"]
	fuel_rows = doc["fuel_rows"]
	oxygen_secs = doc["oxygen_secs"]
	world = doc["world"]
	_load_palette()
	_cur_row = mini(_cur_row, rows - 1)
	_message = "loaded %s" % path_for(name_stem)
	_follow()
	_revalidate()


## Save first, then hand the path to the shell. A road is play-tested from the
## file so that what is driven is exactly what would ship, not the grid in
## memory — the same reason the parity captures replay from disk.
func _play() -> void:
	if not Ed.playable(_problems):
		_message = "fix the errors first — press V to read them"
		_redraw()
		return
	_save()
	play_requested.emit(path_for(name_stem))


# --------------------------------------------------------------- solver ----
## Ask the analysis toolkit whether this road can be finished at all.
##
## Authoritative in ONE direction only. A route found is a PROOF, because sra
## replays it from scratch to confirm it; finding nothing means the search
## failed, not that the road is impossible — so a failure is reported as "no
## route found" and never as "impossible".
##
## `analysis/` is a sibling checkout and NOT part of this repo, so an exported
## build will not have it. That is why this reports what is missing rather than
## quietly doing nothing: an author who presses C and sees no reaction has no
## way to tell a slow search from an absent toolkit.
func _solve() -> void:
	if not _solver.is_empty():
		_message = "already solving - X cancels"
		_redraw()
		return
	if not Ed.playable(_problems):
		_message = "fix the errors first - press V to read them"
		_redraw()
		return
	_save()
	var sra := _sra_path()
	if sra.is_empty():
		_message = "no analysis/sra.py beside the project: no solver"
		_redraw()
		return
	var args := [sra, "solve", "--road-json",
		ProjectSettings.globalize_path(path_for(name_stem))]
	var proc := OS.execute_with_pipe("python3", args)
	if proc.is_empty():
		_message = "could not start python3 - no solver"
		_redraw()
		return
	_solver = proc
	_solver_frames = 0
	_message = "solving... (X cancels)"
	_redraw()


## The toolkit, if this is a dev checkout. `res://` globalises to the Godot
## project folder, and `analysis/` is its sibling.
func _sra_path() -> String:
	var here := ProjectSettings.globalize_path("res://")
	var candidate := here.path_join("../analysis/sra.py").simplify_path()
	return candidate if FileAccess.file_exists(candidate) else ""


func _cancel_solve() -> void:
	if _solver.is_empty():
		return
	OS.kill(int(_solver["pid"]))
	_solver = {}
	_message = "solve cancelled"
	_redraw()


func _process(_delta: float) -> void:
	if _solver.is_empty():
		return
	_solver_frames += 1
	if OS.is_process_running(int(_solver["pid"])):
		if _solver_frames % 60 == 0:
			_message = "solving... %ds  (X cancels)" % (_solver_frames / 60)
			_redraw()
		return
	var text := ""
	var out: FileAccess = _solver.get("stdio")
	if out != null:
		text = out.get_as_text()
	_solver = {}
	_message = _verdict(text)
	# Put the cursor where the search died. That row IS the answer to "why not"
	# far more often than the verdict is: the first road built with this editor
	# was unsolvable because three rows of ice ended against a wall with one
	# open lane, and `furthest row 34.7` pointed straight at it.
	var row := _furthest_row(text)
	if row >= 0.0 and not text.contains("SOLVED"):
		_cur_row = clampi(int(row), 0, rows - 1)
		_follow()
	print("[editor] solve: %s" % text.strip_edges())
	_redraw()


## The toolkit prints one line per road; the verdict is the word SOLVED, and
## either way the line carries `furthest row N/M`.
static func _verdict(text: String) -> String:
	var line := _last_line(text)
	if line.is_empty():
		return "the solver said nothing - is python3 on PATH?"
	if line.contains("SOLVED"):
		var ticks := _token_before(line, "ticks")
		return "solvable: completes in %s ticks" % ticks if not ticks.is_empty() \
			else "solvable: a route was found and replayed"
	var row := _furthest_row(text)
	if row < 0.0:
		return "no route found - a search failure, not proof none exists"
	return "no route past row %.1f - a search failure, not proof none exists" % row


## How far the best branch got, or -1 when the line does not say. Reported on a
## success too, where it is simply the last row.
static func _furthest_row(text: String) -> float:
	var line := _last_line(text)
	var parts := line.split(" ", false)
	for i in parts.size():
		# "furthest row   34.7/60"
		if parts[i] == "furthest" and i + 2 < parts.size():
			return String(parts[i + 2]).split("/")[0].to_float()
	return -1.0


static func _token_before(line: String, word: String) -> String:
	var parts := line.split(" ", false)
	for i in parts.size():
		if parts[i] == word and i > 0:
			return parts[i - 1]
	return ""


static func _last_line(text: String) -> String:
	var body := text.strip_edges()
	if body.is_empty():
		return ""
	var lines := body.split("\n")
	return String(lines[lines.size() - 1]).strip_edges()


# ----------------------------------------------------------------- draw ----
func _draw_editor() -> void:
	var d := _draw_node
	d.draw_rect(Rect2(Vector2.ZERO,
		Vector2(SkyRoads.SCREEN_W, SkyRoads.SQUARE_H)), Color(0.04, 0.05, 0.07),
		true)
	if _help:
		_draw_help(d)
		return
	_text(d, "EDIT %s" % name_stem.substr(0, 16), 2, 3, INK)
	_right(d, "r%d/%d c%d" % [_cur_row, rows, _cur_col], 3, CURSOR)
	_text(d, "g%d  fuel %d  oxy %ds  world %d"
		% [gravity, fuel_rows, oxygen_secs, world], 2, 13, DIM)

	for i in VISIBLE_ROWS:
		var r := _top_row + i
		if r >= rows:
			break
		var y := GRID_TOP + i * CELL_H
		var tag := "%d" % r
		if r == SkyRoads.Z_START_ROW:
			tag = "S%d" % r                       # where the ship spawns
		elif r == rows - 1:
			tag = "F%d" % r                       # the finish row
		if r == _mark_row:
			tag = "*" + tag                       # the far end of a fill
		_text(d, tag, 2, int(y + 3),
			CURSOR if r == _cur_row else DIM)
		for c in Ed.COLS:
			_draw_cell(d, r, c, GUTTER + c * CELL_W, y)

	_draw_status(d)


func _draw_cell(d: Control, row: int, col: int, x: float, y: float) -> void:
	var code: int = cells[row * Ed.COLS + col]
	var geom := Ed.geometry_of(code)
	var rect := Rect2(Vector2(x, y), Vector2(CELL_W - 1.0, CELL_H - 1.0))
	var fill: Color = HOLE_COLOUR if Ed.is_hole(code) \
		else GEOM_COLOUR.get(geom, Color(0.6, 0.1, 0.6))
	d.draw_rect(rect, fill, true)

	var glyph := " " if Ed.is_hole(code) else str(GEOM_GLYPH.get(geom, "?"))
	var eff := Ed.effect_of(code)
	var label: String = glyph + str(EFFECT_GLYPH.get(eff, ""))
	var ink := INK
	if eff == "burning":
		ink = ERR
	elif eff == "supplies" or eff == "boost":
		ink = Color(0.55, 1.0, 0.6)
	_text(d, label, int(x + 3), int(y + 3), ink)

	if row == _cur_row and col == _cur_col:
		d.draw_rect(rect, CURSOR, false, 1.0)


func _draw_status(d: Control) -> void:
	d.draw_rect(Rect2(Vector2(0, STATUS_TOP),
		Vector2(SkyRoads.SCREEN_W, SkyRoads.SQUARE_H - STATUS_TOP)),
		Color(0.02, 0.02, 0.03), true)
	var brush := "%s / %s" % [GEOM_LABELS[_geom_brush],
		EFFECT_LABELS[_effect_brush]]
	if _mark_row >= 0:
		brush += "  *%d" % _mark_row
	_text(d, brush, 2, 173, CURSOR)

	if not _problems.is_empty():
		var p: Dictionary = _problems[_problem_at]
		var col := INK
		if p["level"] == Ed.ERROR:
			col = ERR
		elif p["level"] == Ed.WARN:
			col = WARN_C
		var errors := 0
		for q in _problems:
			if q["level"] == Ed.ERROR:
				errors += 1
		# the count of ERRORS is the number that decides whether P will play,
		# so it is on screen even when the reader is looking at problem 4 of 6
		_right(d, "%d err  %d/%d" % [errors, _problem_at + 1, _problems.size()],
			173, ERR if errors > 0 else DIM)
		_wrap(d, str(p["text"]), 2, 183, col, 2)

	if not _message.is_empty():
		_wrap(d, _message, 2, 203, INK, 2)
	_text(d, "H keys  V problem  P play  ESC exit", 2, 226, DIM)


## The key list. Deliberately the whole screen: it is read once and then not
## again, so there is no reason to make it share space with the grid.
func _draw_help(d: Control) -> void:
	for i in HELP_LINES.size():
		var line: String = HELP_LINES[i]
		_text(d, line, 4, 6 + i * 11, INK if i == 0 else DIM)


## Right-aligned at the screen edge, for the numbers that belong in a corner.
func _right(d: Control, s: String, y: int, col: Color) -> void:
	_text(d, s, int(SkyRoads.SCREEN_W) - Text8x8.width(s) - 2, y, col)


## Text8x8 draws at 320x200 coordinates and scales by PIXEL_ASPECT, the same as
## every other string in the game.
func _text(d: Control, s: String, x: int, y: int, col: Color) -> void:
	Text8x8.draw(d, s, x, int(y / SkyRoads.PIXEL_ASPECT), col,
		SkyRoads.PIXEL_ASPECT)


## A problem sentence is longer than the screen, and it is the one thing here
## that has to be readable, so it wraps instead of being cut off.
func _wrap(d: Control, s: String, x: int, y: int, col: Color, lines: int) -> void:
	var per := int((SkyRoads.SCREEN_W - x - 2) / Text8x8.GLYPH_W)
	var words := s.split(" ")
	var line := ""
	var n := 0
	for w in words:
		var candidate: String = w if line.is_empty() else line + " " + w
		if candidate.length() > per:
			_text(d, line, x, y + n * 9, col)
			n += 1
			line = w
			if n >= lines:
				return
		else:
			line = candidate
	if not line.is_empty() and n < lines:
		_text(d, line, x, y + n * 9, col)
